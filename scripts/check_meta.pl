#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP ();
use CPAN::Meta ();

my $file = shift // '98_PresenceSimulation.pm';
open my $fh, '<:encoding(UTF-8)', $file or die "cannot open $file: $!\n";
local $/;
my $text = <$fh>;
close $fh;

my ($version) = $text =~ /my\s+\$PRESENCE_SIM_VERSION\s*=\s*'([^']+)'/;
die "module version not found\n" if !defined $version;
my ($json) = $text =~ /=for\s+:application\/json;q=META\.json\s+98_PresenceSimulation\.pm\s*\n(.*?)\n=end\s+:application\/json;q=META\.json/s;
die "embedded META JSON not found\n" if !defined $json;
my $meta = JSON::PP->new->utf8(0)->decode($json);
die "META name mismatch\n" if ($meta->{name} // '') ne 'FHEM-PresenceSimulation';
die "META version mismatch\n" if ($meta->{version} // '') ne "v$version";
die "META release status mismatch\n" if ($meta->{release_status} // '') ne 'testing';
die "META author mismatch\n" if ref($meta->{author}) ne 'ARRAY' || ($meta->{author}[0] // '') ne 'Flachzange <>';
die "META support status mismatch\n" if ($meta->{x_support_status} // '') ne 'experimental';
CPAN::Meta->new($meta, { lazy_validation => 0 });
print "Embedded META JSON: PASS\n";
print "name: $meta->{name}\n";
print "version: $meta->{version}\n";
print "release_status: $meta->{release_status}\n";
print "CPAN::Meta validation: PASS\n";
