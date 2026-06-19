use strict;
use warnings;
use Test::More;
use FindBin;
use JSON::PP ();
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);

BEGIN {
    package Blocking;
    sub import { return }
    $INC{'Blocking.pm'} = 1;

    package FHEM::Meta;
    sub import { return }
    sub InitMod { return }
    sub SetInternals { return 1 }
    $INC{'FHEM/Meta.pm'} = 1;
}

package main;

use Time::HiRes qw(time);

our (%defs, %attr, $readingFnAttributes, $init_done);
our %PresenceSimulation_DATA;
our %TEST_ATTR;
our %TEST_READINGS;
our @TEST_TIMERS;
our @TEST_COMMANDS;
our @TEST_LOGS;
our @TEST_NOTIFY_DEVS;
our %TEST_EVENTS;
our %TEST_DISABLED;
our $TEST_COMMAND_ERROR;
$readingFnAttributes = '';
$init_done = 1;

sub AttrVal {
    my ($name, $attrName, $default) = @_;
    return $TEST_ATTR{$name}{$attrName} if exists $TEST_ATTR{$name}{$attrName};
    return $attr{$name}{$attrName} if exists $attr{$name}{$attrName};
    return $default;
}
sub ReadingsVal {
    my ($name, $reading, $default) = @_;
    return exists $TEST_READINGS{$name}{$reading} ? $TEST_READINGS{$name}{$reading} : $default;
}
sub ReadingsNum {
    my ($name, $reading, $default) = @_;
    my $value = ReadingsVal($name, $reading, $default);
    return $value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/ ? 0 + $value : $default;
}
sub readingsBeginUpdate { return }
sub readingsEndUpdate   { return }
sub readingsBulkUpdate {
    my ($hash, $reading, $value) = @_;
    $TEST_READINGS{$hash->{NAME}}{$reading} = $value;
    return;
}
sub readingsBulkUpdateIfChanged { goto &readingsBulkUpdate }
sub readingsSingleUpdate {
    my ($hash, $reading, $value) = @_;
    $TEST_READINGS{$hash->{NAME}}{$reading} = $value;
    return;
}
sub readingsDelete { return }
sub InternalTimer {
    push @TEST_TIMERS, [@_];
    return;
}
sub RemoveInternalTimer {
    my ($hash, $fn) = @_;
    @TEST_TIMERS = grep {
        my $same_hash = ref($_->[2]) && ref($hash) && $_->[2] == $hash;
        my $same_fn = !defined $fn || $_->[1] eq $fn;
        !($same_hash && $same_fn);
    } @TEST_TIMERS;
    return;
}
sub Log3 { push @TEST_LOGS, [@_]; return }
sub BlockingCall { die 'BlockingCall must not be reached by these self-tests' }
sub BlockingKill { return }
sub BlockingStart { return }
sub CommandSet {
    my ($client, $command) = @_;
    push @TEST_COMMANDS, $command;
    return $TEST_COMMAND_ERROR;
}
sub IsDisabled {
    my ($name) = @_;
    return $TEST_DISABLED{$name} if exists $TEST_DISABLED{$name};
    return AttrVal($name, 'disable', 0) ? 1 : 0;
}
sub setNotifyDev {
    my ($hash, $devices) = @_;
    push @TEST_NOTIFY_DEVS, $devices;
    return;
}
sub deviceEvents {
    my ($dev, $addStateEvent) = @_;
    return $TEST_EVENTS{$dev->{NAME}};
}
sub addToDevAttrList { require Carp; Carp::confess('PresenceSimulation must not call addToDevAttrList') }
sub FileRead {
    my ($args) = @_;
    my $file = $args->{FileName};
    open my $fh, '<', $file or return ("cannot read $file: $!");
    local $/;
    my $content = <$fh>;
    close $fh;
    return (undef, $content);
}
sub FileWrite {
    my ($args, $content) = @_;
    my $file = $args->{FileName};
    open my $fh, '>', $file or return "cannot write $file: $!";
    print {$fh} $content;
    close $fh or return "cannot close $file: $!";
    return;
}
sub fhem { return }
sub EvalSpecials {
    my ($text, %specials) = @_;
    for my $key (sort { length($b) <=> length($a) } keys %specials) {
        (my $placeholder = $key) =~ s/^%/\$/;
        $text =~ s/\Q$placeholder\E/$specials{$key}/g;
    }
    return $text;
}
sub AnalyzeCommandChain {
    my ($client, $command) = @_;
    push @TEST_COMMANDS, $command;
    return;
}

my $module = "$FindBin::Bin/../98_PresenceSimulation.pm";
my $loaded = do $module;
die "Could not load $module: $@ $!" if !$loaded;

ok(defined &main::time,
    'test harness exposes Time::HiRes::time in package main before module compilation');
{
    my $state = PresenceSimulation_EmptyState('HiResEpoch');
    ok(PresenceSimulation_IsIntegerInRange($state->{lastCoverageTick}, 0, undef),
        'empty state stores lastCoverageTick as an integer with Time::HiRes::time imported');
    ok(!exists $state->{lastDbLogImportAttemptDate},
        'fresh runtime state omits the unused former import-attempt date');
}

{
    is_deeply(
        PresenceSimulation_EmptyConfig(),
        { byDevice => {}, byReadingDevice => {}, order => [], globalBlocks => [], ready => 0 },
        'empty configuration helper returns the canonical configuration frame',
    );
    my $instance = PresenceSimulation_NewInstanceData('ConstructorTest');
    is($instance->{raw}{deviceName}, 'ConstructorTest',
        'instance constructor initializes raw data for the requested device name');
    is($instance->{state}{deviceName}, 'ConstructorTest',
        'instance constructor initializes runtime state for the requested device name');
    is_deeply(
        PresenceSimulation_EmptyRawDay('2026-06-17'),
        {
            weekday => PresenceSimulation_WeekdayForDate('2026-06-17'),
            trainingSeconds => 0, discardedSessions => 0, sessions => {},
        },
        'raw-day helper returns the canonical empty day structure',
    );
    is(PresenceSimulation_OneLineError("first\nsecond\r\nthird"), 'first second third',
        'one-line error helper removes embedded line breaks');
    is(PresenceSimulation_FormatFileSize(1000), '1000 B',
        'file-size helper keeps values through 1000 bytes in B');
    is(PresenceSimulation_FormatFileSize(1001), '1.0 kB',
        'file-size helper switches to decimal kB above 1000 bytes');
    is(PresenceSimulation_FormatFileSize(1_250_000), '1.2 MB',
        'file-size helper selects MB for larger files');
    is(PresenceSimulation_FormatBlockBoundary(615), '10:15',
        'block-boundary helper formats an ordinary retry deadline');
    is(PresenceSimulation_FormatBlockBoundary(1440), '24:00',
        'block-boundary helper preserves the end of the final daily block');
}

sub make_instance {
    my ($name, %attrs) = @_;
    my $hash = { NAME => $name, TYPE => 'PresenceSimulation', helper => {} };
    $defs{$name} = $hash;
    $TEST_ATTR{$name} = {
        trainingSource    => 'events',
        trainingDays      => 3,
        retentionDays     => 90,
        minTrainingMinutes => 1200,
        binMinutes        => 15,
        weekdaySpecific   => 0,
        saveInterval      => 300,
        %attrs,
    };
    $PresenceSimulation_DATA{$name} = PresenceSimulation_NewInstanceData($name);
    return $hash;
}

sub raw_day {
    my (%args) = @_;
    return {
        weekday         => 1,
        trainingSeconds => $args{trainingSeconds} // 0,
        sessions        => $args{sessions} // {},
        (defined $args{source} ? (source => $args{source}) : ()),
        (defined $args{importedFromDbLog}
            ? (importedFromDbLog => $args{importedFromDbLog}) : ()),
    };
}

{
    my @dates = qw(2026-06-01 2026-06-02 2026-06-03);
    my $data = {
        config => { order => ['ModelDevice'] },
        raw => {
            days => {
                $dates[0] => { sessions => { ModelDevice => [
                    { startMinute => 602, durationMinutes => 5 },
                ] } },
                $dates[1] => { sessions => {} },
                $dates[2] => { sessions => { ModelDevice => [
                    { startMinute => 610, durationMinutes => 7 },
                ] } },
            },
        },
    };
    my $section = PresenceSimulation_BuildModelSection($data, \@dates, 15);
    my $bin = $section->{devices}{ModelDevice}{bins}{40};
    cmp_ok(abs($bin->{probability} - (2 / 3)), '<', 0.0000001,
        'model probability is days with at least one start divided by usable days');
    is($bin->{daysWithStart}, 2,
        'model counts each date only once for the block probability');
    is_deeply($bin->{startOffsets}, [2, 10],
        'model retains historical minute positions inside the time block');
    is_deeply($bin->{durations}, [5, 7],
        'model retains empirical durations for the time block');
    ok(!exists $section->{devices}{ModelDevice}{totalSessions},
        'device model omits the redundant per-device totalSessions copy');
}

{
    my $name = 'DiscardedToday';
    my $hash = make_instance($name);
    my $dev = 'ShortSessionDevice';
    my $date = PresenceSimulation_Date(CORE::time());
    my $cfg = {
        device => $dev,
        minDuration => 1,
        maxDuration => 240,
    };
    $PresenceSimulation_DATA{$name}{state}{activeSessions}{$dev} = {
        startedAt => CORE::time(),
        date => $date,
        weekday => PresenceSimulation_WeekdayForDate($date),
        startMinute => PresenceSimulation_MinuteOfDay(CORE::time()),
    };

    PresenceSimulation_ProcessTrainingTransition($hash, $cfg, 'off');

    is($PresenceSimulation_DATA{$name}{raw}{days}{$date}{discardedSessions}, 1,
        'discarded event-training session is counted in its raw-data calendar day');
    is($PresenceSimulation_DATA{$name}{state}{discardedSessions}, 1,
        'existing cumulative discarded-session counter remains updated');
    is($TEST_READINGS{$name}{rawSessionsTodayDiscarded}, 1,
        'rawSessionsTodayDiscarded exposes the current raw-day count');
    is($TEST_READINGS{$name}{rawSessionsToday}, 0,
        'discarded session is not counted as a completed raw session');
}

{
    my $name = 'BlockEvaluationError';
    my $hash = make_instance($name);
    my $device = 'BlockedDevice';
    my $date = PresenceSimulation_Date(CORE::time());
    my $at1000 = PresenceSimulation_EpochFromDateTime("$date 10:00:00");
    my $cfg = {
        device => $device,
        blocks => [],
    };
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$device],
        byDevice => { $device => $cfg },
        globalBlocks => [
            {
                attrName => 'globalBlock01',
                expression => '[MissingDevice:state] > 5000',
                parseError => 'test evaluation failure',
            },
        ],
        ready => 1,
    };
    $PresenceSimulation_DATA{$name}{model} = {
        binMinutes => 15,
        allDays => { validDates => ['2026-06-01'], devices => {} },
        weekdays => {},
    };
    $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40} = {
        plannedStartMinute => 600,
        durationMinutes => 10,
        probabilityHistorical => 0.5,
        probabilityEffective => 0.5,
        probabilityFactor => 1,
        historyStarts => 1,
        historyDays => 2,
        historyPositionSamples => 1,
        modelType => 'all-days',
        createdAt => CORE::time(),
    };

    PresenceSimulation_RunDryRun($hash, $at1000, $date);

    like($TEST_READINGS{$name}{simulationEvent}, qr/condition=globalBlock01 reason=evaluationError/,
        'run-time block evaluation failure emits the compact static reason');
    is($TEST_READINGS{$name}{lastErrorSource}, 'blockCondition',
        'block evaluation failure uses the existing subsystem error readings');
    like($TEST_READINGS{$name}{lastError}, qr/globalBlock01.*test evaluation failure/,
        'block evaluation error reading retains the detailed diagnostic');
}

{
    my $name = 'ProbabilityDiagnostics';
    my $hash = make_instance($name, probabilityFactor => 1.5);
    $PresenceSimulation_DATA{$name}{config}{byDevice}{DiagnosticDevice} = {};
    $PresenceSimulation_DATA{$name}{model} = {
        binMinutes => 15,
        allDays => {
            validDates => [qw(2026-06-01 2026-06-02 2026-06-03 2026-06-04 2026-06-05)],
            devices => {
                DiagnosticDevice => {
                    bins => {
                        40 => {
                            probability => 0.4,
                            daysWithStart => 2,
                            startOffsets => [2, 10],
                        },
                    },
                },
            },
        },
        weekdays => {},
    };
    is(
        PresenceSimulation_GetProbability($hash, 'DiagnosticDevice', '10:00', undef),
        'DiagnosticDevice Alle Tage 10:00: historical block 40.00%, factor 1.500, effective block 60.00%, days with start 2 of 5, start-position samples 2',
        'probability diagnostics distinguish historical and factor-adjusted block probability',
    );
}

