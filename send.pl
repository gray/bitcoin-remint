#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;

use Capture::Tiny;
use Carp qw(croak);
use Data::Printer;
use Getopt::Long qw(:config auto_help);
use IO::Prompter;
use JSON::MaybeXS;
use List::Util qw(sum);
use Path::Tiny;
use Pod::Usage;
use Term::ReadKey;

GetOptions(
    'address|a=s' => \my $addr,
    'send|s'      => \my $send,
    'fee|f'       => \(my $fee = 0),
    'inputs|i=s'  => \my $in,
) or pod2usage;

# Hardcode the fee to avoid mistakes if accepted as an argument.
$fee &&= 0.00010_000;

sub capture;

$in &&= path($in)->slurp;
# Copy selected input lines here from /tmp/utxo.txt if an input file is't
# specified.
# 67 inputs usually fits within 10KB.
# When adding an input from an address not controlled by the wallet, append
#   an extra field for the WIF.
$in //= q[


];
my @in = map { [ split /\s*\|\s*/ ] } grep $_, split /\n/, $in;
die 'missing input data' unless @in;

my %addr; $addr{$_->[5]} += $_->[0] for @in;
# Determine the address contributing the most to the tx.
unless ($addr) {
    my ($max, $max_addr) = 0;
    while (my ($key, $val) = each %addr) {
        $max_addr = $key, $max = $val if $val > $max;
    }
    $addr = $max_addr;
    say "address: $max_addr ($max)";
}

my $total = sum(map $_->[0], @in) // 0;
if ($fee) {
    printf "total: %.8f + %.8f fee\n", $total - $fee, $fee;
}
else {
    printf "total: %.8f\n", $total;
}

my $tx = do {
    my $inputs = encode_json([
        map { txid => $_->[3], vout => 0+$_->[4] }, @in
    ]);
    $total -= $fee;
    my $pay = encode_json({$addr => sprintf "%.8f", $total});
    capture 'bitcoin-cli', createrawtransaction => $inputs, $pay;
};
chomp $tx;
exit unless $tx =~ /^[0-9a-f]{100,}$/;

my @arg = ($tx);
if (my %wif = map @$_[5,6], grep $_->[6], @in) {
    for my $a (keys %addr) {
        if (exists $wif{$a}) {
            # If a wif needs to be specified, the address is not aleady in the
            # wallet- make sure the output does not get sent to that address.
            die 'use a different send address' if $a eq $addr;
            next;
        }
        my $wif = capture 'bitcoin-cli', dumpprivkey => $a;
        chomp $wif;
        $wif{$a} = $wif;
    }
    push @arg, '[]', encode_json([values %wif]);
}

my $res = eval { capture 'bitcoin-cli', signrawtransaction => @arg };
if ($@ and $@ =~ /walletpassphrase/) {
    unlock_wallet();
    $res = capture 'bitcoin-cli', signrawtransaction => @arg;
}
$res = decode_json($res);
unless ($res->{complete}) {
    p $res->{errors};
    die "failed to sign tx\n";
}

my $hex = $res->{hex};
my $len = length(pack 'H*', $hex);
say "bytes: $len";
die "tx too large- $len > 10,000 bytes" if 1e4 <= $len;

# 0.12 disabled estimatepriority.
my $min_priority = 1e7;
my $priority = int sum(map $_->[2], @in) / $len;
printf "priority: %.2e (minimum: %.2e)\n", $priority, $min_priority;
die 'insufficient priority' if ! $fee and $priority < $min_priority;

$res = capture 'bitcoin-cli', decoderawtransaction => $hex;
$res = decode_json($res);
my $id = $res->{txid};
say "tx: $id";

if ($send) {
    # 0.12 prevents sending free transactions:
    #   https://github.com/bitcoin/bitcoin/issues/7630
    capture 'bitcoin-cli', prioritisetransaction => $id, 0, 1e6;
    capture 'bitcoin-cli', sendrawtransaction => $hex;
    say "https://live.blockcypher.com/btc/tx/$id";
}
else {
    say 'performed dry-run. send with -s/--send';
}

exit;


END {
    capture 'bitcoin-cli', 'walletlock';
}

sub capture {
    # Copy @_ so it is available to the command.
    my @cmd = @_;
    # XXX: Hackish implementation to pass STDIN data as last argument.
    my $in = pop @cmd if ref $cmd[-1];
    my ($out, $err) = Capture::Tiny::capture {
        open my $pipe, '|-', @cmd or return 0 + $!;
        print $pipe $$in if $in;
        close $pipe;
    };
    return $out if ! $? and '' eq $err;
    $? >>= 8, croak $err;
}


sub unlock_wallet {
    # Overwrite the password prompt after it's done.
    my $width = (GetTerminalSize)[0];
    my $ret = "\r" . ' ' x $width . "\r";
    {
        my $pass = prompt 'wallet password: ', -in => *STDIN, -echo => '*',
            -return => $ret;
        my $stdin = "walletpassphrase\n$pass\n300";
        eval { capture 'bitcoin-cli', '-stdin', \$stdin };
        redo if 14 == $?;
    }
}


__END__

=head1 NAME

send.pl

=head1 SYNOPSIS

  send.pl [<options>]

  -a --address <address> The address to which the inputs will be sent.
  -s --send              Send the transaction, default is dry-run.
  -f --fee               Add a fee of 0.00010000 to the tx.
  -i --inputs <filename> Read the inputs from a file.

=cut
