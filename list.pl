#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;

use Data::Printer;
use FindBin;
use HTTP::Tiny;
use JSON::SL;
use Path::Tiny;
use Sort::Key::Maker in_sort => sub { @$_[6..7] }, qw(num -num);
use URI::Escape;

my $large = 1.0;
my $out = path("$FindBin::Bin/utxo.txt");

my $conf = path('~/.bitcoin/bitcoin.conf')->slurp;
my ($user, $pass);
if (($user) = $conf =~ /^rpcuser\s*=\s*(.*)$/m) {
    ($pass) = $conf =~ /^rpcpassword\s*=\s*(.*)$/m;
}
else {
    my $cookie = path('~/.bitcoin/.cookie')->slurp;
    chomp $cookie;
    ($user, $pass) = split /:/, $cookie, 2;
    $user // die q(can't determine rpc auth);
}
$pass //= '';
$_ = uri_escape($_) for $user, $pass;
my $url = "http://$user:$pass\@127.0.0.1:8332/";

# Parse the JSON result as a stream to minimize memory usage.
my $parser = JSON::SL->new;
$parser->max_size(2**20);
$parser->set_jsonpointer(['/result/^']);

my @in;

my $ua = HTTP::Tiny->new;
my $res = $ua->post($url, {
    content => q<{"id":"0","method":"listunspent","params":[]}>,
    headers => { 'content-type' => 'application/json' },
    data_callback => sub {
        my ($data, $res) = @_;
        $parser->feed($data);
        while (my $obj = $parser->fetch) {
            $obj = $obj->{Value};
            if ('HASH' eq ref $obj) {
                my $amount = sprintf '%.8f', $obj->{amount};

                my $conf = $obj->{confirmations};
                my $priority = $conf * $amount * 1e8;
                my $is_large = $large <= $amount;
                push @in, [
                    $amount, $conf, $priority, @$obj{qw(txid vout address)},
                    $is_large, $is_large ? -$priority : $priority
                ];
            }
        }
    }
});
die p $res unless $res->{success};

in_sort_inplace @in;

my $fh = $out->openw;
my $prev = 1;
for my $in (@in) {
    # Insert a newline at the boundary between the large and small inputs.
    say $fh '' if $large > $prev and $large <= $in->[0];
    say $fh join ' | ', @$in[0..5];
    $prev = $in->[0];
}