{
    my $name = 'SingleBlockPlan';
    my $hash = make_instance($name, probabilityFactor => 1.5);
    my $device = 'PlannedDevice';
    my $cfg = {
        device => $device, reading => 'state',
        onPattern => '^on$', offPattern => '^off$',
        onRe => qr/^on$/, offRe => qr/^off$/,
        onCommand => 'on', offCommand => 'off',
        minDuration => 1, maxDuration => 240,
    };
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$device], byDevice => { $device => $cfg }, globalBlocks => [], ready => 1,
    };
    $PresenceSimulation_DATA{$name}{model} = {
        binMinutes => 15,
        allDays => {
            validDates => [qw(2026-06-01 2026-06-02 2026-06-03 2026-06-04 2026-06-05)],
            devices => {
                $device => {
                    allDurations => [7],
                    bins => {
                        40 => {
                            probability => 0.8,
                            daysWithStart => 4,
                            durations => [7],
                            startOffsets => [2, 10],
                        },
                    },
                },
            },
        },
        weekdays => {},
    };
    my $date = PresenceSimulation_Date(CORE::time());
    my $at1000 = PresenceSimulation_EpochFromDateTime("$date 10:00:00");
    my @draws = (0.5, 0.9);
    delete $TEST_READINGS{$name}{simulationEvent};
    {
        no warnings 'redefine';
        local *PresenceSimulation_Random = sub {
            die 'unexpected additional random draw' if !@draws;
            return shift @draws;
        };
        PresenceSimulation_RunDryRun($hash, $at1000, $date);
        my $plan = $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40};
        ok($plan, 'one successful block decision creates a pending dry-run plan');
        is($plan->{plannedStartMinute}, 610,
            'pending plan uses a sampled historical minute position inside the block');
        ok(!exists $TEST_READINGS{$name}{simulationEvent},
            'pending plan emits no event before its selected start minute');
        my ($valid, $error) = PresenceSimulation_ValidatePersistedData(
            $hash, 'state', $PresenceSimulation_DATA{$name}{state},
        );
        ok($valid && !defined $error,
            'pending block plan is valid persistent runtime state');

        my $roundTripState = JSON::PP->new->decode(
            JSON::PP->new->canonical(1)->encode($PresenceSimulation_DATA{$name}{state})
        );
        $PresenceSimulation_DATA{$name}{state} = $roundTripState;
        PresenceSimulation_NormalizeInstanceData($hash);
        is(
            $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40}{plannedStartMinute},
            610,
            'pending block plan survives a persistence-style JSON round trip',
        );

        PresenceSimulation_RunDryRun($hash, $at1000 + 9 * 60, $date);
        ok(!exists $TEST_READINGS{$name}{simulationEvent},
            'pending plan waits through earlier minutes without another probability decision');
        PresenceSimulation_RunDryRun($hash, $at1000 + 10 * 60, $date);
    }
    is(scalar @draws, 0,
        'block decision and historical start-position selection are each drawn only once');
    like(
        $TEST_READINGS{$name}{simulationEvent},
        qr/action=on .*pHistorical=80\.00% .*pBlock=100\.00% .*factor=1\.500 .*planned=10:10 .*positionSamples=2/,
        'simulationEvent reports historical probability, effective probability, factor and planned time',
    );
    ok($PresenceSimulation_DATA{$name}{state}{dryPlayedBins}{$date}{$device}{40},
        'executed plan consumes the device/time-bin pair');
    ok(!exists $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40},
        'executed plan is removed from pending runtime state');
    is($PresenceSimulation_DATA{$name}{state}{dryManaged}{$device}{durationMinutes}, 7,
        'executed plan starts one virtual session with the sampled duration');
    is_deeply(
        [sort keys %{$PresenceSimulation_DATA{$name}{state}{dryManaged}{$device}}],
        [qw(durationMinutes modelType offDue)],
        'dry-run runtime state contains only fields used by dry-run processing',
    );
}

{
    my $name = 'PendingBlockedDryRun';
    my $hash = make_instance($name, eventFn => 'set EventSink text $EVENT');
    my $device = 'BlockedPlanDevice';
    my $date = PresenceSimulation_Date(CORE::time());
    my $at1000 = PresenceSimulation_EpochFromDateTime("$date 10:00:00");
    my ($block, $blockError) = PresenceSimulation_ParseBlockCondition(
        'globalBlock01', '[Weather:brightness] > 5000', 'global',
    );
    ok(!defined $blockError, 'pending-block test condition parses successfully');
    my $cfg = { device => $device, blocks => [] };
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$device], byDevice => { $device => $cfg },
        globalBlocks => [$block], ready => 1,
    };
    $PresenceSimulation_DATA{$name}{model} = {
        binMinutes => 15,
        allDays => { validDates => ['2026-06-01'], devices => {} },
        weekdays => {},
    };
    $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40} = {
        plannedStartMinute => 600, durationMinutes => 20,
        probabilityHistorical => 0.4, probabilityEffective => 0.4,
        probabilityFactor => 1, historyStarts => 4, historyDays => 10,
        historyPositionSamples => 4, modelType => 'all-days',
        createdAt => CORE::time(),
    };
    $TEST_READINGS{Weather}{brightness} = 6000;
    @TEST_COMMANDS = ();

    PresenceSimulation_RunDryRun($hash, $at1000, $date);

    like(
        $TEST_READINGS{$name}{simulationEvent},
        qr/action=blocked .*planned=10:00 .*pending=1 retryUntil=10:15 .*condition=globalBlock01/,
        'first blocked check reports a pending plan and its block deadline',
    );
    is(scalar @TEST_COMMANDS, 1,
        'first blocked check invokes eventFn exactly once');
    ok(
        $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40}{blockNotified},
        'blocked plan remains persisted with its notification marker',
    );
    ok(!$PresenceSimulation_DATA{$name}{state}{dryPlayedBins}{$date}{$device}{40},
        'pending blocked plan does not consume the time block yet');
    my ($valid, $error) = PresenceSimulation_ValidatePersistedData(
        $hash, 'state', $PresenceSimulation_DATA{$name}{state},
    );
    ok($valid && !defined $error,
        'pending blocked plan is valid schema-3 runtime state');
    my $roundTripState = JSON::PP->new->decode(
        JSON::PP->new->canonical(1)->encode($PresenceSimulation_DATA{$name}{state})
    );
    $PresenceSimulation_DATA{$name}{state} = $roundTripState;
    PresenceSimulation_NormalizeInstanceData($hash);
    ok(
        $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40}{blockNotified},
        'persisted blocked notification marker survives a reload-style round trip',
    );

    PresenceSimulation_RunDryRun($hash, $at1000 + 60, $date);
    is(scalar @TEST_COMMANDS, 1,
        'continued blocking emits no repeated blocked event');

    $TEST_READINGS{Weather}{brightness} = 1000;
    PresenceSimulation_RunDryRun($hash, $at1000 + 5 * 60, $date);
    is(scalar @TEST_COMMANDS, 2,
        'later release invokes eventFn exactly once for the ON event');
    like(
        $TEST_READINGS{$name}{simulationEvent},
        qr/action=on duration=15min .*planned=10:00 started=10:05 delayed=5min/,
        'released plan reports reduced duration plus original and actual start times',
    );
    is($PresenceSimulation_DATA{$name}{state}{dryManaged}{$device}{durationMinutes}, 15,
        'delayed dry-run plan subtracts the five-minute wait from its runtime');
    is($PresenceSimulation_DATA{$name}{state}{dryManaged}{$device}{offDue}, $at1000 + 20 * 60,
        'delayed dry-run plan preserves the originally planned end time');
    ok(!exists $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40},
        'released plan is removed from pending runtime state');
    ok($PresenceSimulation_DATA{$name}{state}{dryPlayedBins}{$date}{$device}{40},
        'released plan consumes the time block after successful start');
}

{
    my $name = 'BlockedUntilBinEnd';
    my $hash = make_instance($name, eventFn => 'set EventSink text $EVENT');
    my $device = 'ExpiredBlockedPlan';
    my $date = PresenceSimulation_Date(CORE::time());
    my $at1000 = PresenceSimulation_EpochFromDateTime("$date 10:00:00");
    my ($block) = PresenceSimulation_ParseBlockCondition(
        'globalBlock01', '[WeatherEnd:brightness] > 5000', 'global',
    );
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$device], byDevice => { $device => { device => $device, blocks => [] } },
        globalBlocks => [$block], ready => 1,
    };
    $PresenceSimulation_DATA{$name}{model} = {
        binMinutes => 15,
        allDays => { validDates => ['2026-06-01'], devices => {} },
        weekdays => {},
    };
    $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40} = {
        plannedStartMinute => 600, durationMinutes => 20,
        probabilityHistorical => 0.4, probabilityEffective => 0.4,
        probabilityFactor => 1, historyStarts => 4, historyDays => 10,
        historyPositionSamples => 4, modelType => 'all-days',
        createdAt => CORE::time(),
    };
    $TEST_READINGS{WeatherEnd}{brightness} = 6000;
    @TEST_COMMANDS = ();

    PresenceSimulation_RunDryRun($hash, $at1000, $date);
    PresenceSimulation_RunDryRun($hash, $at1000 + 14 * 60, $date);
    is(scalar @TEST_COMMANDS, 1,
        'a continuously blocked plan reports only its initial blocked event');
    PresenceSimulation_RunDryRun($hash, $at1000 + 15 * 60, $date);
    is(scalar @TEST_COMMANDS, 1,
        'block expiry emits no second blocked event');
    ok(!exists $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40},
        'continuously blocked plan is discarded when its time block ends');
}

{
    my $name = 'PendingBlockedPlayback';
    my $hash = make_instance($name);
    my $device = 'PlaybackBlockedPlan';
    my $date = PresenceSimulation_Date(CORE::time());
    my $at1000 = PresenceSimulation_EpochFromDateTime("$date 10:00:00");
    my ($block) = PresenceSimulation_ParseBlockCondition(
        'globalBlock01', '[PlaybackWeather:brightness] > 5000', 'global',
    );
    my $cfg = {
        device => $device, readingDevice => $device, reading => 'state',
        onPattern => '^on$', offPattern => '^off$',
        onRe => qr/^on$/, offRe => qr/^off$/,
        onCommand => 'on', offCommand => 'off', blocks => [],
    };
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$device], byDevice => { $device => $cfg },
        globalBlocks => [$block], ready => 1,
    };
    $PresenceSimulation_DATA{$name}{model} = {
        binMinutes => 15,
        allDays => { validDates => ['2026-06-01'], devices => {} },
        weekdays => {},
    };
    $PresenceSimulation_DATA{$name}{state}{plannedBins}{$date}{$device}{40} = {
        plannedStartMinute => 600, durationMinutes => 20,
        probabilityHistorical => 0.4, probabilityEffective => 0.4,
        probabilityFactor => 1, historyStarts => 4, historyDays => 10,
        historyPositionSamples => 4, modelType => 'all-days',
        createdAt => CORE::time(),
    };
    $TEST_READINGS{$device}{state} = 'off';
    $TEST_READINGS{PlaybackWeather}{brightness} = 6000;
    @TEST_COMMANDS = ();

    PresenceSimulation_RunPlayback($hash, $at1000, $date);
    is(scalar @TEST_COMMANDS, 0,
        'blocked playback plan sends no device command');
    ok($PresenceSimulation_DATA{$name}{state}{plannedBins}{$date}{$device}{40}{blockNotified},
        'blocked playback plan remains pending');

    $TEST_READINGS{PlaybackWeather}{brightness} = 1000;
    PresenceSimulation_RunPlayback($hash, $at1000 + 3 * 60, $date);
    is_deeply(\@TEST_COMMANDS, ["$device on"],
        'released playback plan sends its ON command exactly once');
    like($TEST_READINGS{$name}{simulationEvent},
        qr/action=on duration=17min .*started=10:03 delayed=3min/,
        'released playback plan publishes the reduced duration and delayed ON event');
    is($PresenceSimulation_DATA{$name}{state}{managed}{$device}{durationMinutes}, 17,
        'delayed playback plan subtracts the three-minute wait from its runtime');
    is($PresenceSimulation_DATA{$name}{state}{managed}{$device}{offDue}, $at1000 + 20 * 60,
        'delayed playback plan preserves the originally planned end time');
}

{
    my $name = 'DelayedPlanExpired';
    my $hash = make_instance($name, eventFn => 'set EventSink text $EVENT');
    my $device = 'ExpiredBeforeRelease';
    my $date = PresenceSimulation_Date(CORE::time());
    my $at1000 = PresenceSimulation_EpochFromDateTime("$date 10:00:00");
    my ($block) = PresenceSimulation_ParseBlockCondition(
        'globalBlock01', '[ShortWeather:brightness] > 5000', 'global',
    );
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$device], byDevice => { $device => { device => $device, blocks => [] } },
        globalBlocks => [$block], ready => 1,
    };
    $PresenceSimulation_DATA{$name}{model} = {
        binMinutes => 15,
        allDays => { validDates => ['2026-06-01'], devices => {} },
        weekdays => {},
    };
    $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40} = {
        plannedStartMinute => 600, durationMinutes => 3,
        probabilityHistorical => 0.4, probabilityEffective => 0.4,
        probabilityFactor => 1, historyStarts => 4, historyDays => 10,
        historyPositionSamples => 4, modelType => 'all-days',
        createdAt => CORE::time(),
    };
    $TEST_READINGS{ShortWeather}{brightness} = 6000;
    @TEST_COMMANDS = ();

    PresenceSimulation_RunDryRun($hash, $at1000, $date);
    is(scalar @TEST_COMMANDS, 1,
        'short plan emits its one pending blocked event');
    like($TEST_READINGS{$name}{simulationEvent}, qr/action=blocked .*pending=1/,
        'short plan remains represented by the initial blocked event');

    $TEST_READINGS{ShortWeather}{brightness} = 1000;
    PresenceSimulation_RunDryRun($hash, $at1000 + 3 * 60, $date);
    is(scalar @TEST_COMMANDS, 1,
        'expired delayed plan emits no ON event when no full minute remains');
    like($TEST_READINGS{$name}{simulationEvent}, qr/action=blocked /,
        'expired delayed plan leaves the initial blocked event as the last event');
    ok(!exists $PresenceSimulation_DATA{$name}{state}{dryManaged}{$device},
        'expired delayed plan does not create a virtual managed session');
    ok(!exists $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{40},
        'expired delayed plan is removed from pending runtime state');
    ok($PresenceSimulation_DATA{$name}{state}{dryPlayedBins}{$date}{$device}{40},
        'expired delayed plan still consumes its time block without a new draw');
}

