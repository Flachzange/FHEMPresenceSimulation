#!/usr/bin/env perl
use strict;
use warnings;
use Encode qw(decode FB_CROAK);
use JSON::PP ();

my $file = shift // '98_PresenceSimulation.pm';
open my $raw, '<:raw', $file or die "cannot open $file: $!\n";
local $/;
my $bytes = <$raw>;
close $raw;
die "CRLF/CR line endings found\n" if $bytes =~ /\r/;
my $text = decode('UTF-8', $bytes, FB_CROAK);
my ($code) = split /^=pod\s*$/m, $text, 2;
my ($version) = $text =~ /my\s+\$PRESENCE_SIM_VERSION\s*=\s*'([^']+)'/;
die "module version not found\n" if !defined $version;

my @long;
my $line_no = 0;
for my $line (split /\n/, $code, -1) {
    ++$line_no;
    push @long, $line_no if length($line) > 120;
}
die "code lines over 120 characters: @long\n" if @long;

my @subs = $code =~ /^sub\s+(PresenceSimulation_[A-Za-z0-9_]+)\b/mg;
my %subs;
for my $sub (@subs) { die "duplicate subroutine $sub\n" if $subs{$sub}++ }
die "Initialize callback missing\n" if !$subs{PresenceSimulation_Initialize};

for my $forbidden ('AnwSim_', 'openai\@christoph-evers.de') {
    die "forbidden legacy/contact text present: $forbidden\n" if $text =~ /\Q$forbidden\E/;
}
die "schema 3 missing\n" if $text !~ /PRESENCE_SIM_SCHEMA\s*=\s*3/;
die "safe default mode off missing\n" if $text !~ /mode\s*=>\s*'off'/;
die "rawSessionsTodayDiscarded missing\n" if $text !~ /rawSessionsTodayDiscarded/;
die "human-readable file size formatter missing\n" if $text !~ /PresenceSimulation_FormatFileSize/;
die "readingDevice fallback missing\n" if $text !~ /readingDevice/;
die "unbounded OFF retry guard missing\n" if $text !~ /PRESENCE_SIM_OFF_MAX_ATTEMPTS/;
die "delayed duration adjustment missing\n" if $text !~ /\$duration\s*-=\s*\$delayedMinutes/;

my ($meta_json) = $text =~ /=for\s+:application\/json;q=META\.json\s+98_PresenceSimulation\.pm\s*\n(.*?)\n=end\s+:application\/json;q=META\.json/s;
die "embedded META missing\n" if !defined $meta_json;
my $meta = JSON::PP->new->decode($meta_json);
die "embedded META version mismatch\n" if ($meta->{version} // '') ne "v$version";

for my $doc (qw(CHANGELOG.md README.md TESTING.md REVIEW-CHECKLIST.md)) {
    open my $fh, '<:encoding(UTF-8)', $doc or die "cannot open $doc: $!\n";
    local $/;
    my $content = <$fh>;
    close $fh;
    die "$doc does not mention current version $version\n" if $content !~ /\Q$version\E/;
}

die "generated dist directory must be empty or absent\n" if -d 'dist' && glob('dist/*');
my @generated = glob('98_PresenceSimulation_v*.pm 98_PresenceSimulation_CURRENT_v*.pm *.zip *.zip.sha256 *-ZIP-CHECK.txt');
die "generated release files found in repository root: @generated\n" if @generated;

print "UTF-8 and LF line endings: PASS\n";
print "Global PresenceSimulation subs: " . scalar(@subs) . " unique: PASS\n";
print "Code line length <= 120 before POD: PASS\n";
print "Legacy/migration prefix and former contact address absent: PASS\n";
print "Safe default mode off and schema 3 present: PASS\n";
print "readingDevice, bounded OFF retries, discarded sessions, and delayed-duration logic present: PASS\n";
print "Embedded META version consistent: PASS\n";
print "Generated release artifacts absent from source tree: PASS\n";
print "Static check result: PASS\n";
