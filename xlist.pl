#!/usr/bin/env perl
use 5.010;
use strict;
use warnings;

use Crypt::OpenSSL::Bignum;
use Crypt::OpenSSL::EC;
use Crypt::RIPEMD160;
use Digest::SHA qw(sha256);
use Encode::Base58::GMP;
use HTTP::Tiny;
use JSON::MaybeXS;

my $ua = HTTP::Tiny->new;

while (my $wif = shift @ARGV) {
    my $addr = eval { wif_to_addr($wif) } // next;

    my $url = "https://chain.so/api/v2/get_tx_unspent/BTC/$addr";
    my $res = $ua->get($url);
    die "$res->{content}\n$res->{status} $res->{reason}\n$url"
        unless $res->{success};

    my $data = eval { decode_utf8 $res->{content} };

    for my $tx (@{ $data->{data}{txs} // [] }) {
        my $btc  = $tx->{value};
        my $conf = $tx->{confirmations};
        my $pri  = $conf * $btc * 1e8;
        my $hash = $tx->{txid};
        my $vout = $tx->{output_no};
        say join ' | ', $btc, $conf, $pri, $hash, $vout, $addr, $wif;
    }

    sleep 1 if @ARGV;
}

exit;


sub wif_to_addr {
    my $wif = shift;

    my $bytes = pack 'H*', decode_base58($wif, 'bitcoin')->Rmpz_get_str(16);
    return unless "\x80" eq unpack 'a', $bytes;
    return unless substr $bytes, -4, ,4, '' eq sha256 sha256 $bytes;
    my $nid = 714;  # secp256k1
    my $ecgroup = Crypt::OpenSSL::EC::EC_GROUP::new_by_curve_name($nid);
    my $eckey = Crypt::OpenSSL::EC::EC_POINT::new($ecgroup);
    my $bn = Crypt::OpenSSL::Bignum->new_from_bin(unpack 'xa32', $bytes);
    Crypt::OpenSSL::EC::EC_POINT::mul($ecgroup, $eckey, $bn, \0, \0, \0);
    my $form = 34 == length($bytes)
        ? &Crypt::OpenSSL::EC::POINT_CONVERSION_COMPRESSED
        : &Crypt::OpenSSL::EC::POINT_CONVERSION_UNCOMPRESSED;
    $bytes = Crypt::OpenSSL::EC::EC_POINT::point2oct($ecgroup, $eckey, $form, \0);
    my $hash = "\0" . Crypt::RIPEMD160->hash(sha256 $bytes);
    my $checksum = unpack 'a4', sha256 sha256 $hash;
    my $addr = unpack 'H*', "$hash$checksum";

    return 1 . encode_base58("0x$addr", 'bitcoin');
}