{
    my $name = 'SeparateReadingPlayback';
    my $hash = make_instance($name);
    my $device = 'TV_Command';
    my $cfg = {
        device => $device, onCommand => 'cmd_1', offCommand => 'cmd_2',
        readingDevice => 'KODI', reading => 'state',
        onPattern => '^opened$', offPattern => '^disconnected$',
        onRe => qr/^opened$/, offRe => qr/^disconnected$/,
        minDuration => 1, maxDuration => 240,
    };
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$device],
        byDevice => { $device => $cfg },
        byReadingDevice => { KODI => [$cfg] },
        globalBlocks => [], ready => 1,
    };
    my ($importDevices, $maxDuration) = PresenceSimulation_ImportDeviceDefinitions($hash);
    is(scalar @{$importDevices}, 1,
        'canonical import definition contains each logical device once');
    is($importDevices->[0]{readingDevice}, 'KODI',
        'canonical import definition retains the separate observation device');
    is($maxDuration, 240,
        'canonical import definition reports the largest configured duration');
    $PresenceSimulation_DATA{$name}{model} = {
        binMinutes => 15,
        allDays => {
            validDates => [qw(2026-06-01)],
            devices => {
                $device => {
                    allDurations => [1],
                    bins => {
                        40 => {
                            probability => 1, daysWithStart => 1,
                            durations => [1], startOffsets => [0],
                        },
                    },
                },
            },
        },
        weekdays => {},
    };
    my $date = PresenceSimulation_Date(CORE::time());
    my $at1000 = PresenceSimulation_EpochFromDateTime("$date 10:00:00");
    $TEST_READINGS{KODI}{state} = 'disconnected';
    delete $TEST_READINGS{TV_Command}{state};
    @TEST_COMMANDS = ();
    {
        no warnings 'redefine';
        local *PresenceSimulation_Random = sub { return 0 };
        PresenceSimulation_RunPlayback($hash, $at1000, $date);
    }
    is($TEST_COMMANDS[0], 'TV_Command cmd_1',
        'playback sends onCommand to the logical command device');
    is(
        $PresenceSimulation_DATA{$name}{state}{managed}{$device}{readingDevice},
        'KODI',
        'managed playback persists the separate observation device',
    );

    $TEST_READINGS{KODI}{state} = 'opened';
    PresenceSimulation_RunPlayback($hash, $at1000 + 60, $date);
    is($TEST_COMMANDS[-1], 'TV_Command cmd_2',
        'playback reads the separate observation device before sending offCommand to the command device');
}

{
    my $name = 'SingleBlockMiss';
    my $hash = make_instance($name);
    my $device = 'MissDevice';
    my $cfg = {
        device => $device, reading => 'state',
        onPattern => '^on$', offPattern => '^off$',
        onRe => qr/^on$/, offRe => qr/^off$/,
        onCommand => 'on', offCommand => 'off',
        minDuration => 1, maxDuration => 240,
    };
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$device], byDevice => { $device => $cfg }, globalBlocks => [], ready => 1,
    };
    $PresenceSimulation_DATA{$name}{model} = {
        binMinutes => 15,
        allDays => {
            validDates => [qw(2026-06-01 2026-06-02)],
            devices => {
                $device => {
                    allDurations => [5],
                    bins => {
                        44 => {
                            probability => 0.5, daysWithStart => 1,
                            durations => [5], startOffsets => [3],
                        },
                    },
                },
            },
        },
        weekdays => {},
    };
    my $date = PresenceSimulation_Date(CORE::time());
    my $at1100 = PresenceSimulation_EpochFromDateTime("$date 11:00:00");
    my @draws = (0.9);
    {
        no warnings 'redefine';
        local *PresenceSimulation_Random = sub {
            die 'probability was drawn more than once for one block' if !@draws;
            return shift @draws;
        };
        PresenceSimulation_RunDryRun($hash, $at1100, $date);
        PresenceSimulation_RunDryRun($hash, $at1100 + 60, $date);
    }
    is(scalar @draws, 0, 'a missed block decision is not repeated in later minutes');
    ok($PresenceSimulation_DATA{$name}{state}{dryPlayedBins}{$date}{$device}{44},
        'a missed decision consumes the block without creating a plan');
    ok(!exists $PresenceSimulation_DATA{$name}{state}{dryPlannedBins}{$date}{$device}{44},
        'a missed decision leaves no pending plan');
}

{
    my $name = 'EventHybrid';
    my $hash = make_instance($name, trainingSource => 'events');
    my @dates = PresenceSimulation_PreviousDates(3);
    $PresenceSimulation_DATA{$name}{config}{order} = ['DeviceHybrid'];
    $PresenceSimulation_DATA{$name}{config}{byDevice}{DeviceHybrid} = {};
    $PresenceSimulation_DATA{$name}{raw}{days}{$dates[0]} = raw_day(
        source => 'dblog', importedFromDbLog => 'OldDbLog', trainingSeconds => 86400,
        sessions => { DeviceHybrid => [ { startMinute => 60, durationMinutes => 10 } ] },
    );
    $PresenceSimulation_DATA{$name}{raw}{days}{$dates[1]} = raw_day(
        trainingSeconds => 72000,
        sessions => { DeviceHybrid => [ { startMinute => 120, durationMinutes => 20 } ] },
    );
    $PresenceSimulation_DATA{$name}{raw}{days}{$dates[2]} = raw_day(
        trainingSeconds => 60,
        sessions => { DeviceHybrid => [ { startMinute => 180, durationMinutes => 30 } ] },
    );

    PresenceSimulation_RebuildModel($hash);
    my $model = $PresenceSimulation_DATA{$name}{model};
    is_deeply(
        $model->{validDates},
        [@dates[0, 1]],
        'event mode uses retained DbLog days and sufficiently covered event days',
    );
    is($model->{sourceDays}{dblog}, 1, 'event mode counts one imported DbLog day');
    is($model->{sourceDays}{events}, 1, 'event mode counts one live event day');
    is($TEST_READINGS{$name}{effectiveTrainingDays}, 2,
        'effectiveTrainingDays reflects the mixed all-days model');
    is($model->{sessionCount}, 2,
        'mixed event model contains sessions from event and imported days');
    is($TEST_READINGS{$name}{modelSessions}, 2,
        'modelSessions reflects both retained data sources');
}

{
    my $name = 'DbLogAcquisition';
    my $hash = make_instance(
        $name,
        trainingSource => 'dblog',
        dbLogDevice    => 'DbLogA',
        trainingDays   => 4,
    );
    my @dates = PresenceSimulation_PreviousDates(4);
    $PresenceSimulation_DATA{$name}{raw}{days}{$dates[0]} = raw_day(
        source => 'dblog', importedFromDbLog => 'DbLogA', trainingSeconds => 86400,
    );
    $PresenceSimulation_DATA{$name}{raw}{days}{$dates[1]} = raw_day(
        trainingSeconds => 86400,
    );
    $PresenceSimulation_DATA{$name}{raw}{days}{$dates[2]} = raw_day(
        source => 'dblog', importedFromDbLog => 'DbLogB', trainingSeconds => 86400,
    );
    $PresenceSimulation_DATA{$name}{raw}{days}{$dates[3]} = raw_day(
        trainingSeconds => 60,
    );

    PresenceSimulation_RebuildModel($hash);
    my $model = $PresenceSimulation_DATA{$name}{model};
    is_deeply(
        $model->{validDates},
        [@dates[0, 1, 2]],
        'DbLog acquisition mode uses retained event and imported days from any DbLog device',
    );
    is($model->{sourceDays}{dblog}, 2,
        'DbLog acquisition mode reports retained imports independently of current dbLogDevice');
    is($model->{sourceDays}{events}, 1,
        'DbLog acquisition mode keeps sufficiently covered event days');
}

{
    my $name = 'SourceOnlyImportedMarker';
    my $hash = make_instance(
        $name,
        trainingSource => 'dblog',
        dbLogDevice    => 'DbLogA',
        trainingDays   => 1,
    );
    my ($date) = PresenceSimulation_PreviousDates(1);
    $PresenceSimulation_DATA{$name}{raw}{days}{$date} = raw_day(
        source => 'dblog', trainingSeconds => 60,
    );

    PresenceSimulation_RebuildModel($hash);
    is_deeply(
        $PresenceSimulation_DATA{$name}{model}{validDates},
        [],
        'source=dblog alone is not treated as an imported day',
    );
}

{
    my $name = 'ManualImportInEvents';
    my $hash = make_instance(
        $name,
        trainingSource => 'events',
        dbLogDevice    => 'DbLogManual',
    );
    $defs{DbLogManual} = { NAME => 'DbLogManual', TYPE => 'DbLog' };

    my @called;
    no warnings qw(redefine once);
    local *main::PresenceSimulation_StartDbLogImport = sub {
        @called = @_;
        return 'manual import dispatched';
    };

    my $result = PresenceSimulation_Set($hash, $name, 'importDbLog', '7');
    is($result, 'manual import dispatched',
        'manual importDbLog is accepted while trainingSource=events');
    is($called[1], 'DbLogManual', 'configured DbLog device is passed to importer');
    is($called[2], 7, 'requested import period is passed to importer');
    is($called[3], 'manual', 'manual import context is preserved');
}


{
    my $name = 'DirectManualImportInEvents';
    my $hash = make_instance(
        $name,
        trainingSource => 'events',
        dbLogDevice    => 'DbLogDirect',
        trainingDays   => 1,
        retentionDays  => 1,
    );
    $defs{DbLogDirect} = {
        NAME   => 'DbLogDirect',
        TYPE   => 'DbLog',
        dbconn => 'dbi:SQLite:dbname=/tmp/not-opened-by-parent.db',
        dbuser => '',
        HELPER => { TH => 'history' },
    };
    $TEST_ATTR{secDbLogDirect}{secret} = 'super-secret-db-password';
    $PresenceSimulation_DATA{$name}{config} = {
        order => ['DeviceDirect'],
        globalBlocks => [],
        ready => 1,
        byDevice => {
            DeviceDirect => {
                device => 'DeviceDirect', reading => 'state',
                onPattern => '^on$', offPattern => '^off$',
                minDuration => 1, maxDuration => 240,
            },
        },
    };

    my @blocking_args;
    no warnings qw(redefine once);
    local *main::BlockingCall = sub {
        @blocking_args = @_;
        return 4242;
    };

    my $result = PresenceSimulation_StartDbLogImport(
        $hash, 'DbLogDirect', 1, 'manual'
    );
    ok(!defined $result,
        'lower-level DbLog importer starts in event mode');
    is($hash->{helper}{importPid}, 4242,
        'event-mode manual import stores the blocking worker id');
    is($hash->{helper}{importContext}, 'manual',
        'event-mode manual import stores the manual context');
    is($blocking_args[0], 'PresenceSimulation_DbLogImportWorker',
        'event-mode manual import dispatches the normal DbLog worker');
    unlike($blocking_args[1], qr/super-secret-db-password|not-opened-by-parent/,
        'BlockingCall argument contains neither database password nor connection string');
    my $public_args = JSON::PP->new->decode($blocking_args[1]);
    ok(-e $public_args->{parameterFile},
        'DbLog credentials are passed through a separate secure parameter file');
    is((stat($public_args->{parameterFile}))[2] & 0777, 0600,
        'secure DbLog parameter file is restricted to the FHEM user');
    open my $param_fh, '<:encoding(UTF-8)', $public_args->{parameterFile} or die $!;
    local $/;
    my $private_args = JSON::PP->new->decode(<$param_fh>);
    close $param_fh;
    is($private_args->{dbpass}, 'super-secret-db-password',
        'worker parameter file contains the database password');
    PresenceSimulation_AbortRunningImport($hash, 'test cleanup', 'aborted');
    ok(!-e $public_args->{parameterFile},
        'aborting an import removes an unread secure parameter file');
}

{
    my $name = 'ManualImportWithoutDevice';
    my $hash = make_instance($name, trainingSource => 'events');
    my $result = PresenceSimulation_Set($hash, $name, 'importDbLog', '7');
    is($result, 'Attribute dbLogDevice must be set for DbLog imports',
        'manual import in event mode still requires an explicit dbLogDevice');
}

{
    my $name = 'NoAutoImportInEvents';
    my $hash = make_instance(
        $name,
        trainingSource => 'events',
        dbLogDevice    => 'DbLogManual',
    );
    @TEST_TIMERS = ();
    PresenceSimulation_ScheduleAutoImport($hash);
    is($TEST_READINGS{$name}{nextDbLogImport}, '-',
        'event mode does not schedule automatic DbLog imports');
    is(scalar @TEST_TIMERS, 0, 'no automatic import timer is installed in event mode');
}

{
    my $moduleHash = {};
    local $init_done = 0;
    PresenceSimulation_Initialize($moduleHash);
    ok(!exists $moduleHash->{AttrRenameMap},
        'module registers no attribute rename compatibility map');
    like($moduleHash->{AttrList}, qr/device\[0-9\]\[0-9\]:textField-long/,
        'public attribute list exposes generic device attributes');
    unlike($moduleHash->{AttrList}, qr/light\[0-9\]/,
        'public attribute list exposes no light attributes');
    ok(!defined &main::PresenceSimulation_LegacyAttributeMap,
        'legacy attribute map function is absent');
    ok(!defined &main::PresenceSimulation_MigrateLegacyAttributes,
        'legacy attribute migration function is absent');
}

