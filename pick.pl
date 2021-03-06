#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;

use Algorithm::Combinatorics qw(combinations);
use FindBin;
use Getopt::Long;
use List::Util qw(first sum);
use Path::Tiny;
use Regexp::Common qw(number);
use Sort::Key qw(rnkeysort_inplace);

GetOptions('low|l' => \my $low) or die;

my $target = shift // 1.0;
die 'invalid target' unless $target =~ /^$RE{num}{real}{-sign=>''}$/;

# amount | conf | priority | txid | vout | addr
my @in = grep { 7 <= @$_ and 1 > $_->[1] }
    map { [ $_, split /\s*\|\s*/ ] }
    path("$FindBin::Bin/utxo.txt")->lines({chomp => 1});

# 67 inputs usually fits within 10KB.
my $max_n = 67 < @in ? 67 : @in;

rnkeysort_inplace { $_->[1] } @in;

my $max_sum = sum(map $_->[1], @in[ 0 .. $max_n - 1 ]);
die "$max_sum < $target" if $target > $max_sum;

my $min_n = first {
    $target <= sum(map $_->[1], @in[ 0 .. $_ - 1 ])
} 1 .. $max_n;

say STDERR 'total inputs: ', 0+@in;

my $min_sum;
if ($low) {
    $min_sum = 0;
    *check = sub { return 1 if $target < $_[0] or $_[1] > $_[0] };
}
else {
    $min_sum = ~0;
    *check = sub { return 1 if $target > $_[0] or $_[1] < $_[0] };
}

SET_SIZE:
for my $n (reverse $min_n .. $max_n) {
    my $it = combinations([ 0 .. $#in ], $n);
    say STDERR "checking sets of $n inputs";
    while (my $c = $it->next) {
        my $sum = sum(map $in[$_]->[1], @$c);

        next if check($sum, $min_sum);

        $min_sum = $sum;
        say '-'x80;
        printf "sum: %.8f\n", $sum;
        say $in[$_]->[0] for @$c;

        last SET_SIZE if $target == $sum;
    }
}
