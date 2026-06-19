#!/usr/bin/env perl
use strict;
use warnings;
use HTML::TreeBuilder ();

my $file = shift // '98_PresenceSimulation.pm';
open my $fh, '<:encoding(UTF-8)', $file or die "cannot open $file: $!\n";
local $/;
my $text = <$fh>;
close $fh;

my @checks = (
    [EN => qr/=begin html\s*\n(.*?)\n=end html/s],
    [DE => qr/=begin html_DE\s*\n(.*?)\n=end html_DE/s],
);
print "FHEM commandref-compatible single-module check\n";
for my $entry (@checks) {
    my ($lang, $pattern) = @$entry;
    my ($html) = $text =~ $pattern;
    die "$lang commandref block missing\n" if !defined $html;
    die "$lang root anchor missing\n" if $html !~ /<a\s+id="PresenceSimulation"><\/a>/;
    my @ids = $html =~ /\bid="([^"]+)"/g;
    my %seen;
    for my $id (@ids) {
        die "$lang duplicate id: $id\n" if $seen{$id}++;
    }
    my $tree = HTML::TreeBuilder->new;
    $tree->parse_content($html);
    $tree->eof;
    $tree->delete;
    print "$lang: block found, root anchor found, " . scalar(@ids) . " unique ids\n";
    print "$lang HTML::TreeBuilder parse PASS\n";
}
print "Result: PASS\n";