{
    my $name = 'ErrorDefaults';
    my $hash = make_instance($name);
    delete @{$TEST_READINGS{$name}}{qw(lastError lastErrorSource lastErrorTime)};
    PresenceSimulation_InitializeErrorReadings($hash);
    is($TEST_READINGS{$name}{lastError}, 'none',
        'missing lastError is initialized to none');
    is($TEST_READINGS{$name}{lastErrorSource}, 'none',
        'missing lastErrorSource is initialized to none');
    is($TEST_READINGS{$name}{lastErrorTime}, 'none',
        'missing lastErrorTime is initialized to none');

    $TEST_READINGS{$name}{lastError} = 'test failure';
    $TEST_READINGS{$name}{lastErrorSource} = 'selftest';
    $TEST_READINGS{$name}{lastErrorTime} = '2026-06-15 21:00:00';
    PresenceSimulation_InitializeErrorReadings($hash);
    is($TEST_READINGS{$name}{lastError}, 'test failure',
        'initialization preserves an active error message');
    is($TEST_READINGS{$name}{lastErrorSource}, 'selftest',
        'initialization preserves an active error source');
    is($TEST_READINGS{$name}{lastErrorTime}, '2026-06-15 21:00:00',
        'initialization preserves an active error timestamp');

    PresenceSimulation_ClearError($hash, 'selftest');
    is($TEST_READINGS{$name}{lastError}, 'none',
        'clearing an error sets lastError to none');
    is($TEST_READINGS{$name}{lastErrorSource}, 'none',
        'clearing an error sets lastErrorSource to none');
    is($TEST_READINGS{$name}{lastErrorTime}, 'none',
        'clearing an error sets lastErrorTime to none');
}

{
    my $name = 'GenericDeviceConfig';
    my $hash = make_instance(
        $name,
        device01 => 'device=ConfiguredTarget reading=state onRegex=^on$ offRegex=^off$',
    );
    local $init_done = 0;
    my @errors = PresenceSimulation_BuildConfig($hash);
    is_deeply(\@errors, [], 'generic device01 configuration is accepted');
    is_deeply(
        $PresenceSimulation_DATA{$name}{config}{order},
        ['ConfiguredTarget'],
        'generic device attribute populates the device order',
    );
    is(
        $PresenceSimulation_DATA{$name}{config}{byDevice}{ConfiguredTarget}{readingDevice},
        'ConfiguredTarget',
        'readingDevice defaults to the command device',
    );
    is(
        $PresenceSimulation_DATA{$name}{config}{byReadingDevice}{ConfiguredTarget}[0]{device},
        'ConfiguredTarget',
        'default observation source is indexed for notifications',
    );
    is($TEST_READINGS{$name}{configuredDevices}, 1,
        'configuredDevices reports the number of valid generic devices');
}

{
    my $name = 'SeparateReadingDevice';
    my $hash = make_instance(
        $name,
        device01 => 'device=TV_Command onCommand=cmd_1 offCommand=cmd_2 reading=state readingDevice=KODI onRegex=^opened$ offRegex=^disconnected$ minDuration=1 maxDuration=240',
    );
    $defs{TV_Command} = { NAME => 'TV_Command', TYPE => 'DOIF' };
    $defs{KODI} = { NAME => 'KODI', TYPE => 'XBMC' };
    $TEST_READINGS{KODI}{state} = 'opened';
    my @errors = PresenceSimulation_BuildConfig($hash);
    is_deeply(\@errors, [], 'separate command and reading devices are accepted');
    my $cfg = $PresenceSimulation_DATA{$name}{config}{byDevice}{TV_Command};
    is($cfg->{readingDevice}, 'KODI', 'explicit readingDevice is retained');
    is($cfg->{onCommand}, 'cmd_1', 'onCommand remains attached to the command device');
    is($cfg->{offCommand}, 'cmd_2', 'offCommand remains attached to the command device');
    is($hash->{helper}{lastObserved}{TV_Command}, 'on',
        'initial state is read from the separate observation device');
    is(
        $PresenceSimulation_DATA{$name}{config}{byReadingDevice}{KODI}[0]{device},
        'TV_Command',
        'observation source maps back to the logical command device',
    );
    like(
        PresenceSimulation_ModelInfo($hash),
        qr/TV_Command: 0 sessions \(observed via KODI:state\)/,
        'modelInfo exposes a separate observation source',
    );
    my $relevant = PresenceSimulation_RelevantDeviceNames($hash);
    ok($relevant->{TV_Command} && $relevant->{KODI},
        'global definition changes track command and reading devices');

    $PresenceSimulation_DATA{$name}{state}{mode} = 'training';
    $TEST_READINGS{KODI}{state} = 'disconnected';
    $hash->{helper}{lastObserved}{TV_Command} = 'off';
    $TEST_READINGS{KODI}{state} = 'opened';
    $TEST_EVENTS{KODI} = ['opened'];
    PresenceSimulation_Notify($hash, $defs{KODI});
    ok($PresenceSimulation_DATA{$name}{state}{activeSessions}{TV_Command},
        'live event from readingDevice starts a session for the logical device');
    ok(!exists $PresenceSimulation_DATA{$name}{state}{activeSessions}{KODI},
        'live training does not use the observation device as the model key');
    is($TEST_READINGS{$name}{lastEvent}, 'KODI state opened',
        'lastEvent reports the actual observation source');
    my $fingerprintKODI = PresenceSimulation_ImportFingerprint($hash);
    $cfg->{readingDevice} = 'KODI_Alternative';
    my $fingerprintAlternative = PresenceSimulation_ImportFingerprint($hash);
    isnt($fingerprintKODI, $fingerprintAlternative,
        'DbLog import fingerprint includes the observation device');
    $cfg->{readingDevice} = 'KODI';

    delete $defs{KODI};
    my ($invalid, $error) = PresenceSimulation_ParseDeviceConfig(
        'device02',
        'device=TV_Command onCommand=cmd_1 offCommand=cmd_2 reading=state readingDevice=MissingSource onRegex=^opened$ offRegex=^disconnected$',
    );
    like($error, qr/readingDevice MissingSource does not exist/,
        'an unavailable readingDevice is rejected explicitly');
    delete $defs{TV_Command};
    delete $TEST_EVENTS{KODI};
}

{
    my $name = 'EventFnRawMsg';
    my $hash = make_instance($name, eventFn => 'msg @Bewohner $EVENT');
    my $event = '2026-06-15T21:20:00 mode=dryrun device=KitchenDevice action=on reason="door open"';
    @TEST_COMMANDS = ();
    PresenceSimulation_CallEventFn(
        $hash,
        $event,
        { mode => 'dryrun', device => 'KitchenDevice', action => 'on', eventDetails => 'timestamp=2026-06-15T21:20:00' },
    );
    is($TEST_COMMANDS[0], "msg \@Bewohner $event",
        'direct msg receives the unchanged raw EVENT expansion');
    unlike($TEST_COMMANDS[0], qr/msgPrio=|msgText=/,
        'eventFn does not inject MSG-specific parameters');
}

{
    my $name = 'EventFnExplicitMsgText';
    my $hash = make_instance(
        $name,
        eventFn => 'msg @Bewohner msgPrio="" msgText="$EVENT"',
    );
    my $event = '2026-06-15T21:20:00 mode=dryrun device=KitchenDevice action=on';
    @TEST_COMMANDS = ();
    PresenceSimulation_CallEventFn(
        $hash,
        $event,
        { mode => 'dryrun', device => 'KitchenDevice', action => 'on', eventDetails => '' },
    );
    is(
        $TEST_COMMANDS[0],
        qq{msg \@Bewohner msgPrio="" msgText="$event"},
        'explicit MSG quoting and parameters are preserved exactly',
    );
}

{
    my $name = 'BlockedEventSafeQuoting';
    my $hash = make_instance(
        $name,
        eventFn => 'msg @Bewohner msgPrio="" msgText="$EVENT"',
    );
    @TEST_COMMANDS = ();
    PresenceSimulation_EmitSimulationEvent(
        $hash,
        'dryrun',
        'KitchenDevice',
        'blocked',
        {
            durationMinutes => 38,
            blockCondition => 'globalBlock01',
            blockReason => 'matched',
            blockScope => 'global',
            blockActual => 'Weather:state="bright"',
            blockExpression => '[Weather:state] eq "bright"',
            modelType => 'all-days',
        },
    );
    like($TEST_READINGS{$name}{simulationEvent}, qr/action=blocked .*condition=globalBlock01/, 
        'normal blocked event identifies the matching condition');
    unlike($TEST_READINGS{$name}{simulationEvent}, qr/(?:scope|reason|actual|expression)=/, 
        'normal blocked event omits redundant and quoting-sensitive block details');
    unlike($TEST_READINGS{$name}{simulationEvent}, qr/"/, 
        'module-generated blocked event contains no embedded quotation marks');
    is(
        $TEST_COMMANDS[0],
        qq{msg \@Bewohner msgPrio="" msgText="$TEST_READINGS{$name}{simulationEvent}"},
        'eventFn receives a safely embeddable blocked event',
    );

    PresenceSimulation_EmitSimulationEvent(
        $hash,
        'dryrun',
        'KitchenDevice',
        'blocked',
        {
            blockCondition => 'globalBlock01',
            blockReason => 'evaluationError',
            modelType => 'all-days',
        },
    );
    like($TEST_READINGS{$name}{simulationEvent}, qr/condition=globalBlock01 reason=evaluationError/, 
        'evaluation failures add only the static evaluationError reason');
}

{
    my $name = 'EventFnOtherCommand';
    my $hash = make_instance($name, eventFn => 'set Dummy text $EVENT');
    my $event = '2026-06-15T21:20:00 mode=dryrun device=KitchenDevice action=off';
    @TEST_COMMANDS = ();
    PresenceSimulation_CallEventFn(
        $hash,
        $event,
        { mode => 'dryrun', device => 'KitchenDevice', action => 'off', eventDetails => '' },
    );
    is($TEST_COMMANDS[0], "set Dummy text $event",
        'non-msg command receives the unchanged raw EVENT value');
}

{
    my $hash = { NAME => 'PersistenceValidation' };
    my $raw = PresenceSimulation_EmptyRaw('PersistenceValidation');
    my ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'raw', $raw);
    ok($validated && !defined $error,
        'current raw persistence schema is accepted without conversion');

    my $date = '2026-06-17';
    $raw->{days}{$date} = {
        weekday => PresenceSimulation_WeekdayForDate($date),
        trainingSeconds => 0,
        sessions => {},
    };
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'raw', $raw);
    ok($validated && !defined $error,
        'older schema-3 raw days without discardedSessions remain loadable');
    $raw->{days}{$date}{discardedSessions} = -1;
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'raw', $raw);
    like($error, qr/discardedSessions must be a non-negative integer/,
        'raw-day discarded-session counter is validated');
    delete $raw->{days}{$date};

    my %missingSchema = %{$raw};
    delete $missingSchema{schemaVersion};
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'raw', \%missingSchema);
    ok(!defined $validated && $error eq 'missing schemaVersion',
        'persistence without schemaVersion is rejected');

    my %oldSchema = %{$raw};
    $oldSchema{schemaVersion} = 1;
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'raw', \%oldSchema);
    like($error, qr/^unsupported schema 1; expected 3$/,
        'older persistence schemas are rejected instead of migrated');

    my $state = PresenceSimulation_EmptyState('PersistenceValidation');
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    ok($validated && !defined $error,
        'current state persistence schema is accepted without conversion');

    my $legacyState = PresenceSimulation_EmptyState('PersistenceValidation');
    $legacyState->{moduleVersion} = '1.1.1';
    delete @{$legacyState}{qw(plannedBins dryPlannedBins)};
    ($validated, $error) = PresenceSimulation_ValidatePersistedData(
        $hash, 'state', $legacyState,
    );
    ok($validated && !defined $error,
        'schema-3 state from version 1.1.1 remains loadable without planning maps');

    my $planDate = PresenceSimulation_Date(CORE::time());
    $state->{plannedBins}{$planDate}{DeviceA}{40} = {
        plannedStartMinute => 610, durationMinutes => 5,
        probabilityHistorical => 0.4, probabilityEffective => 0.6,
        probabilityFactor => 1.5, historyStarts => 2, historyDays => 5,
        historyPositionSamples => 2, modelType => 'all-days',
        createdAt => CORE::time(),
    };
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    ok($validated && !defined $error,
        'current state persistence accepts a complete pending block plan');
    $state->{plannedBins}{$planDate}{DeviceA}{40}{plannedStartMinute} = 1440;
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    like($error, qr/plannedStartMinute must be 0 through 1439/,
        'pending plan start minute is range-checked');
    $state->{plannedBins}{$planDate}{DeviceA}{40}{plannedStartMinute} = 610;
    $state->{plannedBins}{$planDate}{DeviceA}{40}{blockNotified} = 1;
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    ok($validated && !defined $error,
        'pending plan accepts the persisted one-time block notification marker');
    $state->{plannedBins}{$planDate}{DeviceA}{40}{blockNotified} = 2;
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    like($error, qr/blockNotified must be 0 or 1/,
        'pending plan block notification marker is range-checked');
}

{
    ok(!defined PresenceSimulation_EventFnSyntaxError('fn:oldHandler'),
        'eventFn has no compatibility-specific validation for former prefixes');
    ok(!defined PresenceSimulation_EventFnSyntaxError('%EVENT'),
        'eventFn has no compatibility-specific validation for former placeholders');
}

{
    my $init = {};
    local $init_done = 0;
    PresenceSimulation_Initialize($init);
    is($init->{DefFn}, \&PresenceSimulation_Define,
        'Initialize registers the renamed Define callback');
    is($init->{UndefFn}, \&PresenceSimulation_Undef,
        'Initialize registers the renamed Undef callback');
    is($init->{SetFn}, \&PresenceSimulation_Set,
        'Initialize registers the renamed Set callback');
    is($init->{GetFn}, \&PresenceSimulation_Get,
        'Initialize registers the renamed Get callback');
    is($init->{NotifyFn}, \&PresenceSimulation_Notify,
        'Initialize registers the renamed Notify callback');
    is($init->{AttrFn}, \&PresenceSimulation_Attr,
        'Initialize registers the renamed Attr callback');
    like($init->{AttrList}, qr/(?:^| )device\[0-9\]\[0-9\]:textField-long(?: |$)/,
        'regular AttrList contains the wildcard device attribute');
    like($init->{AttrList}, qr/(?:^| )device\[0-9\]\[0-9\]Block\[0-9\]\[0-9\]:textField-long(?: |$)/,
        'regular AttrList contains the wildcard device block attribute');
    ok(!exists $init->{NotifyOrderPrefix}, 'module does not override FHEM notification order without a dependency');
    like($init->{AttrList}, qr/(?:^| )disabledForIntervals:textField-long(?: |$)/,
        'regular AttrList supports the standard disabledForIntervals attribute');
    like($init->{AttrList}, qr/(?:^| )globalBlock\[0-9\]\[0-9\]:textField-long(?: |$)/,
        'regular AttrList contains the wildcard global block attribute');
}

{
    my $name = 'WildcardAttributeValidation';
    my $hash = make_instance($name);
    local $init_done = 0;
    is(PresenceSimulation_Attr('set', $name, 'device01', 'device=Target'), undef,
        'device01 is accepted without adding it to userattr');
    is(PresenceSimulation_Attr('set', $name, 'device01Block01', '[Target:state] eq "off"'), undef,
        'device01Block01 is accepted without adding it to userattr');
    is(PresenceSimulation_Attr('set', $name, 'globalBlock01', '[Presence:state] eq "present"'), undef,
        'globalBlock01 is accepted without adding it to userattr');
    is(PresenceSimulation_Attr('set', $name, 'device00', 'device=Target'),
        'device attributes must be numbered device01 through device30',
        'out-of-range wildcard device attribute is still rejected');
}

{
    is(
        PresenceSimulation_Define({}, 'OnlyOneArgument'),
        'Usage: define <name> PresenceSimulation',
        'Define usage names the new FHEM module type',
    );
}

{
    my $tmp = tempdir(CLEANUP => 1);
    local $TEST_ATTR{global}{modpath} = $tmp;
    my $name = 'UiDefaultDefine';
    my $hash = { NAME => $name, TYPE => 'PresenceSimulation', helper => {} };
    $defs{$name} = $hash;
    is(PresenceSimulation_Define($hash, "$name PresenceSimulation"), undef,
        'Define succeeds for UI default test instance');
    is(
        $hash->{devStateIcon},
        'off:rc_STOP training:rc_REC dryrun:rc_PLAY playback:rc_PLAYgreen',
        'Define applies the module-owned state icon mapping',
    );
    ok(!exists $TEST_ATTR{$name}{devStateIcon} && !exists $attr{$name}{devStateIcon},
        'state icon mapping is not written as a user attribute');
    RemoveInternalTimer($hash);
    delete $PresenceSimulation_DATA{$name};
    delete $defs{$name};
    delete $TEST_READINGS{$name};
}

{
    local $TEST_ATTR{global}{modpath} = '/tmp/presence-simulation-test';
    my $files = PresenceSimulation_FileNamesForName('FreshInstall', 0);
    is(
        $files->{raw},
        '/tmp/presence-simulation-test/FHEM/FhemUtils/PresenceSimulation_Raw_FreshInstall.json',
        'raw persistence filename uses the module prefix',
    );
    ok(!exists $files->{model}, 'no persistent model file is exposed');
    is(
        $files->{state},
        '/tmp/presence-simulation-test/FHEM/FhemUtils/PresenceSimulation_State_FreshInstall.json',
        'state persistence filename uses the module prefix',
    );

    my $raw = PresenceSimulation_EmptyRaw('FreshInstall');
    $raw->{moduleVersion} = '1.1.0';
    my ($validated, $error) = PresenceSimulation_ValidatePersistedData(
        { NAME => 'FreshInstall' }, 'raw', $raw,
    );
    ok($validated && !defined $error,
        'schema-3 raw data from module version 1.1.0 remains loadable');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    local $TEST_ATTR{global}{modpath} = $tmp;
    my $name = 'FileInfoUnits';
    my $hash = make_instance($name);
    my $files = PresenceSimulation_FileNames($hash);
    for my $entry ([raw => 1001], [state => 1_250_000]) {
        open my $fh, '>:raw', $files->{$entry->[0]} or die $!;
        print {$fh} 'x' x $entry->[1];
        close $fh;
    }
    my $info = PresenceSimulation_Get($hash, $name, 'fileInfo');
    like($info, qr/raw\s+.*\(1\.0 kB, modified /,
        'fileInfo uses kB above 1000 bytes');
    like($info, qr/state\s+.*\(1\.2 MB, modified /,
        'fileInfo selects a larger human-readable unit when appropriate');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    local $TEST_ATTR{global}{modpath} = $tmp;
    my $name = 'FreshInstall';
    my $dir = "$tmp/FHEM/FhemUtils";
    make_path($dir);

    my $raw = PresenceSimulation_EmptyRaw($name);
    $raw->{moduleVersion} = '1.1.0';
    $raw->{days}{'2026-06-14'} = {
        weekday => 0,
        trainingSeconds => 86400,
        sessions => {
            Device01 => [ { startMinute => 60, durationMinutes => 15 } ],
        },
    };
    my $state = PresenceSimulation_EmptyState($name);
    $state->{moduleVersion} = '1.1.0';
    $state->{mode} = 'off';

    my $json = JSON::PP->new->canonical(1);
    for my $part ([raw => $raw], [state => $state]) {
        my ($kind, $payload) = @{$part};
        my $file = "$dir/PresenceSimulation_" . ucfirst($kind) . "_${name}.json";
        open my $fh, '>', $file or die "Cannot write $file: $!";
        print {$fh} $json->encode($payload);
        close $fh;
    }

    my $hash = { NAME => $name, TYPE => 'PresenceSimulation', helper => {} };
    $defs{$name} = $hash;
    $PresenceSimulation_DATA{$name} = PresenceSimulation_NewInstanceData($name);

    PresenceSimulation_LoadAll($hash);
    is(
        $PresenceSimulation_DATA{$name}{raw}{days}{'2026-06-14'}{sessions}{Device01}[0]{durationMinutes},
        15,
        'module loads a current raw file under the PresenceSimulation filename',
    );
    is(
        $PresenceSimulation_DATA{$name}{state}{mode},
        'off',
        'module loads a current state file under the PresenceSimulation filename',
    );
}


{
    my $state = PresenceSimulation_EmptyState('SafeDefault');
    is($state->{mode}, 'off', 'new instances default to safe mode off');
}

{
    my $name = 'NoConfigCoverage';
    my $hash = make_instance($name, trainingSource => 'events');
    $PresenceSimulation_DATA{$name}{state}{mode} = 'training';
    $PresenceSimulation_DATA{$name}{state}{lastCoverageTick} = CORE::time() - 60;
    my @errors = PresenceSimulation_BuildConfig($hash);
    is_deeply(\@errors, ['At least one valid deviceNN attribute is required'],
        'an empty first-installation configuration is reported clearly');
    ok(!PresenceSimulation_ConfigReady($hash), 'empty configuration is not training-ready');
    @TEST_TIMERS = ();
    PresenceSimulation_Tick($hash);
    is_deeply($PresenceSimulation_DATA{$name}{raw}{days}, {},
        'event coverage is not recorded before a valid device is configured');
    is(PresenceSimulation_SetMode($hash, 'training'),
        'At least one valid deviceNN attribute is required',
        'training cannot be started without a valid device configuration');
}

{
    my $name = 'ReadyCoverage';
    my $hash = make_instance($name,
        device01 => 'device=ReadyTarget reading=state onRegex=^on$ offRegex=^off$');
    $defs{ReadyTarget} = { NAME => 'ReadyTarget', TYPE => 'dummy' };
    local $init_done = 0;
    my @errors = PresenceSimulation_BuildConfig($hash);
    is_deeply(\@errors, [], 'valid first-installation device configuration has no errors');
    ok(PresenceSimulation_ConfigReady($hash), 'valid device configuration is training-ready');
    is(PresenceSimulation_SetMode($hash, 'training'), undef,
        'training can be started explicitly after configuration');
    $PresenceSimulation_DATA{$name}{state}{lastCoverageTick} = CORE::time() - 60;
    local $init_done = 1;
    PresenceSimulation_Tick($hash);
    my $today = PresenceSimulation_Date(CORE::time());
    ok(($PresenceSimulation_DATA{$name}{raw}{days}{$today}{trainingSeconds} // 0) > 0,
        'valid event training records coverage');
}

{
    my $name = 'ManagedAttrGuard';
    my $hash = make_instance($name);
    $PresenceSimulation_DATA{$name}{state}{managed}{ManagedDevice} = {
        startedAt => CORE::time() - 60, offDue => CORE::time() + 60, durationMinutes => 2,
        bin => 1, weekday => PresenceSimulation_WeekdayIndex(CORE::time()), modelType => 'all-days',
        reading => 'state', onPattern => '^on$', offPattern => '^off$', offCommand => 'off',
    };
    like(
        PresenceSimulation_Attr('set', $name, 'device01', 'device=OtherDevice'),
        qr/Cannot change device or model configuration while playback devices are active/,
        'device configuration cannot be changed while playback owns a device',
    );
    like(
        PresenceSimulation_Attr('set', $name, 'binMinutes', '30'),
        qr/Cannot change device or model configuration while playback devices are active/,
        'model configuration cannot be changed while playback owns a device',
    );
}

{
    my $tmp = tempdir(CLEANUP => 1);
    local $TEST_ATTR{global}{modpath} = $tmp;
    my $name = 'ShutdownSafety';
    my $hash = make_instance($name);
    $PresenceSimulation_DATA{$name}{config} = {
        order => ['ShutdownDevice'], globalBlocks => [], ready => 1,
        byDevice => {
            ShutdownDevice => {
                device => 'ShutdownDevice', reading => 'state',
                onPattern => '^on$', offPattern => '^off$',
                onRe => qr/^on$/, offRe => qr/^off$/, offCommand => 'off',
            },
        },
    };
    $PresenceSimulation_DATA{$name}{state}{managed}{ShutdownDevice} = {
        startedAt => CORE::time() - 60, offDue => CORE::time() + 60, durationMinutes => 2,
        bin => 1, weekday => PresenceSimulation_WeekdayIndex(CORE::time()), modelType => 'all-days',
        reading => 'state', onPattern => '^on$', offPattern => '^off$', offCommand => 'off',
    };
    $TEST_READINGS{ShutdownDevice}{state} = 'on';
    @TEST_COMMANDS = ();
    @TEST_TIMERS = ([CORE::time()+60, 'PresenceSimulation_Tick', $hash, 0]);
    local $TEST_COMMAND_ERROR;
    PresenceSimulation_Shutdown($hash);
    ok(grep($_ eq 'ShutdownDevice off', @TEST_COMMANDS),
        'shutdown sends OFF to every managed playback device');
    is(scalar @TEST_TIMERS, 0, 'shutdown removes all module timers');
    is(scalar keys %{$PresenceSimulation_DATA{$name}{state}{managed}}, 1,
        'shutdown preserves managed ownership until OFF is confirmed');
    is($PresenceSimulation_DATA{$name}{state}{managed}{ShutdownDevice}{offAttempts}, 1,
        'shutdown records one bounded OFF attempt before saving');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    local $TEST_ATTR{global}{modpath} = $tmp;
    my $name = 'UndefSafety';
    my $hash = make_instance($name);
    $PresenceSimulation_DATA{$name}{state}{managed}{UndefDevice} = {
        startedAt => CORE::time() - 60, offDue => CORE::time() + 60, durationMinutes => 2,
        bin => 1, weekday => PresenceSimulation_WeekdayIndex(CORE::time()), modelType => 'all-days',
        reading => 'state', onPattern => '^on$', offPattern => '^off$', offCommand => 'off',
    };
    @TEST_COMMANDS = ();
    @TEST_TIMERS = ([CORE::time()+60, 'PresenceSimulation_SaveDirty', $hash, 0]);
    local $TEST_COMMAND_ERROR;
    PresenceSimulation_Undef($hash, '');
    ok(grep($_ eq 'UndefDevice off', @TEST_COMMANDS),
        'Undef sends OFF using the persisted managed-device snapshot');
    is(scalar @TEST_TIMERS, 0, 'Undef leaves no callback timer behind');
    ok(!exists $PresenceSimulation_DATA{$name}, 'Undef removes in-memory instance data');
}

{
    my $name = 'TeardownDirty';
    my $hash = make_instance($name);
    $hash->{helper}{teardown} = 1;
    @TEST_TIMERS = ();
    PresenceSimulation_MarkDirty($hash, 'state');
    is(scalar @TEST_TIMERS, 0, 'MarkDirty does not schedule a save timer during teardown');
    ok($PresenceSimulation_DATA{$name}{dirty}{state},
        'teardown still marks state dirty for an explicit final save');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    my $file = "$tmp/raw.json";
    my $backup = "$file.bak";
    my $name = 'BackupValidation';
    my $hash = make_instance($name);
    my $valid = PresenceSimulation_EmptyRaw($name);
    my $date = PresenceSimulation_Date(CORE::time() - 86400);
    $valid->{days}{$date} = {
        weekday => PresenceSimulation_WeekdayForDate($date),
        trainingSeconds => 3600,
        sessions => {},
    };
    my $json = JSON::PP->new->canonical(1);
    open my $bad, '>', $file or die $!;
    print {$bad} $json->encode({ schemaVersion => 3, days => [] });
    close $bad;
    open my $bak, '>', $backup or die $!;
    print {$bak} $json->encode($valid);
    close $bak;

    my ($loaded, $error) = PresenceSimulation_ReadJsonWithBackup($hash, 'raw', $file);
    ok($loaded && !defined $error,
        'a semantically invalid main file falls back to a validated backup');
    ok(exists $loaded->{days}{$date}, 'validated backup data is returned');
    my @corrupt = glob("$file.corrupt.*");
    is(scalar @corrupt, 1, 'the invalid main file is preserved as a corrupt archive');
    my ($restored) = PresenceSimulation_ReadJsonFile($file);
    ok(ref $restored->{days} eq 'HASH', 'validated backup is copied back to the main file');
    is((stat($file))[2] & 0777, 0600,
        'a restored persistence file is restricted to the FHEM user');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    my $file = "$tmp/atomic.json";
    open my $fh, '>', $file or die $!;
    print {$fh} '{}';
    close $fh;
    no warnings qw(redefine once);
    local *main::copy = sub { local $! = 13; return 0 };
    my $error = PresenceSimulation_WriteFileAtomic($file, '{"new":1}');
    like($error, qr/^backup copy .* failed:/,
        'atomic persistence reports a failed backup copy instead of silently continuing');
}

{
    my $hash = { NAME => 'NestedValidation' };
    my $date = PresenceSimulation_Date(CORE::time() - 86400);
    my $raw = PresenceSimulation_EmptyRaw('NestedValidation');
    $raw->{days}{$date} = {
        weekday => PresenceSimulation_WeekdayForDate($date),
        trainingSeconds => 60,
        sessions => { DeviceA => {} },
    };
    my ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'raw', $raw);
    like($error, qr/sessions for DeviceA must be an array/,
        'nested raw session containers are validated');

    $raw->{days}{$date}{sessions}{DeviceA} = [ { startMinute => 1440, durationMinutes => 1 } ];
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'raw', $raw);
    like($error, qr/startMinute must be 0 through 1439/,
        'nested raw session values are range-checked');

    my $state = PresenceSimulation_EmptyState('NestedValidation');
    $state->{managed}{DeviceA} = {
        startedAt => 1, offDue => 2, durationMinutes => 1, bin => 0,
        weekday => 1, modelType => 'all-days',
    };
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    like($error, qr/state\.managed\.DeviceA\.reading must be a non-empty scalar/,
        'managed playback state requires a complete stop-command snapshot');

    $state = PresenceSimulation_EmptyState('NestedValidation');
    $state->{managed}{DeviceA} = {
        startedAt => 1, offDue => 2, durationMinutes => 1, bin => 0,
        weekday => 1, modelType => 'all-days', reading => 'state',
        readingDevice => 'KODI', onPattern => '^opened$', offPattern => '^disconnected$',
        offCommand => 'cmd_2',
    };
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    ok($validated && !defined $error,
        'managed playback state accepts a separate observation-device snapshot');
    @{$state->{managed}{DeviceA}}{qw(stopping offAttempts offFailed offRetryDue offLastError)}
        = (1, 3, 1, 100, 'off not confirmed');
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    ok($validated && !defined $error,
        'managed playback state accepts persisted bounded OFF retry metadata');
    $state->{managed}{DeviceA}{offAttempts} = -1;
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    like($error, qr/offAttempts must be a non-negative integer/,
        'persisted OFF attempt counters are range-checked');
    $state->{managed}{DeviceA}{offAttempts} = 3;
    $state->{managed}{DeviceA}{readingDevice} = '';
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    like($error, qr/state\.managed\.DeviceA\.readingDevice must be a non-empty scalar/,
        'persisted readingDevice snapshots are validated when present');

    $state = PresenceSimulation_EmptyState('NestedValidation');
    $state->{playedBins}{$date}{DeviceA}{bad} = 1;
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    like($error, qr/bin bad must be a non-negative integer/,
        'nested played-bin state is validated');
}

{
    my $name = 'UnknownReconcile';
    my $hash = make_instance($name);
    my $cfg = {
        device => 'UnknownDevice', reading => 'state',
        onPattern => '^on$', offPattern => '^off$', onRe => qr/^on$/, offRe => qr/^off$/,
        offCommand => 'off',
    };
    $PresenceSimulation_DATA{$name}{config} = {
        order => ['UnknownDevice'], globalBlocks => [], ready => 1,
        byDevice => { UnknownDevice => $cfg },
    };
    $PresenceSimulation_DATA{$name}{state}{managed}{UnknownDevice} = {
        startedAt => 1, offDue => 2, durationMinutes => 1, bin => 0,
        weekday => 1, modelType => 'all-days', reading => 'state',
        onPattern => '^on$', offPattern => '^off$', offCommand => 'off',
    };
    delete $TEST_READINGS{UnknownDevice}{state};
    PresenceSimulation_ReconcileRuntimeState($hash);
    ok(exists $PresenceSimulation_DATA{$name}{state}{managed}{UnknownDevice},
        'unknown device state does not discard managed playback ownership');
    is($TEST_READINGS{$name}{lastErrorSource}, 'runtime',
        'unknown managed state is exposed as a runtime error');
    $TEST_READINGS{UnknownDevice}{state} = 'off';
    PresenceSimulation_ReconcileRuntimeState($hash);
    ok(!exists $PresenceSimulation_DATA{$name}{state}{managed}{UnknownDevice},
        'a definitely off device is removed from managed state');
}


{
    my $name = 'RestartResolvesFailedOff';
    my $hash = make_instance($name);
    my $dev = 'RestartOffDevice';
    my $cfg = {
        device => $dev, readingDevice => $dev, reading => 'state',
        onPattern => '^on$', offPattern => '^off$',
        onRe => qr/^on$/, offRe => qr/^off$/, offCommand => 'off',
    };
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$dev], globalBlocks => [], ready => 1,
        byDevice => { $dev => $cfg },
    };
    $PresenceSimulation_DATA{$name}{state}{managed}{$dev} = {
        startedAt => 1, offDue => 2, durationMinutes => 1, bin => 0,
        weekday => 1, modelType => 'all-days', readingDevice => $dev,
        reading => 'state', onPattern => '^on$', offPattern => '^off$',
        offCommand => 'off', stopping => 1, offAttempts => 3,
        offFailed => 1, offLastError => 'not confirmed',
    };
    $TEST_READINGS{$dev}{state} = 'off';
    PresenceSimulation_SetError($hash, "$dev did not confirm off after 3 attempts", 'playback');
    PresenceSimulation_ReconcileRuntimeState($hash);
    ok(!exists $PresenceSimulation_DATA{$name}{state}{managed}{$dev},
        'restart reconciliation releases a failed managed entry that is now definitely off');
    is($TEST_READINGS{$name}{lastError}, 'none',
        'restart reconciliation clears the resolved playback error');
}

{
    my $name = 'ManagedManualOn';
    my $hash = make_instance($name);
    my $cfg = {
        device => 'ManagedManualDevice', reading => 'state',
        onRe => qr/^on$/, offRe => qr/^off$/,
    };
    $PresenceSimulation_DATA{$name}{state}{managed}{ManagedManualDevice} = {
        startedAt => 1, offDue => CORE::time()+60, durationMinutes => 1, bin => 0,
        weekday => 1, modelType => 'all-days', reading => 'state',
        onPattern => '^on$', offPattern => '^off$', offCommand => 'off',
    };
    PresenceSimulation_ProcessPlaybackTransition($hash, $cfg, 'on');
    ok(exists $PresenceSimulation_DATA{$name}{state}{managed}{ManagedManualDevice},
        'unexpected ON feedback does not contradictorily discard managed state');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    local $TEST_ATTR{global}{modpath} = $tmp;
    my $name = 'NoModelFile';
    my $hash = make_instance($name);
    PresenceSimulation_MarkDirty($hash, qw(raw state));
    PresenceSimulation_SaveAll($hash, 1);
    my $files = PresenceSimulation_FileNames($hash);
    ok(-e $files->{raw}, 'force save writes the raw-data file');
    ok(-e $files->{state}, 'force save writes the runtime-state file');
    is((stat($files->{raw}))[2] & 0777, 0600,
        'raw persistence is restricted to the FHEM user');
    is((stat($files->{state}))[2] & 0777, 0600,
        'state persistence is restricted to the FHEM user');
    ok(!-e "$tmp/FHEM/FhemUtils/PresenceSimulation_Model_${name}.json",
        'no redundant model cache file is written');
}



{
    my $tmp = tempdir(CLEANUP => 1);
    local $TEST_ATTR{global}{modpath} = $tmp;
    my $name = 'ReloadRejectsOldSchema';
    my $hash = make_instance($name);
    $PresenceSimulation_DATA{$name}{raw}{schemaVersion} = 2;
    $PresenceSimulation_DATA{$name}{state}{schemaVersion} = 2;
    PresenceSimulation_ReloadTimer($hash);
    is($PresenceSimulation_DATA{$name}{raw}{schemaVersion}, 3,
        'reload does not preserve incompatible old-schema raw data in memory');
    is($PresenceSimulation_DATA{$name}{state}{schemaVersion}, 3,
        'reload does not preserve incompatible old-schema state data in memory');
}

{
    my $name = 'InvalidConfigForcesOff';
    my $hash = make_instance($name, trainingSource => 'events');
    $PresenceSimulation_DATA{$name}{state}{mode} = 'training';
    $PresenceSimulation_DATA{$name}{state}{activeSessions}{OldDevice} = {
        startedAt => CORE::time() - 60,
        date => PresenceSimulation_Date(CORE::time()),
        weekday => PresenceSimulation_WeekdayIndex(CORE::time()),
        startMinute => PresenceSimulation_MinuteOfDay(CORE::time() - 60),
    };
    PresenceSimulation_InitTimer($hash);
    is($PresenceSimulation_DATA{$name}{state}{mode}, 'off',
        'configuration errors force a non-off instance into safe mode off');
    is_deeply($PresenceSimulation_DATA{$name}{state}{activeSessions}, {},
        'configuration errors discard open event-training sessions');
    is($TEST_READINGS{$name}{lastErrorSource}, 'configuration',
        'invalid first-installation configuration is exposed as a configuration error');
}

{
    my $name = 'DisabledPlaybackSafety';
    my $hash = make_instance($name);
    $PresenceSimulation_DATA{$name}{config} = {
        order => ['DisabledDevice'], globalBlocks => [], ready => 1,
        byDevice => {
            DisabledDevice => {
                device => 'DisabledDevice', reading => 'state',
                onPattern => '^on$', offPattern => '^off$',
                onRe => qr/^on$/, offRe => qr/^off$/, offCommand => 'off',
            },
        },
    };
    $PresenceSimulation_DATA{$name}{state}{mode} = 'playback';
    $PresenceSimulation_DATA{$name}{state}{managed}{DisabledDevice} = {
        startedAt => CORE::time() - 60, offDue => CORE::time() + 60,
        durationMinutes => 2, bin => 1,
        weekday => PresenceSimulation_WeekdayIndex(CORE::time()), modelType => 'all-days',
        reading => 'state', onPattern => '^on$', offPattern => '^off$', offCommand => 'off',
    };
    $TEST_READINGS{DisabledDevice}{state} = 'on';
    local $TEST_DISABLED{$name} = 1;
    @TEST_COMMANDS = ();
    @TEST_TIMERS = ();
    PresenceSimulation_Tick($hash);
    ok(grep($_ eq 'DisabledDevice off', @TEST_COMMANDS),
        'the central disabled state triggers an OFF command for managed playback devices');
    ok($PresenceSimulation_DATA{$name}{state}{managed}{DisabledDevice}{stopping},
        'disabled playback remains tracked until the OFF state is confirmed');
}

{
    my $name = 'ExtendedPersistenceValidation';
    my $hash = { NAME => $name };
    my $date = PresenceSimulation_Date(CORE::time() - 86400);
    my $weekday = PresenceSimulation_WeekdayForDate($date);

    my $raw = PresenceSimulation_EmptyRaw($name);
    $raw->{days}{$date} = {
        weekday => $weekday,
        trainingSeconds => 60,
        sessions => {
            DeviceA => [ {
                startMinute => 1,
                durationMinutes => 2000,
                weekday => $weekday,
            } ],
        },
    };
    my ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'raw', $raw);
    ok($validated && !defined $error,
        'persistence accepts positive session durations longer than one day when configured');

    $raw->{deviceName} = 'OtherInstance';
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'raw', $raw);
    like($error, qr/deviceName OtherInstance does not match ExtendedPersistenceValidation/,
        'persistence rejects data belonging to another FHEM instance');

    my $state = PresenceSimulation_EmptyState($name);
    $state->{lastDbLogImportDate} = '2026-02-31';
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    like($error, qr/lastDbLogImportDate must be empty or a valid YYYY-MM-DD date/,
        'persisted DbLog import dates are validated');

    $state = PresenceSimulation_EmptyState($name);
    $state->{dryManaged}{DeviceA} = {
        offDue => 2, durationMinutes => 1,
    };
    ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    like($error, qr/dryManaged\.DeviceA\.modelType must be a non-empty scalar/,
        'dry-run runtime entries require their model metadata');
}


{
    my $name = 'RuntimeShapeCleanup';
    my $hash = make_instance($name);
    my $state = $PresenceSimulation_DATA{$name}{state};
    $state->{lastDbLogImportAttemptDate} = '2026-06-01';
    $state->{managed}{DeviceA} = {
        startedAt => 1, offDue => 120, durationMinutes => 2, bin => 4, weekday => 1,
        modelType => 'all-days', readingDevice => 'DeviceA', reading => 'state',
        onPattern => '^on$', offPattern => '^off$', offCommand => 'off',
        stopping => 0, offAttempts => 0, offFailed => 0, offLastError => '', offSentAt => 5,
    };
    $state->{dryManaged}{DeviceB} = {
        startedAt => 1, offDue => 120, durationMinutes => 2, bin => 4, weekday => 1,
        modelType => 'all-days', reading => 'unused', offCommand => 'unused',
    };
    PresenceSimulation_NormalizeInstanceData($hash);
    ok(!exists $state->{lastDbLogImportAttemptDate},
        'normalization removes the unused same-schema import-attempt date');
    ok(!grep { exists $state->{managed}{DeviceA}{$_} } qw(startedAt bin weekday offSentAt),
        'normalization removes unused metadata from managed playback entries');
    is_deeply(
        [sort keys %{$state->{dryManaged}{DeviceB}}],
        [qw(durationMinutes modelType offDue)],
        'normalization reduces old dry-run entries to their used fields',
    );
    my ($validated, $error) = PresenceSimulation_ValidatePersistedData($hash, 'state', $state);
    ok($validated && !defined $error,
        'cleaned runtime state remains valid under persistence schema 3');
}

{
    my $name = 'DisabledIntervalRecovery';
    my $hash = make_instance(
        $name,
        trainingSource => 'dblog',
        dbLogDevice => 'RecoveryDbLog',
        importTime => '03:05',
    );
    $defs{RecoveryDbLog} = { NAME => 'RecoveryDbLog', TYPE => 'DbLog' };
    $PresenceSimulation_DATA{$name}{config} = {
        order => ['RecoveryDevice'], globalBlocks => [], ready => 1,
        byDevice => { RecoveryDevice => { device => 'RecoveryDevice' } },
    };
    $hash->{helper}{wasDisabled} = 1;
    local $TEST_DISABLED{$name} = 0;
    @TEST_TIMERS = ();
    PresenceSimulation_Tick($hash);
    ok(
        grep($_->[1] eq 'PresenceSimulation_AutoImportTimer', @TEST_TIMERS),
        'automatic DbLog scheduling resumes after a disabled interval ends'
    );
    isnt($TEST_READINGS{$name}{nextDbLogImport}, '-',
        'nextDbLogImport is recalculated after disabled-interval recovery');
}

{
    my $tmp = tempdir(CLEANUP => 1);
    local $TEST_ATTR{global}{modpath} = $tmp;
    my $name = 'ValidateBeforeSave';
    my $hash = make_instance($name);
    my $date = PresenceSimulation_Date(CORE::time() - 86400);
    $PresenceSimulation_DATA{$name}{raw}{days}{$date} = {
        weekday => PresenceSimulation_WeekdayForDate($date),
        trainingSeconds => 60,
        sessions => { BrokenDevice => {} },
    };
    PresenceSimulation_MarkDirty($hash, 'raw');
    PresenceSimulation_SaveAll($hash, 0);
    is($TEST_READINGS{$name}{lastErrorSource}, 'persistence',
        'invalid internal persistence data is rejected before a file is overwritten');
    like($TEST_READINGS{$name}{lastError}, qr/validation failed before save/,
        'pre-save validation reports the structural error');
    ok(!-e PresenceSimulation_FileNames($hash)->{raw},
        'pre-save validation leaves no invalid raw file behind');
}


{
    my $name = 'StrictBinValidation';
    my $hash = make_instance($name);
    is(
        PresenceSimulation_Attr('set', $name, 'binMinutes', '0'),
        'binMinutes must be one of 1, 5, 10, 15, 20, 30, or 60',
        'binMinutes zero is rejected by the attribute handler',
    );
    is(
        PresenceSimulation_Attr('set', $name, 'binMinutes', '15'),
        undef,
        'a documented binMinutes value remains accepted',
    );
    my $error;
    eval { PresenceSimulation_BuildModelSection({ config => { order => [] }, raw => { days => {} } }, [], 0); 1 }
        or $error = $@;
    like($error, qr/binMinutes must be one of/,
        'model construction defensively rejects an invalid zero bin size');
}

{
    $defs{DurationDevice} = { NAME => 'DurationDevice', TYPE => 'dummy' };
    my ($valid_cfg, $valid_error) = PresenceSimulation_ParseDeviceConfig(
        'device01',
        'device=DurationDevice minDuration=1 maxDuration=1440'
    );
    ok($valid_cfg && !defined $valid_error,
        'maxDuration accepts the documented upper limit of 1440 minutes');
    my ($invalid_cfg, $invalid_error) = PresenceSimulation_ParseDeviceConfig(
        'device01',
        'device=DurationDevice minDuration=1 maxDuration=1441'
    );
    like($invalid_error, qr/maxDuration must be <= 1440/,
        'maxDuration above one day is rejected');
}

{
    my $name = 'BoundedOffRetries';
    my $hash = make_instance($name);
    my $dev = 'RetryDevice';
    my $cfg = {
        device => $dev, readingDevice => $dev, reading => 'state',
        onPattern => '^on$', offPattern => '^off$',
        onRe => qr/^on$/, offRe => qr/^off$/,
        onCommand => 'on', offCommand => 'off',
        minDuration => 1, maxDuration => 240,
    };
    $PresenceSimulation_DATA{$name}{config} = {
        order => [$dev], byDevice => { $dev => $cfg },
        byReadingDevice => { $dev => [$cfg] }, globalBlocks => [], ready => 1,
    };
    my $entry = {
        startedAt => 100, offDue => 200, durationMinutes => 2,
        bin => 1, weekday => 1, modelType => 'all-days',
        readingDevice => $dev, reading => 'state',
        onPattern => '^on$', offPattern => '^off$', offCommand => 'off',
        stopping => 1, offAttempts => 0, offFailed => 0, offLastError => '',
    };
    $PresenceSimulation_DATA{$name}{state}{managed}{$dev} = $entry;
    $TEST_READINGS{$dev}{state} = 'on';
    @TEST_COMMANDS = ();
    local $TEST_COMMAND_ERROR;

    PresenceSimulation_ProcessManagedOffEntry($hash, $dev, $entry, $cfg, 1000);
    PresenceSimulation_ProcessManagedOffEntry($hash, $dev, $entry, $cfg, 1059);
    PresenceSimulation_ProcessManagedOffEntry($hash, $dev, $entry, $cfg, 1060);
    PresenceSimulation_ProcessManagedOffEntry($hash, $dev, $entry, $cfg, 1360);
    PresenceSimulation_ProcessManagedOffEntry($hash, $dev, $entry, $cfg, 1420);

    is(scalar(grep { $_ eq "$dev off" } @TEST_COMMANDS), 3,
        'managed OFF is sent at most three times');
    is($entry->{offAttempts}, 3,
        'managed state persists the number of OFF attempts');
    is($entry->{offFailed}, 1,
        'missing OFF confirmation enters a persistent failed state');
    is($TEST_READINGS{$name}{lastErrorSource}, 'playback',
        'exhausted OFF retries use the existing playback error readings');

    PresenceSimulation_ProcessManagedOffEntry($hash, $dev, $entry, $cfg, 5000);
    is(scalar(grep { $_ eq "$dev off" } @TEST_COMMANDS), 3,
        'failed managed OFF state sends no further automatic commands');

    PresenceSimulation_UpdateReadings($hash);
    is($TEST_READINGS{$name}{stoppingPlayback}, 1,
        'stoppingPlayback remains non-zero while OFF is unresolved');

    PresenceSimulation_Set($hash, $name, 'retryOff', $dev);
    is($entry->{offFailed}, 0,
        'retryOff explicitly leaves the failed state');
    is($entry->{offAttempts}, 1,
        'retryOff starts a new bounded attempt cycle');
    is(scalar(grep { $_ eq "$dev off" } @TEST_COMMANDS), 4,
        'retryOff sends exactly one immediate new OFF attempt');

    $TEST_READINGS{$dev}{state} = 'off';
    PresenceSimulation_ProcessManagedOffEntry($hash, $dev, $entry, $cfg, 5001);
    ok(!exists $PresenceSimulation_DATA{$name}{state}{managed}{$dev},
        'a later confirmed OFF releases managed ownership');
    is($TEST_READINGS{$name}{lastError}, 'none',
        'a resolved OFF failure clears the existing playback error');
}

{
    my $name = 'ForceReleaseManaged';
    my $hash = make_instance($name);
    $PresenceSimulation_DATA{$name}{state}{mode} = 'off';
    $PresenceSimulation_DATA{$name}{state}{managed}{StaleDevice} = {
        startedAt => 1, offDue => 2, durationMinutes => 1,
        bin => 0, weekday => 1, modelType => 'all-days',
        reading => 'state', onPattern => '^on$', offPattern => '^off$', offCommand => 'off',
        stopping => 1, offAttempts => 3, offFailed => 1, offLastError => 'not confirmed',
    };
    is(
        PresenceSimulation_Set($hash, $name, 'forceReleaseManaged', 'StaleDevice', 'confirm'),
        undef,
        'forceReleaseManaged is available as an explicit recovery command in mode off',
    );
    ok(!exists $PresenceSimulation_DATA{$name}{state}{managed}{StaleDevice},
        'forceReleaseManaged removes only the selected managed entry');
}

{
    my $name = 'QueuedImportCancellation';
    my $hash = make_instance($name);
    my ($param_fh, $param_file) = tempfile(
        'PresenceSimulation_CancelParams_XXXXXX',
        TMPDIR => 1,
        UNLINK => 0,
    );
    print {$param_fh} '{}';
    close $param_fh;
    my $job = { pid => 'WAITING:', fn => 'PresenceSimulation_DbLogImportWorker' };
    $hash->{helper}{importPid} = $job;
    $hash->{helper}{importToken} = 'queued-token';
    $hash->{helper}{importParamFile} = $param_file;
    my ($starts, $kills) = (0, 0);
    no warnings qw(redefine once);
    local *main::BlockingStart = sub { $starts++; return };
    local *main::BlockingKill = sub { $kills++; return };

    PresenceSimulation_AbortRunningImport($hash, 'test queued cancellation', 'aborted');
    is($job->{fn}, undef,
        'queued BlockingCall is invalidated before FHEM can start it');
    is($job->{terminated}, 1,
        'queued BlockingCall is marked terminated');
    is($starts, 1,
        'BlockingStart is invoked once to remove the invalidated waiting job');
    is($kills, 0,
        'BlockingKill is not misused for a WAITING job');
    ok(!-e $param_file,
        'queued import cancellation removes its unread parameter file');
    ok(!exists $hash->{helper}{importPid},
        'queued import cancellation clears module runtime bookkeeping');
}

{
    my $name = 'MalformedImportCallback';
    my $hash = make_instance($name);
    my ($param_fh, $param_file) = tempfile(
        'PresenceSimulation_MalformedParams_XXXXXX',
        TMPDIR => 1,
        UNLINK => 0,
    );
    print {$param_fh} '{}';
    close $param_fh;
    $hash->{helper}{importPid} = { pid => 12345 };
    $hash->{helper}{importToken} = 'malformed-token';
    $hash->{helper}{importContext} = 'manual';
    $hash->{helper}{importParamFile} = $param_file;

    PresenceSimulation_DbLogImportDone('not a valid worker response');
    ok(!exists $hash->{helper}{importPid},
        'malformed worker callback cannot leave the import permanently locked');
    ok(!-e $param_file,
        'malformed worker callback removes its secure parameter file');
    is($TEST_READINGS{$name}{importState}, 'error',
        'malformed worker callback is exposed through importState');
    is($TEST_READINGS{$name}{lastErrorSource}, 'dblog',
        'malformed worker callback uses the existing DbLog error readings');
}


{
    my $name = 'MismatchedImportResult';
    my $hash = make_instance($name);
    my $fingerprint = PresenceSimulation_ImportFingerprint($hash);
    my ($result_fh, $result_file) = tempfile(
        'PresenceSimulation_MismatchedResult_XXXXXX',
        TMPDIR => 1,
        UNLINK => 0,
    );
    print {$result_fh} JSON::PP->new->encode({
        importToken => 'matching-token',
        configFingerprint => 'wrong-file-fingerprint',
    });
    close $result_fh;
    $hash->{helper}{importPid} = { pid => 12345 };
    $hash->{helper}{importToken} = 'matching-token';
    $hash->{helper}{importFingerprint} = $fingerprint;
    $hash->{helper}{importContext} = 'manual';

    PresenceSimulation_DbLogImportDone(
        PresenceSimulation_EncodeImportResponse(
            $name,
            'matching-token',
            {
                ok => 1,
                moduleName => $name,
                importToken => 'matching-token',
                configFingerprint => $fingerprint,
                file => $result_file,
            },
        )
    );
    ok(!exists $hash->{helper}{importPid},
        'identity-mismatched result releases import runtime bookkeeping');
    ok(!-e $result_file,
        'identity-mismatched result file is removed');
    is($TEST_READINGS{$name}{importState}, 'error',
        'identity-mismatched result is exposed as an import error');
    is($TEST_READINGS{$name}{lastErrorSource}, 'dblog',
        'identity-mismatched result uses the existing DbLog error readings');
}

{
    my ($result_fh, $result_file) = tempfile(
        'PresenceSimulation_OrphanResult_XXXXXX',
        TMPDIR => 1,
        UNLINK => 0,
    );
    print {$result_fh} '{}';
    close $result_fh;
    my $response = PresenceSimulation_EncodeImportResponse(
        'DeletedPresenceSimulation',
        'orphan-token',
        {
            ok => 1,
            moduleName => 'DeletedPresenceSimulation',
            importToken => 'orphan-token',
            configFingerprint => 'orphan-fingerprint',
            file => $result_file,
        },
    );
    PresenceSimulation_DbLogImportDone($response);
    ok(!-e $result_file,
        'late worker callback removes its result file even after the module device was deleted');
}

{
    package DBI;
    our @ROWS;
    our @EXECUTE;
    our $SQL;
    sub connect { return bless {}, 'PresenceSimulationTestDBH' }
    package PresenceSimulationTestDBH;
    sub prepare {
        $DBI::SQL = $_[1];
        return bless { rows => [ map { [@{$_}] } @DBI::ROWS ] }, 'PresenceSimulationTestSTH';
    }
    sub disconnect { return 1 }
    package PresenceSimulationTestSTH;
    sub execute { @DBI::EXECUTE = @_[1 .. $#_]; return 1 }
    sub fetchrow_arrayref { return shift @{$_[0]{rows}} }
    sub finish { return 1 }
    package main;
    local $INC{'DBI.pm'} = __FILE__;

    my $date = PresenceSimulation_Date(CORE::time() - 86400);
    @DBI::ROWS = (
        ["$date 18:00:00", 'KODI', 'state', 'opened'],
        ["$date 18:10:00", 'KODI', 'state', 'disconnected'],
    );
    my $params = {
        moduleName => 'TempWorker', dbLogName => 'DbLog', dbconn => 'dbi:mock:',
        dbuser => '', dbpass => '', table => 'history',
        targetStart => PresenceSimulation_EpochFromDateTime("$date 00:00:00"),
        targetEnd => PresenceSimulation_EpochFromDateTime(PresenceSimulation_Date(CORE::time()) . ' 00:00:00'),
        queryStart => "$date 00:00:00", queryEnd => PresenceSimulation_Date(CORE::time()) . ' 00:00:00',
        targetDates => [$date], importToken => 'token', configFingerprint => 'fingerprint',
        devices => [ { device => 'TV_Command', readingDevice => 'KODI', reading => 'state', onPattern => '^opened$', offPattern => '^disconnected$', minDuration => 1, maxDuration => 240 } ],
    };
    my ($parameter_fh, $parameter_file) = tempfile(
        'PresenceSimulation_TestParams_XXXXXX',
        TMPDIR => 1,
        UNLINK => 0,
    );
    print {$parameter_fh} JSON::PP->new->encode($params);
    close $parameter_fh;
    chmod 0600, $parameter_file;
    my $public = {
        moduleName => 'TempWorker',
        importToken => 'token',
        configFingerprint => 'fingerprint',
        parameterFile => $parameter_file,
    };
    my ($meta, $worker_name, $worker_token, $worker_decode_error) =
        PresenceSimulation_DecodeImportResponse(
            PresenceSimulation_DbLogImportWorker(JSON::PP->new->encode($public))
        );
    ok(!$worker_decode_error && $meta->{ok}, 'DbLog worker completes with a mocked database');
    is($worker_name, 'TempWorker', 'worker response envelope retains the module name');
    is($worker_token, 'token', 'worker response envelope retains the import token');
    ok(!-e $parameter_file, 'DbLog worker removes the secure parameter file immediately after reading it');
    is_deeply(
        [@DBI::EXECUTE[2, 3]],
        ['KODI', 'state'],
        'DbLog query binds the observation device and reading',
    );
    unlike($DBI::SQL, qr/TV_Command/, 'DbLog SQL does not query the logical command device');
    ok(-e $meta->{file}, 'DbLog worker writes its result to a temporary file');
    is((stat($meta->{file}))[2] & 0777, 0600,
        'DbLog worker result file is restricted to the FHEM user');
    like($meta->{file}, qr/PresenceSimulation_DbLogImport_TempWorker_[A-Za-z0-9_]+$/,
        'DbLog worker uses a randomized File::Temp name');
    open my $result_fh, '<:encoding(UTF-8)', $meta->{file} or die $!;
    local $/;
    my $result_data = JSON::PP->new->decode(<$result_fh>);
    close $result_fh;
    is(
        $result_data->{days}{$date}{sessions}{TV_Command}[0]{durationMinutes},
        10,
        'DbLog rows from readingDevice are stored under the logical command device',
    );
    ok(!exists $result_data->{days}{$date}{sessions}{KODI},
        'DbLog import does not use the observation device as a model key');
    unlink $meta->{file};
}

{
    open my $fh, '<:encoding(UTF-8)', $module or die "Cannot read $module: $!";
    local $/;
    my $source = <$fh>;
    close $fh;
    unlike($source, qr/^sub Anwesenheitssimulation_/m,
        'no global function keeps the former module prefix');
    unlike($source, qr/our %Anwesenheitssimulation_DATA/,
        'former global runtime data symbol is absent');
    unlike($source, qr/\{TYPE\}.*(?:ne|eq) 'Anwesenheitssimulation'/,
        'runtime type checks no longer use the former module type');
    unlike($source, qr/Usage: define <name> Anwesenheitssimulation/,
        'Define usage no longer exposes the former module type');
    my @root_anchors = ($source =~ /<a id="PresenceSimulation"><\/a>/g);
    is(scalar @root_anchors, 2,
        'English and German commandref use the PresenceSimulation root anchor');
    unlike($source, qr/id="Anwesenheitssimulation(?:-|")/,
        'former commandref anchors are absent');
    ok(index($source, 'raw   => "$dir/PresenceSimulation_Raw_$safe.json"') >= 0,
        'raw persistence uses the PresenceSimulation prefix');
    like($source, qr/my \$PRESENCE_SIM_VERSION = '1\.1\.8'/,
        'module version is 1.1.8');
    like($source, qr/^# Copyright \(C\) 2026 Flachzange$/m,
        'source copyright holder is Flachzange');
    unlike($source, qr/Christoph Evers/,
        'former author display name is absent from the module source');
    unlike($source, qr/(?<!CORE::)\btime\(\)/,
        'all epoch-second calls explicitly bypass an imported high-resolution time function');
    like(
        $source,
        qr/off:rc_STOP training:rc_REC dryrun:rc_PLAY playback:rc_PLAYgreen/,
        'source contains the documented internal devStateIcon mapping',
    );
    my @ui_default_calls = ($source =~ /PresenceSimulation_ApplyUiDefaults\(\$hash\)/g);
    is(scalar @ui_default_calls, 2,
        'UI defaults are applied on initial define and module reload');
    unlike($source, qr/importDbLog is only available when trainingSource=dblog/,
        'obsolete manual-import restriction is absent');
    like($source, qr/configuredDevices/, 'generic configuredDevices reading is present');
    like($source, qr/readingDevice/, 'optional separate observation device is implemented');
    unlike($source, qr/lastDbLogImportAttemptDate =>/, 'fresh state contains no unused import-attempt field');
    unlike($source, qr/\$entry->\{offSentAt\}\s*=/, 'unused OFF timestamp is no longer written');
    unlike($source, qr/\btotalSessions\b/, 'redundant device-model totalSessions field is absent');
    unlike($source, qr/attrName => \$attrName, device =>/, 'device configuration omits its unused attribute name copy');
    like(
        $source,
        qr/device=&lt;device&gt; \[onCommand=on\] \[offCommand=off\] \[reading=state\] \[readingDevice=&lt;device&gt;\]/,
        'English commandref documents the requested device specification order',
    );
    like(
        $source,
        qr/device=&lt;Ger&auml;t&gt; \[onCommand=on\] \[offCommand=off\] \[reading=state\] \[readingDevice=&lt;Ger&auml;t&gt;\]/,
        'German commandref documents the requested device specification order',
    );
    unlike($source, qr/PresenceSimulation_(?:MigrateData|LegacyAttributeMap|MigrateLegacyAttributes|CleanupReadings)/,
        'migration and legacy helper functions are absent');
    unlike($source, qr/PresenceSimulation_RegisterDynamicAttributes/,
        'dynamic userattr registration helper is absent');
    unlike($source, qr/addToDevAttrList/,
        'module does not add numbered attributes to userattr');
    unlike($source, qr/NotifyOrderPrefix/,
        'module does not impose an unexplained notification order');
    unlike($source, qr/sub PresenceSimulation_IsDisabled \{.*?return PresenceSimulation_IsDisabled/s,
        'disabled-state helper does not recurse into itself');
    like($source, qr/defined &IsDisabled/,
        'module uses the central FHEM IsDisabled helper when available');
    unlike($source, qr/AnwSim_/,
        'fresh-installation persistence contains no former file prefix');
    unlike($source, qr/Changes in 1\.0\.2/,
        'source header contains no stale release-note block');
    unlike($source, qr/<a name="PresenceSimulation"/,
        'commandref uses HTML5 id-only root anchors');
    like($source, qr/wait until <code>stoppingPlayback<\/code> is 0/,
        'English commandref explains the safe wait before changing playback-sensitive attributes');
    like($source, qr/warten, bis <code>stoppingPlayback<\/code> den Wert 0 hat/,
        'German commandref explains the safe wait before changing playback-sensitive attributes');
    like($source, qr/FHEMWEB uses the internal default <code>devStateIcon<\/code> mapping/,
        'English commandref documents the internal state icon mapping');
    like($source, qr/FHEMWEB verwendet intern standardm&auml;&szlig;ig die/,
        'German commandref documents the internal state icon mapping');
    unlike($source, qr/PresenceSimulation_Model_\$safe\.json/,
        'module contains no persistent model cache path');
    unlike($source, qr/pMinute|probabilityMinute|per-minute probability|Minutenwahrscheinlichkeit/,
        'obsolete minute-hazard probability is absent from code and commandref');
    like($source, qr/startOffsets/,
        'model stores historical minute positions inside each time block');
    like($source, qr/plannedBins/,
        'runtime state persists pending real-playback block plans');
    like($source, qr/dryPlannedBins/,
        'runtime state persists pending dry-run block plans');
    like($source, qr/blockNotified/,
        'pending plans persist their one-time blocked notification marker');
    like($source, qr/pending=1/,
        'blocked simulation events expose their pending state');
    like($source, qr/retryUntil=/,
        'blocked simulation events expose the current block deadline');
    like($source, qr/use File::Temp qw\(tempfile\)/,
        'secure File::Temp support is loaded');
    like($source, qr/use File::Spec \(\)/,
        'File::Spec support for portable temporary-file cleanup is loaded');
    unlike($source, qr/failedPlaybackStops/,
        'OFF retry failures do not add another public reading');
    like($source, qr/rawSessionsTodayDiscarded/,
        'source and commandref contain the discarded-today reading');
    unlike($source, qr/PresenceSimulation_QuoteEventValue/,
        'obsolete quoted block-event helper is absent');
    unlike($source, qr/push \@detailParts, 'scope='/,
        'simulationEvent no longer emits redundant block scope');
    unlike($source, qr/push \@detailParts, '(?:actual|expression)='/,
        'simulationEvent no longer emits quoting-sensitive block diagnostics');
    like($source, qr/at most three times: immediately/,
        'English commandref documents bounded OFF retries');
    like($source, qr/h&ouml;chstens dreimal versucht: sofort/,
        'German commandref documents bounded OFF retries');
    like($source, qr/maxDuration<\/code>\s+must be between .*?1440 minutes/s,
        'English commandref documents the maxDuration upper limit');
    like($source, qr/maxDuration<\/code>\s+muss zwischen .*?1440\s+Minuten/s,
        'German commandref documents the maxDuration upper limit');
    unlike($source, qr/PresenceSimulation_EventFnEventValue/,
        'MSG-specific eventFn rewrite helper is absent');
    unlike($source, qr/\Q(\$day->{source} \/\/ '') eq 'dblog'\E/,
        'source=dblog compatibility fallback is absent');

    my @basic_setup = ($source =~ /<h4>Basic setup<\/h4>/g);
    is(scalar @basic_setup, 1,
        'English commandref contains one Basic setup section');
    my @grundkonfiguration = ($source =~ /<h4>Grundkonfiguration<\/h4>/g);
    is(scalar @grundkonfiguration, 1,
        'German commandref contains one Grundkonfiguration section');
    like($source, qr/A raw session starts with\s+a recognized on transition and ends with the corresponding off transition/s,
        'English commandref explains what a raw session is');
    like($source, qr/Eine Raw-Session beginnt mit einem erkannten Einschaltvorgang und endet mit\s+dem zugeh&ouml;rigen Ausschaltvorgang/s,
        'German commandref explains what a raw session is');
    unlike($source, qr/This module is licensed under GPL-2\.0-or-later\. Its implementation was/,
        'English implementation-assistance paragraph is absent from commandref');
    unlike($source, qr/Das Modul steht unter GPL-2\.0-or-later\. Die Implementierung wurde iterativ/,
        'German implementation-assistance paragraph is absent from commandref');

    my ($meta_text) = $source =~ /=for :application\/json;q=META\.json 98_PresenceSimulation\.pm\n(\{.*?\n\})\n=end/s;
    ok(defined $meta_text, 'embedded META.json found');
    my $meta = eval { JSON::PP->new->decode($meta_text) };
    ok(!$@ && ref $meta eq 'HASH', 'embedded META.json is valid JSON');
    is($meta->{name}, 'FHEM-PresenceSimulation', 'META name matches the new module type');
    is($meta->{version}, 'v1.1.8', 'META version matches module version');
    ok(exists $meta->{prereqs}{runtime}{requires}{'File::Spec'},
        'META declares the File::Spec runtime prerequisite');
    is_deeply($meta->{author}, ['Flachzange <>'],
        'META author contains only the pseudonym without a contact address');
    ok(
        ref $meta->{resources} ne 'HASH' || !exists $meta->{resources}{bugtracker},
        'META contains no mailto bugtracker contact',
    );
    unlike($source, qr/openai\@christoph-evers\.de/,
        'former contact address is absent from module source');
    is($meta->{release_status}, 'testing', 'META release status remains testing');
}

done_testing();
