###############################################################################
# 98_PresenceSimulation.pm
#
# Copyright (C) 2026 Flachzange
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Event- and DbLog-based rolling presence simulation for FHEM.
#
# $Id$
###############################################################################

package main;

use strict;
use warnings;
use Blocking;
use FHEM::Meta;
use Time::HiRes qw(gettimeofday);
use POSIX qw(strftime mktime);
use JSON::PP ();
use Text::ParseWords qw(shellwords);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Basename qw(dirname);
use File::Temp qw(tempfile);
use File::Spec ();
use Scalar::Util qw(looks_like_number);
use Digest::SHA qw(sha1_hex);

our (%defs, %attr, $readingFnAttributes, $init_done);

my $PRESENCE_SIM_VERSION = '1.1.10';
my $PRESENCE_SIM_SCHEMA  = 3;
my $PRESENCE_SIM_MAX_DURATION_MINUTES = 1440;
my $PRESENCE_SIM_OFF_MAX_ATTEMPTS = 3;
my @PRESENCE_SIM_OFF_RETRY_DELAYS = (60, 300, 60);
my $PRESENCE_SIM_IMPORT_RESPONSE_PREFIX = 'PSIMPORT1';
my $PRESENCE_SIM_DEV_STATE_ICON =
    'off:rc_STOP training:rc_REC dryrun:rc_PLAY playback:rc_PLAYgreen';
our %PresenceSimulation_DATA;

# Applies module-owned FHEMWEB defaults without creating user attributes.
sub PresenceSimulation_ApplyUiDefaults {
    my ($hash) = @_;
    return if !$hash;
    $hash->{devStateIcon} = $PRESENCE_SIM_DEV_STATE_ICON;
    return;
}

# Writes a standardized message to the FHEM log.
sub PresenceSimulation_Log {
    my ($hash, $level, $message) = @_;
    return if !$hash;

    my $name = $hash->{NAME} // 'PresenceSimulation';
    Log3($name, $level, "$name - $message");
    return;
}

# Ensures the explicit no-error readings exist for the current module instance.
sub PresenceSimulation_InitializeErrorReadings {
    my ($hash) = @_;
    return if !$hash;
    my $name = $hash->{NAME};

    my $lastError = ReadingsVal($name, 'lastError', '');
    $lastError = 'none' if !defined $lastError || $lastError eq '';

    my $lastErrorSource = ReadingsVal($name, 'lastErrorSource', '');
    my $lastErrorTime   = ReadingsVal($name, 'lastErrorTime', '');
    if ($lastError eq 'none') {
        $lastErrorSource = 'none';
        $lastErrorTime   = 'none';
    }

    return if ReadingsVal($name, 'lastError', '') eq $lastError
        && ReadingsVal($name, 'lastErrorSource', '') eq $lastErrorSource
        && ReadingsVal($name, 'lastErrorTime', '') eq $lastErrorTime;

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastError',       $lastError);
    readingsBulkUpdate($hash, 'lastErrorSource', $lastErrorSource);
    readingsBulkUpdate($hash, 'lastErrorTime',   $lastErrorTime);
    readingsEndUpdate($hash, 0);
    return;
}

# Updates persisted import diagnostics and the compact importState reading.
sub PresenceSimulation_SetImportInfo {
    my ($hash, %updates) = @_;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});
    return if !%{$data};
    my $state = PresenceSimulation_AsHash($data->{state});
    $state->{importInfo} = {} if ref $state->{importInfo} ne 'HASH';
    my $info = $state->{importInfo};
    $info->{$_} = $updates{$_} for keys %updates;
    readingsSingleUpdate($hash, 'importState', $info->{state} // 'idle', 1);
    PresenceSimulation_MarkDirty($hash, 'state');
    return;
}

# Returns the configured training source with a safe default.
sub PresenceSimulation_TrainingSource {
    my ($name) = @_;
    my $source = AttrVal($name, 'trainingSource', 'events');
    return $source eq 'dblog' ? 'dblog' : 'events';
}


# Uses FHEM's central disabled-state helper when available.
sub PresenceSimulation_IsDisabled {
    my ($name) = @_;
    return IsDisabled($name) ? 1 : 0 if defined &IsDisabled;
    return AttrVal($name, 'disable', 0) ? 1 : 0;
}

# Returns true only after at least one valid device and all configuration
# expressions have been parsed successfully.
sub PresenceSimulation_ConfigReady {
    my ($hash) = @_;
    return 0 if !$hash;
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$hash->{NAME}});
    my $config = PresenceSimulation_AsHash($data->{config});
    return $config->{ready} ? 1 : 0;
}


# Builds the current attribute configuration immediately when a command is
# issued before the delayed initialization timer has run.
sub PresenceSimulation_EnsureConfigReady {
    my ($hash) = @_;
    return undef if PresenceSimulation_ConfigReady($hash);
    my @errors = PresenceSimulation_BuildConfig($hash);
    return join('; ', @errors) if @errors;
    return undef;
}

# Reports whether real playback still owns at least one device.
sub PresenceSimulation_HasManagedPlaybackDevices {
    my ($hash) = @_;
    return 0 if !$hash;
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$hash->{NAME}});
    return scalar(keys %{PresenceSimulation_AsHash($data->{state}{managed})}) ? 1 : 0;
}

# Reconstructs the minimum device configuration needed to stop or reconcile a
# persisted managed session if the current deviceNN attribute is unavailable.
sub PresenceSimulation_ConfigForManagedEntry {
    my ($data, $dev, $entry) = @_;
    my $current = PresenceSimulation_AsHash($data->{config}{byDevice}{$dev});
    return $current if %{$current};
    return undef if ref $entry ne 'HASH';

    for my $key (qw(reading onPattern offPattern offCommand)) {
        return undef if !defined $entry->{$key} || $entry->{$key} eq '';
    }
    my $readingDevice = defined $entry->{readingDevice} && $entry->{readingDevice} ne ''
        ? $entry->{readingDevice}
        : $dev;

    my $onRe = eval { qr/$entry->{onPattern}/ };
    return undef if $@;
    my $offRe = eval { qr/$entry->{offPattern}/ };
    return undef if $@;

    return {
        device        => $dev,
        readingDevice => $readingDevice,
        reading       => $entry->{reading},
        onPattern  => $entry->{onPattern},
        offPattern => $entry->{offPattern},
        onRe       => $onRe,
        offRe      => $offRe,
        offCommand => $entry->{offCommand},
    };
}

# Returns canonical device definitions for DbLog imports and their largest duration.
sub PresenceSimulation_ImportDeviceDefinitions {
    my ($hash) = @_;
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$hash->{NAME}});
    my @devices;
    my $maxDuration = 1;

    for my $device (@{PresenceSimulation_AsArray($data->{config}{order})}) {
        my $cfg = PresenceSimulation_AsHash($data->{config}{byDevice}{$device});
        my $definition = {
            device        => $cfg->{device} // '',
            readingDevice => $cfg->{readingDevice} // $cfg->{device} // '',
            reading       => $cfg->{reading} // '',
            onPattern     => $cfg->{onPattern} // '',
            offPattern    => $cfg->{offPattern} // '',
            minDuration   => int($cfg->{minDuration} // 0),
            maxDuration   => int($cfg->{maxDuration} // 0),
        };
        push @devices, $definition;
        $maxDuration = $definition->{maxDuration}
            if $definition->{maxDuration} > $maxDuration;
    }

    return (\@devices, $maxDuration);
}

# Returns a stable fingerprint for all settings that affect a DbLog import.
sub PresenceSimulation_ImportFingerprint {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my ($devices) = PresenceSimulation_ImportDeviceDefinitions($hash);
    my $payload = {
        trainingSource => PresenceSimulation_TrainingSource($name),
        dbLogDevice    => AttrVal($name, 'dbLogDevice', ''),
        retentionDays  => PresenceSimulation_EffectiveRetentionDays($name),
        devices        => $devices,
    };
    return sha1_hex(JSON::PP->new->canonical(1)->encode($payload));
}


# Returns true for the only time-bin sizes supported by the model.
sub PresenceSimulation_IsValidBinMinutes {
    my ($value) = @_;
    return defined $value && $value =~ /^(?:1|5|10|15|20|30|60)$/ ? 1 : 0;
}

# Removes stale module-owned DbLog import parameter and result files before imports.
sub PresenceSimulation_CleanupImportTempFiles {
    my $tmpdir = File::Spec->tmpdir();
    my $cutoff = CORE::time() - 86400;

    for my $pattern (
        'PresenceSimulation_DbLogParams_*',
        'PresenceSimulation_DbLogImport_*',
    ) {
        for my $file (glob(File::Spec->catfile($tmpdir, $pattern))) {
            next if !-f $file;
            my $modified = (stat($file))[9];
            next if !defined $modified || $modified >= $cutoff;
            unlink $file;
        }
    }
    return;
}

# Clears parent-process runtime bookkeeping and removes a remaining secret
# parameter file. The worker normally unlinks that file immediately after read.
sub PresenceSimulation_ClearImportRuntime {
    my ($hash) = @_;
    return if !$hash;
    my $parameterFile = $hash->{helper}{importParamFile};
    unlink $parameterFile if defined $parameterFile && $parameterFile ne '' && -e $parameterFile;
    delete @{$hash->{helper}}{
        qw(importPid importContext importToken importFingerprint importParamFile)
    };
    return;
}

# Cancels both running and queued BlockingCall jobs. BlockingKill alone does not
# remove a job whose pid is still the special WAITING: marker.
sub PresenceSimulation_CancelBlockingJob {
    my ($job) = @_;
    return if ref $job ne 'HASH';

    if (($job->{pid} // '') =~ /:/) {
        $job->{terminated} = 1;
        $job->{fn} = undef;
        RemoveInternalTimer($job);
        BlockingStart();
        return;
    }

    BlockingKill($job);
    return;
}

# Wraps worker replies in a small public envelope so the parent can still
# identify and release the correct import if the JSON payload is malformed.
sub PresenceSimulation_EncodeImportResponse {
    my ($moduleName, $token, $meta) = @_;
    $moduleName //= '';
    $token //= '';
    $meta = {} if ref $meta ne 'HASH';

    my $json = eval { JSON::PP->new->canonical->encode($meta) };
    if ($@ || !defined $json) {
        $json = '{"ok":0,"error":"Unable to encode DbLog import response"}';
    }
    return join("\t", $PRESENCE_SIM_IMPORT_RESPONSE_PREFIX, $moduleName, $token, $json);
}

# Decodes the public worker envelope and its JSON payload.
sub PresenceSimulation_DecodeImportResponse {
    my ($response) = @_;
    return (undef, '', '', 'empty DbLog import response')
        if !defined $response || $response eq '';

    my ($prefix, $moduleName, $token, $json) = split /\t/, $response, 4;
    return (undef, '', '', 'invalid DbLog import response envelope')
        if !defined $json || ($prefix // '') ne $PRESENCE_SIM_IMPORT_RESPONSE_PREFIX;

    my $meta = eval { JSON::PP->new->decode($json) };
    return (undef, $moduleName // '', $token // '', "invalid DbLog import response payload: $@")
        if $@ || ref $meta ne 'HASH';

    $meta->{moduleName} //= $moduleName;
    $meta->{importToken} //= $token;
    return ($meta, $moduleName // '', $token // '', undef);
}

# Finishes a failed DbLog import consistently and schedules a retry if applicable.
sub PresenceSimulation_FailImport {
    my ($hash, $message, $state, %details) = @_;
    return if !$hash;
    $state //= 'error';
    $message = PresenceSimulation_OneLineError($message // 'DbLog import failed');
    PresenceSimulation_SetImportInfo(
        $hash,
        %details,
        state    => $state,
        finished => PresenceSimulation_FormatDateTime(CORE::time()),
        error    => $message,
    );
    PresenceSimulation_SetError($hash, $message, 'dblog');
    PresenceSimulation_ScheduleAutoImportRetry($hash);
    return;
}

# A completely malformed callback has no usable token. Clearing all currently
# active imports is safer than leaving one or more instances permanently locked.
sub PresenceSimulation_FailActiveImportsForMalformedResponse {
    my ($message) = @_;
    $message //= 'invalid DbLog import response';

    for my $name (sort keys %defs) {
        my $hash = $defs{$name};
        next if ref $hash ne 'HASH';
        next if ($hash->{TYPE} // '') ne 'PresenceSimulation';
        next if !$hash->{helper}{importPid} && !$hash->{helper}{importToken};

        PresenceSimulation_ClearImportRuntime($hash);
        PresenceSimulation_FailImport($hash, $message, 'error');
    }
    return;
}

# Aborts an active import and invalidates a late worker response.
sub PresenceSimulation_AbortRunningImport {
    my ($hash, $reason, $stateText) = @_;
    return if !$hash;
    my $hadImport = $hash->{helper}{importPid} || $hash->{helper}{importToken};
    my $job = $hash->{helper}{importPid};

    PresenceSimulation_ClearImportRuntime($hash);
    $hash->{helper}{importGeneration} = int($hash->{helper}{importGeneration} // 0) + 1;
    PresenceSimulation_CancelBlockingJob($job) if ref $job eq 'HASH';

    if ($hadImport) {
        PresenceSimulation_SetImportInfo(
            $hash,
            state    => ($stateText // 'aborted'),
            finished => PresenceSimulation_FormatDateTime(CORE::time()),
            error    => ($reason // 'unspecified reason'),
        );
        PresenceSimulation_Log($hash, 3, "DbLog import aborted: " . ($reason // 'unspecified reason'));
    }
    return $hadImport;
}

# Clears an error only when it belongs to the successful subsystem.
sub PresenceSimulation_ClearError {
    my ($hash, $source) = @_;
    my $name = $hash->{NAME};
    return if ReadingsVal($name, 'lastError', 'none') =~ /^(?:|none)$/;
    return if defined $source && ReadingsVal($name, 'lastErrorSource', '') ne $source;

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastError', 'none');
    readingsBulkUpdate($hash, 'lastErrorSource', 'none');
    readingsBulkUpdate($hash, 'lastErrorTime', 'none');
    readingsEndUpdate($hash, 1);
    return;
}

# Schedules bounded retries after a failed automatic DbLog import.
sub PresenceSimulation_ScheduleAutoImportRetry {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});
    return PresenceSimulation_ScheduleAutoImport($hash)
        if PresenceSimulation_IsDisabled($name)
        || PresenceSimulation_TrainingSource($name) ne 'dblog';

    my $failures = int($data->{state}{autoImportFailures} // 0) + 1;
    $data->{state}{autoImportFailures} = $failures;
    my @delays = (300, 900, 3600);
    my $retryAt;

    if ($failures <= @delays) {
        $retryAt = CORE::time() + $delays[$failures - 1];
    }
    else {
        my $timeText = AttrVal($name, 'importTime', '03:05');
        my ($hour, $minute) = split /:/, $timeText, 2;
        my @lt = localtime(CORE::time());
        $retryAt = mktime(0, $minute, $hour, $lt[3] + 1, $lt[4], $lt[5]);
        $data->{state}{autoImportFailures} = 0;
    }

    $data->{state}{autoImportRetryAt} = $retryAt;
    PresenceSimulation_MarkDirty($hash, 'state');
    RemoveInternalTimer($hash, 'PresenceSimulation_AutoImportTimer');
    readingsSingleUpdate($hash, 'nextDbLogImport', PresenceSimulation_FormatDateTime($retryAt), 0);
    InternalTimer($retryAt, 'PresenceSimulation_AutoImportTimer', $hash, 0);
    PresenceSimulation_Log($hash, 3, "automatic DbLog import retry scheduled after failure $failures");
    return;
}

# Validates the DbLog-related attributes without silently selecting a device.
sub PresenceSimulation_ValidateDbLogConfiguration {
    my ($hash, $dbLogNameOverride) = @_;
    my $name = $hash->{NAME};
    my $dbLogName = defined $dbLogNameOverride
        ? $dbLogNameOverride
        : AttrVal($name, 'dbLogDevice', '');

    return 'Attribute dbLogDevice must be set for DbLog imports'
        if !defined $dbLogName || $dbLogName eq '';
    return "DbLog device $dbLogName does not exist"
        if !$defs{$dbLogName};
    return "Device $dbLogName is not a DbLog device"
        if ($defs{$dbLogName}{TYPE} // '') ne 'DbLog';

    my $importTime = AttrVal($name, 'importTime', '03:05');
    return "Invalid importTime '$importTime'; expected HH:MM"
        if $importTime !~ /^(?:[01]\d|2[0-3]):[0-5]\d$/;

    return;
}

# Calculates and schedules the next automatic DbLog import.
sub PresenceSimulation_ScheduleAutoImport {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});

    RemoveInternalTimer($hash, 'PresenceSimulation_AutoImportTimer');

    if (PresenceSimulation_IsDisabled($name) || PresenceSimulation_TrainingSource($name) ne 'dblog') {
        readingsSingleUpdate($hash, 'nextDbLogImport', '-', 0);
        return;
    }

    if (!PresenceSimulation_ConfigReady($hash)) {
        readingsSingleUpdate($hash, 'nextDbLogImport', 'configuration error', 0);
        return 'At least one valid deviceNN attribute is required';
    }

    my $error = PresenceSimulation_ValidateDbLogConfiguration($hash);
    if ($error) {
        readingsSingleUpdate($hash, 'nextDbLogImport', 'configuration error', 0);
        return $error;
    }

    my $now = CORE::time();
    my $retryAt = int($data->{state}{autoImportRetryAt} // 0);
    if ($retryAt > $now) {
        readingsSingleUpdate($hash, 'nextDbLogImport', PresenceSimulation_FormatDateTime($retryAt), 0);
        InternalTimer($retryAt, 'PresenceSimulation_AutoImportTimer', $hash, 0);
        return;
    }
    $data->{state}{autoImportRetryAt} = 0;

    my $timeText = AttrVal($name, 'importTime', '03:05');
    my ($hour, $minute) = split /:/, $timeText, 2;
    my @lt = localtime($now);
    my $today = PresenceSimulation_Date($now);
    my $lastImportDate = $data->{state}{lastDbLogImportDate} // '';
    my $target = mktime(0, $minute, $hour, $lt[3], $lt[4], $lt[5]);

    if ($lastImportDate eq $today) {
        $target = mktime(0, $minute, $hour, $lt[3] + 1, $lt[4], $lt[5]);
    }
    elsif ($target <= $now) {
        $target = $now + 1;
    }

    readingsSingleUpdate($hash, 'nextDbLogImport', PresenceSimulation_FormatDateTime($target), 0);
    InternalTimer($target, 'PresenceSimulation_AutoImportTimer', $hash, 0);
    return;
}


# Starts the scheduled daily import or postpones it while another import runs.
sub PresenceSimulation_AutoImportTimer {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return if !$defs{$name} || $defs{$name} != $hash;

    if (PresenceSimulation_IsDisabled($name) || PresenceSimulation_TrainingSource($name) ne 'dblog') {
        PresenceSimulation_ScheduleAutoImport($hash);
        return;
    }

    my $error = PresenceSimulation_ValidateDbLogConfiguration($hash);
    if ($error) {
        PresenceSimulation_SetImportInfo($hash, state => 'configuration error', error => $error);
        PresenceSimulation_SetError($hash, $error, 'configuration');
        PresenceSimulation_ScheduleAutoImportRetry($hash);
        return;
    }

    if ($hash->{helper}{importPid}) {
        my $retry = CORE::time() + 300;
        readingsSingleUpdate($hash, 'nextDbLogImport', PresenceSimulation_FormatDateTime($retry), 0);
        InternalTimer($retry, 'PresenceSimulation_AutoImportTimer', $hash, 0);
        PresenceSimulation_Log($hash, 4, 'automatic DbLog import postponed because another import is running');
        return;
    }

    my $dbLogName = AttrVal($name, 'dbLogDevice', '');
    my $days = PresenceSimulation_EffectiveRetentionDays($name);
    my $startError = PresenceSimulation_StartDbLogImport($hash, $dbLogName, $days, 'automatic');
    if ($startError) {
        PresenceSimulation_SetError($hash, "Automatic DbLog import could not start: $startError", 'dblog');
        PresenceSimulation_ScheduleAutoImportRetry($hash);
        return;
    }

    readingsSingleUpdate($hash, 'nextDbLogImport', 'running', 0);
    return;
}


# Registers FHEM functions and attributes.
sub PresenceSimulation_Initialize {
    my ($hash) = @_;

    $hash->{DefFn}      = \&PresenceSimulation_Define;
    $hash->{UndefFn}    = \&PresenceSimulation_Undef;
    $hash->{DeleteFn}   = \&PresenceSimulation_Delete;
    $hash->{SetFn}      = \&PresenceSimulation_Set;
    $hash->{GetFn}      = \&PresenceSimulation_Get;
    $hash->{NotifyFn}   = \&PresenceSimulation_Notify;
    $hash->{AttrFn}     = \&PresenceSimulation_Attr;
    $hash->{RenameFn}   = \&PresenceSimulation_Rename;
    $hash->{ShutdownFn} = \&PresenceSimulation_Shutdown;

    # Numbered attributes are declared as wildcard entries in the regular
    # module AttrList. Current FHEMWEB versions can edit matching concrete
    # attributes directly, so no device-specific userattr entries are needed.
    $hash->{AttrList} =
          'device[0-9][0-9]:textField-long '
        . 'device[0-9][0-9]Block[0-9][0-9]:textField-long '
        . 'globalBlock[0-9][0-9]:textField-long '
        . 'trainingSource:events,dblog '
        . 'dbLogDevice:textField '
        . 'importTime:textField '
        . 'trainingDays:textField '
        . 'retentionDays:textField '
        . 'binMinutes:select,1,5,10,15,20,30,60 '
        . 'minTrainingMinutes:textField '
        . 'saveInterval:textField '
        . 'manualLockMinutes:textField '
        . 'probabilityFactor:textField '
        . 'weekdaySpecific:0,1 '
        . 'eventFn:textField-long '
        . 'eventFnEnabled:0,1 '
        . 'disable:1,0 '
        . 'disabledForIntervals:textField-long '
        . $readingFnAttributes;

    # During a module reload FHEM calls Initialize again, but it does not call
    # DefFn for existing devices. Reinitialize those instances explicitly.
    PresenceSimulation_PrepareReload() if $init_done;
    return FHEM::Meta::InitMod(__FILE__, $hash);
}

# Schedules controlled reinitialization for all existing module instances.
sub PresenceSimulation_PrepareReload {
    for my $name (sort keys %defs) {
        my $instance = $defs{$name};
        next if ref $instance ne 'HASH';
        next if ($instance->{TYPE} // '') ne 'PresenceSimulation';

        # Prevent callbacks from being scheduled while the old implementation
        # is being detached. The runtime data remains in memory for ReloadTimer.
        $instance->{helper}{teardown} = 1;
        PresenceSimulation_AbortRunningImport($instance, 'module reload', 'aborted by reload');
        RemoveInternalTimer($instance);
        delete $instance->{helper}{saveScheduled};
        $instance->{VERSION} = $PRESENCE_SIM_VERSION;

        InternalTimer(
            gettimeofday() + 0.1,
            'PresenceSimulation_ReloadTimer',
            $instance,
            0
        );
    }
    return;
}

# Reinitializes one existing device after the module source was reloaded.
sub PresenceSimulation_ReloadTimer {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return if !$defs{$name} || $defs{$name} != $hash;

    delete $hash->{helper}{teardown};
    my $preserved = ref $PresenceSimulation_DATA{$name} eq 'HASH';
    if ($preserved) {
        my ($raw, $rawError) = PresenceSimulation_ValidatePersistedData(
            $hash,
            'raw',
            $PresenceSimulation_DATA{$name}{raw}
        );
        my ($state, $stateError) = PresenceSimulation_ValidatePersistedData(
            $hash,
            'state',
            $PresenceSimulation_DATA{$name}{state}
        );
        if (!$raw || !$state) {
            PresenceSimulation_Log(
                $hash,
                2,
                'discarding incompatible runtime data during reload: '
                    . join('; ', grep { defined $_ && $_ ne '' } ($rawError, $stateError))
            );
            $preserved = 0;
        }
    }

    if (!$preserved) {
        $PresenceSimulation_DATA{$name} = PresenceSimulation_NewInstanceData($name);
        PresenceSimulation_LoadAll($hash);
    }
    else {
        PresenceSimulation_NormalizeInstanceData($hash);
    }

    my $data = $PresenceSimulation_DATA{$name};
    $data->{model}  = PresenceSimulation_EmptyModel($name);
    $data->{config} = PresenceSimulation_EmptyConfig();
    $data->{state}{lastCoverageTick} = CORE::time();

    delete $hash->{helper}{saveScheduled};
    $hash->{VERSION} = $PRESENCE_SIM_VERSION;
    PresenceSimulation_ApplyUiDefaults($hash);
    FHEM::Meta::SetInternals($hash);

    PresenceSimulation_InitializeErrorReadings($hash);
    readingsBeginUpdate($hash);
    readingsBulkUpdateIfChanged($hash, 'mode', $data->{state}{mode} // 'off');
    readingsBulkUpdateIfChanged($hash, 'state', $data->{state}{mode} // 'off');
    readingsBulkUpdateIfChanged(
        $hash, 'importState',
        PresenceSimulation_AsHash($data->{state}{importInfo})->{state} // 'idle'
    );
    readingsEndUpdate($hash, 1);

    setNotifyDev($hash, 'global');
    PresenceSimulation_ScheduleInit($hash, 0.05);
    PresenceSimulation_ScheduleTick($hash);

    PresenceSimulation_Log(
        $hash, 3,
        'module reloaded: runtime data ' . ($preserved ? 'preserved in memory' : 'restored from files')
    );
    return;
}

# Normalizes reload-persistent data without discarding raw sessions or state.
sub PresenceSimulation_NormalizeInstanceData {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};

    if (ref $data ne 'HASH') {
        $PresenceSimulation_DATA{$name} = PresenceSimulation_NewInstanceData($name);
        return;
    }

    $data->{raw} = PresenceSimulation_EmptyRaw($name)
        if ref $data->{raw} ne 'HASH';
    $data->{raw}{days} = {} if ref $data->{raw}{days} ne 'HASH';
    for my $date (keys %{$data->{raw}{days}}) {
        my $day = $data->{raw}{days}{$date};
        next if ref $day ne 'HASH';
        $day->{discardedSessions} = int($day->{discardedSessions} // 0);
    }

    $data->{state} = PresenceSimulation_EmptyState($name)
        if ref $data->{state} ne 'HASH';
    my $state = $data->{state};
    $state->{activeSessions}  = {} if ref $state->{activeSessions} ne 'HASH';
    $state->{managed}         = {} if ref $state->{managed} ne 'HASH';
    $state->{dryManaged}      = {} if ref $state->{dryManaged} ne 'HASH';
    $state->{expected}        = {} if ref $state->{expected} ne 'HASH';
    $state->{manualLockUntil} = {} if ref $state->{manualLockUntil} ne 'HASH';
    $state->{playedBins}      = {} if ref $state->{playedBins} ne 'HASH';
    $state->{dryPlayedBins}   = {} if ref $state->{dryPlayedBins} ne 'HASH';
    $state->{plannedBins}     = {} if ref $state->{plannedBins} ne 'HASH';
    $state->{dryPlannedBins}  = {} if ref $state->{dryPlannedBins} ne 'HASH';
    $state->{mode} = 'off'
        if ($state->{mode} // '') !~ /^(?:training|playback|dryrun|off)$/;
    $state->{currentDate} ||= PresenceSimulation_Date(CORE::time());
    $state->{lastDbLogImportDate} //= '';
    $state->{autoImportFailures} = int($state->{autoImportFailures} // 0);
    $state->{autoImportRetryAt} = int($state->{autoImportRetryAt} // 0);
    $state->{coverageDate} //= '';
    $state->{coverageSeconds} = int($state->{coverageSeconds} // 0);
    $state->{discardedSessions} = int($state->{discardedSessions} // 0);
    $state->{importInfo} = {} if ref $state->{importInfo} ne 'HASH';
    delete $state->{lastDbLogImportAttemptDate};
    for my $entry (values %{$state->{managed}}) {
        next if ref $entry ne 'HASH';
        delete @{$entry}{qw(startedAt bin weekday offSentAt)};
    }
    for my $entry (values %{$state->{dryManaged}}) {
        next if ref $entry ne 'HASH';
        my %minimal = map { $_ => $entry->{$_} } qw(offDue durationMinutes modelType);
        %{$entry} = %minimal;
    }
    if (($state->{importInfo}{state} // '') eq 'running') {
        $state->{importInfo}{state} = 'interrupted';
        $state->{importInfo}{finished} ||= PresenceSimulation_FormatDateTime(CORE::time());
        $state->{importInfo}{error} ||= 'FHEM or the module was restarted while the import was running';
    }
    if ($state->{coverageDate} ne '' && $state->{coverageSeconds} > 0) {
        my $day = (
            $data->{raw}{days}{$state->{coverageDate}}
                //= PresenceSimulation_EmptyRawDay($state->{coverageDate})
        );
        $day->{trainingSeconds} = $state->{coverageSeconds}
            if ($state->{coverageSeconds} > int($day->{trainingSeconds} // 0));
    }

    my $now = CORE::time();
    for my $dev (keys %{$state->{expected}}) {
        delete $state->{expected}{$dev}
            if ($state->{expected}{$dev}{until} // 0) < $now;
    }

    $data->{model} = PresenceSimulation_EmptyModel($name)
        if ref $data->{model} ne 'HASH';
    $data->{config} = PresenceSimulation_EmptyConfig()
        if ref $data->{config} ne 'HASH';
    $data->{dirty} = {} if ref $data->{dirty} ne 'HASH';
    return;
}

# Initializes a module instance, loads data, and starts the internal timers.
sub PresenceSimulation_Define {
    my ($hash, $def) = @_;
    my @a = split /\s+/, $def;

    return 'Usage: define <name> PresenceSimulation' if @a != 2;
    return $@ unless FHEM::Meta::SetInternals($hash);

    my $name = $hash->{NAME};
    $hash->{VERSION} = $PRESENCE_SIM_VERSION;
    PresenceSimulation_ApplyUiDefaults($hash);

    $PresenceSimulation_DATA{$name} = PresenceSimulation_NewInstanceData($name);

    PresenceSimulation_LoadAll($hash);

    my $mode = $PresenceSimulation_DATA{$name}{state}{mode} // 'off';
    $mode = 'off' if $mode !~ /^(?:training|playback|dryrun|off)$/;
    $PresenceSimulation_DATA{$name}{state}{mode} = $mode;

    PresenceSimulation_InitializeErrorReadings($hash);
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'mode',                  $mode);
    readingsBulkUpdate($hash, 'state',                 $mode);
    readingsBulkUpdate($hash, 'configuredDevices',     0);
    readingsBulkUpdate($hash, 'trainingDaysUsed',      0);
    readingsBulkUpdate($hash, 'effectiveTrainingDays', 0);
    readingsBulkUpdate($hash, 'modelSessions',         0);
    readingsBulkUpdate($hash, 'rawSessions',           0);
    readingsBulkUpdate($hash, 'rawSessionsToday',          0);
    readingsBulkUpdate($hash, 'rawSessionsTodayDiscarded', 0);
    readingsBulkUpdate($hash, 'rawDays',                   0);
    readingsBulkUpdate($hash, 'activeTraining',        0);
    readingsBulkUpdate($hash, 'activePlayback',        0);
    readingsBulkUpdate($hash, 'stoppingPlayback',      0);
    readingsBulkUpdate($hash, 'activeDryRun',          0);
    readingsBulkUpdate(
        $hash, 'importState',
        PresenceSimulation_AsHash($PresenceSimulation_DATA{$name}{state}{importInfo})->{state} // 'idle'
    );
    readingsBulkUpdate($hash, 'nextDbLogImport', '-');
    readingsEndUpdate($hash, 1);

    setNotifyDev($hash, 'global');

    if ($init_done) {
        PresenceSimulation_ScheduleInit($hash, 0.2);
        PresenceSimulation_ScheduleTick($hash);
    }

    return;
}

# Sends one final OFF command to every real device still owned by playback.
# This is used when no later timer cycle can confirm or retry the command.
sub PresenceSimulation_SwitchOffManagedDevices {
    my ($hash, $reason) = @_;
    return if !$hash;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});
    my $managed = PresenceSimulation_AsHash($data->{state}{managed});
    my @errors;
    my $now = CORE::time();

    for my $dev (sort keys %{$managed}) {
        my $entry = PresenceSimulation_AsHash($managed->{$dev});
        if ($entry->{offFailed}) {
            PresenceSimulation_ReleaseManagedOffFailure($hash, $dev, $entry);
            next;
        }
        my $cfg = PresenceSimulation_ConfigForManagedEntry($data, $dev, $entry);
        if (!$cfg) {
            push @errors, "cannot determine off command for managed device $dev";
            next;
        }

        $entry->{stopping} = 1;
        $entry->{offRetryDue} = $now
            if !$entry->{offFailed}
            && int($entry->{offAttempts} // 0) < $PRESENCE_SIM_OFF_MAX_ATTEMPTS;
        my $status = PresenceSimulation_ProcessManagedOffEntry(
            $hash, $dev, $entry, $cfg, $now
        );
        push @errors, "$dev off attempt failed"
            if $status eq 'command-error' || $status eq 'missing';
        PresenceSimulation_Log($hash, 3, "$reason: requested managed OFF for $dev")
            if $status eq 'sent';
    }

    PresenceSimulation_MarkDirty($hash, 'state') if keys %{$managed};
    if (@errors) {
        PresenceSimulation_SetError($hash, join('; ', @errors), 'playback');
        return join('; ', @errors);
    }
    return;
}

# Saves the state and removes timers and instance data.
sub PresenceSimulation_Undef {
    my ($hash, $arg) = @_;
    my $name = $hash->{NAME};

    PresenceSimulation_Log($hash, 4, 'undefining module instance');
    $hash->{helper}{teardown} = 1;
    PresenceSimulation_AbortRunningImport($hash, 'module instance removed', 'aborted');
    RemoveInternalTimer($hash);
    delete $hash->{helper}{saveScheduled};
    PresenceSimulation_SwitchOffManagedDevices($hash, 'module instance removed');
    PresenceSimulation_SaveAll($hash, 1);
    delete $PresenceSimulation_DATA{$name};
    return;
}

# Removes persistent files when the FHEM definition is permanently deleted.
sub PresenceSimulation_Delete {
    my ($hash, $name) = @_;
    my $files = PresenceSimulation_FileNamesForName($name, 0);
    my @errors;

    for my $part (qw(raw state)) {
        my $base = $files->{$part};
        my @candidates = ($base, "$base.bak", "$base.tmp", glob("$base.corrupt.*"), glob("$base.preRename.*"));
        for my $file (@candidates) {
            next if !defined $file || !-e $file;
            push @errors, "cannot remove $file: $!" if !unlink($file);
        }
    }

    return join('; ', @errors) if @errors;
    return;
}

# Moves in-memory state and persistent files after a FHEM device rename.
sub PresenceSimulation_Rename {
    my ($newName, $oldName) = @_;
    my $hash = $defs{$newName};
    return if !$hash;

    $hash->{helper}{teardown} = 1;

    if (exists $PresenceSimulation_DATA{$oldName}) {
        $PresenceSimulation_DATA{$newName} = delete $PresenceSimulation_DATA{$oldName};
    }
    else {
        $PresenceSimulation_DATA{$newName} = PresenceSimulation_NewInstanceData($newName);
    }

    PresenceSimulation_AbortRunningImport($hash, 'device renamed', 'aborted by rename');
    RemoveInternalTimer($hash);
    delete $hash->{helper}{saveScheduled};

    my $data = $PresenceSimulation_DATA{$newName};
    for my $part (qw(raw state)) {
        $data->{$part}{deviceName} = $newName if ref $data->{$part} eq 'HASH';
    }

    my $oldFiles = PresenceSimulation_FileNamesForName($oldName, 0);
    my $newFiles = PresenceSimulation_FileNamesForName($newName, 1);
    my @errors;
    my $stamp = CORE::time();

    for my $part (qw(raw state)) {
        for my $suffix ('', '.bak', '.tmp') {
            my $oldFile = $oldFiles->{$part} . $suffix;
            my $newFile = $newFiles->{$part} . $suffix;
            next if !-e $oldFile;

            if (-e $newFile) {
                my $archive = "$newFile.preRename.$stamp";
                push @errors, "cannot preserve existing $newFile: $!"
                    if !rename($newFile, $archive);
            }
            push @errors, "cannot rename $oldFile to $newFile: $!"
                if !rename($oldFile, $newFile);
        }
    }

    $hash->{VERSION} = $PRESENCE_SIM_VERSION;
    setNotifyDev($hash, 'global');
    PresenceSimulation_MarkDirty($hash, qw(raw state));
    PresenceSimulation_SaveAll($hash, 1);

    if (@errors) {
        PresenceSimulation_SetError($hash, join('; ', @errors), 'persistence');
    }
    else {
        PresenceSimulation_Log($hash, 3, "renamed module instance from $oldName to $newName");
    }

    delete $hash->{helper}{teardown};
    if ($init_done) {
        PresenceSimulation_ScheduleInit($hash, 0.1);
        PresenceSimulation_ScheduleTick($hash);
    }
    return;
}

# Saves all module files when FHEM shuts down.
sub PresenceSimulation_Shutdown {
    my ($hash) = @_;
    PresenceSimulation_Log($hash, 4, 'shutdown: stopping managed devices and saving module data');
    $hash->{helper}{teardown} = 1;
    PresenceSimulation_AbortRunningImport($hash, 'FHEM shutdown', 'aborted');
    RemoveInternalTimer($hash);
    delete $hash->{helper}{saveScheduled};
    PresenceSimulation_SwitchOffManagedDevices($hash, 'FHEM shutdown');
    PresenceSimulation_SaveAll($hash, 1);
    return;
}

# Handles the module set commands.
sub PresenceSimulation_Set {
    my ($hash, @a) = @_;
    return 'set needs at least one argument' if @a < 2;

    my $name = shift @a;
    my $cmd  = shift @a;
    my $list = 'mode:training,playback,dryrun,off save:noArg rebuildModel:noArg importDbLog '
        . 'resetTrainingData:confirm';

    if ($cmd eq 'mode') {
        return 'Usage: set <name> mode training|playback|dryrun|off' if @a != 1;
        return PresenceSimulation_SetMode($hash, $a[0]);
    }

    if ($cmd eq 'save') {
        PresenceSimulation_SaveAll($hash, 1);
        return;
    }

    if ($cmd eq 'rebuildModel') {
        PresenceSimulation_RebuildModel($hash);
        PresenceSimulation_SaveAll($hash, 1);
        return;
    }

    if ($cmd eq 'importDbLog') {
        return 'Usage: set <name> importDbLog [days]' if @a > 1;
        my $configError = PresenceSimulation_ValidateDbLogConfiguration($hash);
        return $configError if $configError;

        my $retentionDays = PresenceSimulation_EffectiveRetentionDays($name);
        my $days = @a == 1 ? int($a[0]) : $retentionDays;
        return "Import days must be between 1 and retentionDays ($retentionDays)"
            if $days < 1 || $days > $retentionDays;

        my $dbLogName = AttrVal($name, 'dbLogDevice', '');
        return PresenceSimulation_StartDbLogImport($hash, $dbLogName, $days, 'manual');
    }

    if ($cmd eq 'resetTrainingData') {
        return 'Usage: set <name> resetTrainingData confirm' if @a != 1 || $a[0] ne 'confirm';

        PresenceSimulation_AbortRunningImport($hash, 'training data reset', 'aborted by reset');
        PresenceSimulation_StopPlayback($hash, 1);
        PresenceSimulation_StopDryRun($hash);
        $PresenceSimulation_DATA{$name}{raw}   = PresenceSimulation_EmptyRaw($name);
        $PresenceSimulation_DATA{$name}{model} = PresenceSimulation_EmptyModel($name);
        $PresenceSimulation_DATA{$name}{state}{activeSessions} = {};
        $PresenceSimulation_DATA{$name}{state}{playedBins}     = {};
        $PresenceSimulation_DATA{$name}{state}{dryPlayedBins}  = {};
        $PresenceSimulation_DATA{$name}{state}{plannedBins}    = {};
        $PresenceSimulation_DATA{$name}{state}{dryPlannedBins} = {};
        $PresenceSimulation_DATA{$name}{state}{discardedSessions} = 0;
        $PresenceSimulation_DATA{$name}{state}{importInfo} = { state => 'idle' };
        readingsSingleUpdate($hash, 'importState', 'idle', 1);
        PresenceSimulation_MarkDirty($hash, qw(raw state));
        PresenceSimulation_UpdateReadings($hash);
        PresenceSimulation_SaveAll($hash, 1);
        PresenceSimulation_Log($hash, 2, 'training data reset by user');
        return;
    }

    return "Unknown argument $cmd, choose one of $list";
}

# Encapsulates the DbLog internals used by the import worker.
sub PresenceSimulation_DbLogConnectionInfo {
    my ($dbLogName) = @_;
    my $dbHash = $defs{$dbLogName};
    return (undef, "DbLog device $dbLogName does not exist") if !$dbHash;
    return (undef, "Device $dbLogName is not a DbLog device")
        if ($dbHash->{TYPE} // '') ne 'DbLog';

    my $info = {
        dbconn => $dbHash->{dbconn} // '',
        dbuser => $dbHash->{dbuser} // '',
        dbpass => AttrVal("sec$dbLogName", 'secret', ''),
        table  => $dbHash->{HELPER}{TH} // 'history',
    };
    return (undef, "DbLog device $dbLogName has no database connection information")
        if $info->{dbconn} eq '';
    return (undef, "Invalid DbLog history table name '$info->{table}'")
        if $info->{table} !~ /^[A-Za-z0-9_.]+$/;
    return ($info, undef);
}

# Starts a nonblocking one-time import from a DbLog history table.
sub PresenceSimulation_StartDbLogImport {
    my ($hash, $dbLogName, $days, $context) = @_;
    $context //= 'manual';
    my $name = $hash->{NAME};

    return 'A DbLog import is already running' if $hash->{helper}{importPid};
    my $configuredDbLog = AttrVal($name, 'dbLogDevice', '');
    return 'Attribute dbLogDevice must be set for DbLog imports' if $configuredDbLog eq '';
    return "Import device $dbLogName differs from configured dbLogDevice $configuredDbLog"
        if $dbLogName ne $configuredDbLog;

    my $configError = PresenceSimulation_ValidateDbLogConfiguration($hash, $dbLogName);
    return $configError if $configError;

    my $configErrorNow = PresenceSimulation_EnsureConfigReady($hash);
    return $configErrorNow if defined $configErrorNow;

    my ($dbInfo, $dbInfoError) = PresenceSimulation_DbLogConnectionInfo($dbLogName);
    return $dbInfoError if $dbInfoError;

    my @targetDates = reverse PresenceSimulation_PreviousDates($days);
    return 'Unable to determine the import date range' if !@targetDates;

    my $targetStart = PresenceSimulation_EpochFromDateTime($targetDates[0] . ' 00:00:00');
    my $targetEnd   = PresenceSimulation_EpochFromDateTime(PresenceSimulation_Date(CORE::time()) . ' 00:00:00');
    return 'Unable to calculate the import date range' if !defined $targetStart || !defined $targetEnd;

    my ($devices, $maxDuration) = PresenceSimulation_ImportDeviceDefinitions($hash);

    my $queryStart = $targetStart - ($maxDuration * 60) - 60;
    my $queryEnd   = $targetEnd + ($maxDuration * 60) + 60;
    $queryEnd = CORE::time() if $queryEnd > CORE::time();

    my $generation = int($hash->{helper}{importGeneration} // 0) + 1;
    $hash->{helper}{importGeneration} = $generation;
    my $token = join('-', CORE::time(), $$, $generation, int(rand(1_000_000)));
    my $fingerprint = PresenceSimulation_ImportFingerprint($hash);

    PresenceSimulation_CleanupImportTempFiles();

    my $params = {
        moduleName  => $name, dbLogName => $dbLogName, dbconn => $dbInfo->{dbconn},
        dbuser      => $dbInfo->{dbuser}, dbpass => $dbInfo->{dbpass}, table => $dbInfo->{table},
        targetStart => $targetStart, targetEnd => $targetEnd,
        queryStart  => PresenceSimulation_FormatDateTime($queryStart),
        queryEnd    => PresenceSimulation_FormatDateTime($queryEnd),
        targetDates => \@targetDates, devices => $devices,
        importToken => $token, configFingerprint => $fingerprint,
    };

    my $safeName = $name;
    $safeName =~ s/[^A-Za-z0-9_.-]+/_/g;
    my ($parameterHandle, $parameterFile);
    my $parameterError;
    eval {
        ($parameterHandle, $parameterFile) = tempfile(
            "PresenceSimulation_DbLogParams_${safeName}_XXXXXX",
            TMPDIR => 1,
            UNLINK => 0,
        );
        binmode($parameterHandle, ':encoding(UTF-8)')
            or die "Cannot set UTF-8 mode for secure import parameters: $!";
        chmod 0600, $parameterFile
            or die "Cannot restrict permissions for secure import parameters: $!";
        print {$parameterHandle} JSON::PP->new->canonical->encode($params)
            or die "Cannot write secure import parameters: $!";
        close $parameterHandle
            or die "Cannot close secure import parameters: $!";
        1;
    } or $parameterError = $@ || 'unknown parameter-file error';

    if ($parameterError) {
        close $parameterHandle if $parameterHandle;
        unlink $parameterFile if defined $parameterFile && -e $parameterFile;
        $parameterError = PresenceSimulation_OneLineError($parameterError);
        return "Unable to create secure DbLog import parameters: $parameterError";
    }

    my $argument = JSON::PP->new->canonical->encode({
        moduleName       => $name,
        importToken      => $token,
        configFingerprint => $fingerprint,
        parameterFile    => $parameterFile,
    });

    PresenceSimulation_SetImportInfo(
        $hash,
        state          => 'running',
        context        => $context,
        source         => $dbLogName,
        days           => $days,
        rows           => 0,
        targetRows     => 0,
        sessions       => 0,
        daysWithRows   => 0,
        firstTimestamp => '',
        lastTimestamp  => '',
        started        => PresenceSimulation_FormatDateTime(CORE::time()),
        finished       => '',
        error          => '',
    );

    PresenceSimulation_Log($hash, 3,
        "DbLog import started: context=$context, source=$dbLogName, days=$days, retentionDays="
        . PresenceSimulation_EffectiveRetentionDays($name) . ", devices=" . scalar(@{$devices}));

    my $pid = BlockingCall(
        'PresenceSimulation_DbLogImportWorker', $argument,
        'PresenceSimulation_DbLogImportDone', 300,
        'PresenceSimulation_DbLogImportAbort', "$name|$token"
    );
    if (!$pid) {
        unlink $parameterFile if defined $parameterFile && -e $parameterFile;
        PresenceSimulation_SetImportInfo(
            $hash, state => 'error',
            finished => PresenceSimulation_FormatDateTime(CORE::time()),
            error => 'Unable to start DbLog import worker',
        );
        return 'Unable to start DbLog import worker';
    }

    $hash->{helper}{importPid} = $pid;
    $hash->{helper}{importContext} = $context;
    $hash->{helper}{importToken} = $token;
    $hash->{helper}{importFingerprint} = $fingerprint;
    $hash->{helper}{importParamFile} = $parameterFile;
    return;
}


# Reads historical switching events in a child process and writes compact import data to a temporary file.
sub PresenceSimulation_DbLogImportWorker {
    my ($argument) = @_;
    my $public = eval { JSON::PP->new->decode($argument) };
    if ($@ || ref $public ne 'HASH') {
        return PresenceSimulation_EncodeImportResponse(
            '', '',
            { ok => 0, error => "Invalid public import parameters: $@" }
        );
    }

    my $moduleName = $public->{moduleName} // '';
    my $token = $public->{importToken} // '';
    my $fingerprint = $public->{configFingerprint} // '';
    my $parameterFile = $public->{parameterFile} // '';
    my ($params, $parameterError);

    eval {
        die 'Secure import parameter file is missing'
            if $parameterFile eq '';
        open my $parameterHandle, '<:encoding(UTF-8)', $parameterFile
            or die "Cannot open secure import parameters: $!";
        local $/;
        my $parameterJson = <$parameterHandle>;
        close $parameterHandle
            or die "Cannot close secure import parameters: $!";
        unlink $parameterFile
            or die "Cannot remove secure import parameters: $!";
        $params = JSON::PP->new->decode($parameterJson);
        die 'Secure import parameters are not an object'
            if ref $params ne 'HASH';
        die 'Secure import parameter identity mismatch'
            if ($params->{moduleName} // '') ne $moduleName
            || ($params->{importToken} // '') ne $token
            || ($params->{configFingerprint} // '') ne $fingerprint;
        1;
    } or $parameterError = $@ || 'unknown secure parameter error';

    if ($parameterError) {
        unlink $parameterFile if $parameterFile ne '' && -e $parameterFile;
        $parameterError = PresenceSimulation_OneLineError($parameterError);
        return PresenceSimulation_EncodeImportResponse(
            $moduleName, $token,
            {
                ok                => 0,
                moduleName        => $moduleName,
                importToken       => $token,
                configFingerprint => $fingerprint,
                error             => $parameterError,
            }
        );
    }

    my $resultFile;
    my $result = eval {
        require DBI;

        my $dsn = $params->{dbconn} =~ /^dbi:/i
            ? $params->{dbconn}
            : 'dbi:' . $params->{dbconn};
        my $dbh = DBI->connect(
            $dsn,
            $params->{dbuser},
            $params->{dbpass},
            {
                RaiseError          => 1,
                PrintError          => 0,
                AutoCommit          => 1,
                ShowErrorStatement  => 1,
                AutoInactiveDestroy => 1,
            }
        );
        die 'Database connection failed' if !$dbh;

        my @clauses;
        my @bind = ($params->{queryStart}, $params->{queryEnd});
        my %selectedSources;
        for my $deviceDef (@{$params->{devices}}) {
            my $readingDevice = $deviceDef->{readingDevice} // $deviceDef->{device};
            my $sourceKey = join("\0", $readingDevice, $deviceDef->{reading});
            next if $selectedSources{$sourceKey}++;
            push @clauses, '(DEVICE = ? AND READING = ?)';
            push @bind, $readingDevice, $deviceDef->{reading};
        }
        die 'No device definitions supplied' if !@clauses;

        my $sql = 'SELECT TIMESTAMP, DEVICE, READING, VALUE FROM ' . $params->{table}
            . ' WHERE TIMESTAMP >= ? AND TIMESTAMP < ? AND ('
            . join(' OR ', @clauses)
            . ') ORDER BY TIMESTAMP ASC, DEVICE ASC, READING ASC';

        my $sth = $dbh->prepare($sql);
        $sth->execute(@bind);

        my %cfgBySource;
        for my $deviceDef (@{$params->{devices}}) {
            my $readingDevice = $deviceDef->{readingDevice} // $deviceDef->{device};
            my $onRe  = eval { qr/$deviceDef->{onPattern}/ };
            die "Invalid onRegex for $deviceDef->{device}: $@" if $@;
            my $offRe = eval { qr/$deviceDef->{offPattern}/ };
            die "Invalid offRegex for $deviceDef->{device}: $@" if $@;
            my $sourceKey = join("\0", $readingDevice, $deviceDef->{reading});
            push @{$cfgBySource{$sourceKey}}, {
                %{$deviceDef},
                readingDevice => $readingDevice,
                onRe => $onRe,
                offRe => $offRe,
            };
        }

        my (%active, %lastState, %days, %rowDates);
        my $rowCount = 0;
        my $targetRowCount = 0;
        my $sessionCount = 0;
        my ($firstTimestamp, $lastTimestamp);

        while (my $row = $sth->fetchrow_arrayref) {
            $rowCount++;
            my ($timestamp, $readingDevice, $reading, $value) = @{$row};
            my $sourceKey = join("\0", $readingDevice, $reading);
            my $configs = $cfgBySource{$sourceKey};
            next if ref $configs ne 'ARRAY' || !@{$configs};

            my $epoch = PresenceSimulation_EpochFromDateTime($timestamp);
            next if !defined $epoch;
            if ($epoch >= $params->{targetStart} && $epoch < $params->{targetEnd}) {
                $targetRowCount++;
                $firstTimestamp //= $timestamp;
                $lastTimestamp = $timestamp;
                $rowDates{substr($timestamp, 0, 10)} = 1 if defined $timestamp && length($timestamp) >= 10;
            }

            for my $cfg (@{$configs}) {
                my $logicalDevice = $cfg->{device};
                my $state;
                $state = 'on'  if defined $value && $value =~ $cfg->{onRe};
                $state = 'off' if defined $value && $value =~ $cfg->{offRe};
                next if !defined $state;

                my $previous = $lastState{$logicalDevice};
                $lastState{$logicalDevice} = $state;
                next if defined $previous && $previous eq $state;

                if ($state eq 'on') {
                    $active{$logicalDevice} = $epoch if !$active{$logicalDevice};
                    next;
                }

                my $startedAt = delete $active{$logicalDevice};
                next if !defined $startedAt;

                my $duration = int(($epoch - $startedAt + 30) / 60);
                next if $duration < $cfg->{minDuration} || $duration > $cfg->{maxDuration};
                next if $startedAt < $params->{targetStart} || $startedAt >= $params->{targetEnd};

                my $date = PresenceSimulation_Date($startedAt);
                push @{$days{$date}{sessions}{$logicalDevice}}, {
                    startMinute     => PresenceSimulation_MinuteOfDay($startedAt),
                    durationMinutes => $duration,
                    weekday         => PresenceSimulation_WeekdayIndex($startedAt),
                    startedAt       => $startedAt,
                    endedAt         => $epoch,
                    source          => 'dblog',
                    sourceDevice    => $params->{dbLogName},
                };
                $sessionCount++;
            }
        }

        $sth->finish;
        $dbh->disconnect;

        my $safeName = $params->{moduleName};
        $safeName =~ s/[^A-Za-z0-9_.-]+/_/g;
        my ($fh, $file) = tempfile(
            "PresenceSimulation_DbLogImport_${safeName}_XXXXXX",
            TMPDIR => 1,
            UNLINK => 0,
        );
        $resultFile = $file;
        binmode($fh, ':encoding(UTF-8)') or die "Cannot set UTF-8 mode for $file: $!";
        chmod 0600, $file or die "Cannot restrict permissions for $file: $!";
        print {$fh} JSON::PP->new->canonical->encode({
            moduleName   => $params->{moduleName},
            dbLogName    => $params->{dbLogName},
            targetDates  => $params->{targetDates},
            rows         => $rowCount,
            targetRows   => $targetRowCount,
            sessionCount => $sessionCount,
            daysWithRows => scalar(keys %rowDates),
            firstTimestamp => $firstTimestamp,
            lastTimestamp  => $lastTimestamp,
            importToken => $params->{importToken},
            configFingerprint => $params->{configFingerprint},
            days         => \%days,
        });
        close $fh or die "Cannot close $file: $!";

        return {
            ok                => 1,
            file              => $file,
            rows              => $rowCount,
            targetRows        => $targetRowCount,
            sessions          => $sessionCount,
            moduleName        => $params->{moduleName},
            importToken       => $params->{importToken},
            configFingerprint => $params->{configFingerprint},
        };
    };

    if ($@) {
        my $error = $@;
        $error = PresenceSimulation_OneLineError($error);
        unlink $resultFile if defined $resultFile && -e $resultFile;
        return PresenceSimulation_EncodeImportResponse(
            $moduleName, $token,
            {
                ok                => 0,
                moduleName        => $moduleName,
                importToken       => $token,
                configFingerprint => $fingerprint,
                error             => $error,
            }
        );
    }

    return PresenceSimulation_EncodeImportResponse($moduleName, $token, $result);
}

# Merges imported sessions into raw data, rebuilds the model, and stores the result.
sub PresenceSimulation_DbLogImportDone {
    my ($response) = @_;
    my ($meta, $envelopeName, $envelopeToken, $decodeError) =
        PresenceSimulation_DecodeImportResponse($response);
    if ($decodeError) {
        $decodeError = PresenceSimulation_OneLineError($decodeError);
        PresenceSimulation_FailActiveImportsForMalformedResponse(
            "DbLog import callback failed: $decodeError"
        );
        return;
    }

    my $name = $envelopeName ne '' ? $envelopeName : ($meta->{moduleName} // '');
    my $hash = $defs{$name};
    if (!$hash || ($hash->{TYPE} // '') ne 'PresenceSimulation') {
        unlink $meta->{file} if $meta->{file} && -e $meta->{file};
        return;
    }

    my $expectedToken = $hash->{helper}{importToken} // '';
    my $responseToken = $envelopeToken ne '' ? $envelopeToken : ($meta->{importToken} // '');
    my $context = $hash->{helper}{importContext} // 'manual';
    my $stale = !$expectedToken || $responseToken ne $expectedToken;
    if (!$stale) {
        my $expectedFingerprint = $hash->{helper}{importFingerprint} // '';
        $stale = ($meta->{configFingerprint} // '') ne $expectedFingerprint
            || PresenceSimulation_ImportFingerprint($hash) ne $expectedFingerprint;
    }

    if ($stale) {
        unlink $meta->{file} if $meta->{file} && -e $meta->{file};
        if ($expectedToken ne '' && $responseToken eq $expectedToken) {
            PresenceSimulation_ClearImportRuntime($hash);
            PresenceSimulation_SetImportInfo(
                $hash, state => 'stale result ignored',
                finished => PresenceSimulation_FormatDateTime(CORE::time()),
                error => 'configuration changed while import was running',
            );
        }
        PresenceSimulation_Log($hash, 2, 'ignored stale DbLog import result after configuration change or reset');
        return;
    }

    PresenceSimulation_ClearImportRuntime($hash);

    if (!$meta->{ok}) {
        my $error = 'DbLog import failed: ' . ($meta->{error} // 'unknown error');
        PresenceSimulation_FailImport($hash, $error, 'error');
        return;
    }

    my ($importData, $readError);
    eval {
        open my $fh, '<:encoding(UTF-8)', $meta->{file} or die "Cannot open $meta->{file}: $!";
        local $/;
        $importData = JSON::PP->new->decode(<$fh>);
        close $fh or die "Cannot close $meta->{file}: $!";
        1;
    } or $readError = $@;
    unlink $meta->{file} if $meta->{file} && -e $meta->{file};

    if ($readError || ref $importData ne 'HASH') {
        $readError //= 'invalid worker result';
        $readError = PresenceSimulation_OneLineError($readError);
        PresenceSimulation_FailImport(
            $hash, "DbLog import result could not be read: $readError", 'error'
        );
        return;
    }

    if (($importData->{importToken} // '') ne $responseToken
        || ($importData->{configFingerprint} // '') ne PresenceSimulation_ImportFingerprint($hash)) {
        my $message = 'DbLog import result identity does not match the active configuration';
        PresenceSimulation_FailImport($hash, $message, 'error');
        return;
    }

    my $rows = int($importData->{rows} // 0);
    my $targetRows = int($importData->{targetRows} // 0);
    my $workerSessions = int($importData->{sessionCount} // 0);
    my $targetDateCount = scalar @{PresenceSimulation_AsArray($importData->{targetDates})};
    if ($targetRows <= 0) {
        my $message =
            'DbLog import returned no rows in the requested date range; '
            . 'existing training data was left unchanged';
        PresenceSimulation_FailImport(
            $hash, $message, 'error', rows => $rows, targetRows => $targetRows
        );
        return;
    }
    if ($targetDateCount >= 7 && $workerSessions <= 0) {
        my $message =
            'DbLog import reconstructed no complete sessions for a multi-day range; '
            . 'existing training data was left unchanged';
        PresenceSimulation_FailImport(
            $hash, $message, 'error',
            rows => $rows, targetRows => $targetRows, sessions => $workerSessions
        );
        return;
    }

    my $data = $PresenceSimulation_DATA{$name};
    my $dbLogName = $importData->{dbLogName} // '';
    my $importedAt = CORE::time();
    my $inserted = 0;

    for my $date (@{PresenceSimulation_AsArray($importData->{targetDates})}) {
        my $day = ($data->{raw}{days}{$date} //= PresenceSimulation_EmptyRawDay($date));
        my $importDay = PresenceSimulation_AsHash($importData->{days}{$date});
        my $importSessions = PresenceSimulation_AsHash($importDay->{sessions});
        my %replacement;

        for my $device (@{$data->{config}{order}}) {
            my @fresh = map { { %{$_} } } @{PresenceSimulation_AsArray($importSessions->{$device})};
            next if !@fresh;
            $replacement{$device} = \@fresh;
            $inserted += scalar @fresh;
        }

        $day->{weekday} = PresenceSimulation_WeekdayForDate($date);
        $day->{trainingSeconds} = 86400;
        $day->{discardedSessions} = 0;
        $day->{sessions} = \%replacement;
        $day->{source} = 'dblog';
        $day->{importedFromDbLog} = $dbLogName;
        $day->{importedAt} = $importedAt;
    }

    $data->{state}{lastDbLogImportDate} = PresenceSimulation_Date(CORE::time());
    $data->{state}{autoImportFailures} = 0;
    $data->{state}{autoImportRetryAt} = 0;

    PresenceSimulation_MarkDirty($hash, qw(raw state));
    PresenceSimulation_PruneRaw($hash);
    PresenceSimulation_RebuildModel($hash);
    PresenceSimulation_SetImportInfo(
        $hash,
        state          => 'done',
        rows           => $rows,
        targetRows     => $targetRows,
        sessions       => $inserted,
        daysWithRows   => int($importData->{daysWithRows} // 0),
        firstTimestamp => $importData->{firstTimestamp} // '',
        lastTimestamp  => $importData->{lastTimestamp} // '',
        finished       => PresenceSimulation_FormatDateTime(CORE::time()),
        error          => '',
    );
    PresenceSimulation_SaveAll($hash, 1);

    PresenceSimulation_ClearError($hash, 'dblog');
    PresenceSimulation_UpdateReadings($hash);
    PresenceSimulation_Log($hash, 3,
        "DbLog import completed: context=$context, rows=$rows, importedSessions=$inserted, usableDays="
        . scalar(@{PresenceSimulation_AsArray($data->{model}{validDates})}));
    PresenceSimulation_ScheduleAutoImport($hash);
    return;
}


# Handles a timeout or explicit termination of the nonblocking import worker.
sub PresenceSimulation_DbLogImportAbort {
    my ($argument, $blockingReason) = @_;
    my ($name, $token) = split /\|/, ($argument // ''), 2;
    my $hash = $defs{$name};
    return if !$hash;
    return if ($hash->{helper}{importToken} // '') ne ($token // '');

    my $message = 'DbLog import timed out or was aborted';
    if (defined $blockingReason && $blockingReason ne '') {
        $blockingReason = PresenceSimulation_OneLineError($blockingReason);
        $message .= ": $blockingReason";
    }
    PresenceSimulation_ClearImportRuntime($hash);
    PresenceSimulation_FailImport($hash, $message, 'timeout');
    return;
}


# Runs a diagnostic callback and reports exceptions consistently.
sub PresenceSimulation_RunDiagnostic {
    my ($hash, $label, $callback) = @_;
    my $result = eval { $callback->() };
    if ($@) {
        my $error = PresenceSimulation_OneLineError("$label failed: $@");
        PresenceSimulation_SetError($hash, $error, 'diagnostic');
        return $error;
    }
    return $result;
}

# Returns model, file, and probability information.
sub PresenceSimulation_Get {
    my ($hash, @a) = @_;
    return 'get needs at least one argument' if @a < 2;

    shift @a;
    my $cmd = shift @a;
    my $list = 'modelInfo:noArg importInfo:noArg fileInfo:noArg probability';

    return PresenceSimulation_RunDiagnostic(
        $hash, 'modelInfo', sub { PresenceSimulation_ModelInfo($hash) }
    ) if $cmd eq 'modelInfo';

    return PresenceSimulation_RunDiagnostic(
        $hash, 'importInfo', sub { PresenceSimulation_ImportInfo($hash) }
    ) if $cmd eq 'importInfo';

    if ($cmd eq 'fileInfo') {
        return PresenceSimulation_RunDiagnostic($hash, 'fileInfo', sub {
            my $files = PresenceSimulation_FileNames($hash);
            return join "\n",
                map {
                    my $file = $files->{$_};
                    my $size = -e $file ? -s $file : 0;
                    my $modified = -e $file
                        ? PresenceSimulation_FormatDateTime((stat($file))[9])
                        : '-';
                    sprintf(
                        '%-5s %s (%s, modified %s)',
                        $_, $file, PresenceSimulation_FormatFileSize($size), $modified
                    );
                } qw(raw state);
        });
    }

    if ($cmd eq 'probability') {
        return 'Usage: get <name> probability <device> <HH:MM> [weekday]' if @a < 2 || @a > 3;
        return PresenceSimulation_RunDiagnostic(
            $hash, 'probability',
            sub { PresenceSimulation_GetProbability($hash, $a[0], $a[1], $a[2]) }
        );
    }

    return "Unknown argument $cmd, choose one of $list";
}


# Validates the current eventFn attribute value.
sub PresenceSimulation_EventFnSyntaxError {
    my ($handler) = @_;
    return 'eventFn must not be empty' if !defined $handler || $handler !~ /\S/;
    return;
}

# Reinitializes the module after relevant attribute changes.
sub PresenceSimulation_Attr {
    my ($cmd, $name, $attrName, $attrValue) = @_;
    my $hash = $defs{$name};
    return if !$hash;

    if ($attrName =~ /^device(\d\d)$/) {
        return 'device attributes must be numbered device01 through device30'
            if $1 < 1 || $1 > 30;
    }
    elsif ($attrName =~ /^device(\d\d)Block(\d\d)$/) {
        return 'device block attributes must use device01Block01 through device30Block10'
            if $1 < 1 || $1 > 30 || $2 < 1 || $2 > 10;
    }
    elsif ($attrName =~ /^globalBlock(\d\d)$/) {
        return 'global block attributes must be numbered globalBlock01 through globalBlock20'
            if $1 < 1 || $1 > 20;
    }

    if ($attrName eq 'trainingSource' && $cmd eq 'set') {
        return 'trainingSource must be events or dblog'
            if !defined $attrValue || $attrValue !~ /^(?:events|dblog)$/;
        if ($attrValue eq 'dblog' && $init_done) {
            my $dbLogName = AttrVal($name, 'dbLogDevice', '');
            return 'Set attribute dbLogDevice before enabling trainingSource=dblog' if $dbLogName eq '';
            return "DbLog device $dbLogName does not exist" if !$defs{$dbLogName};
            return "Device $dbLogName is not a DbLog device" if ($defs{$dbLogName}{TYPE} // '') ne 'DbLog';
        }
    }

    if ($attrName eq 'dbLogDevice') {
        if ($cmd eq 'set') {
            return 'dbLogDevice must not be empty' if !defined $attrValue || $attrValue eq '';
            return "DbLog device $attrValue does not exist" if $init_done && !$defs{$attrValue};
            return "Device $attrValue is not a DbLog device"
                if $init_done && $defs{$attrValue} && ($defs{$attrValue}{TYPE} // '') ne 'DbLog';
        }
        elsif ($cmd eq 'del' && PresenceSimulation_TrainingSource($name) eq 'dblog') {
            return 'dbLogDevice cannot be deleted while trainingSource=dblog';
        }
    }

    if ($attrName eq 'importTime' && $cmd eq 'set') {
        return 'importTime must use HH:MM (00:00 through 23:59)'
            if !defined $attrValue || $attrValue !~ /^(?:[01]\d|2[0-3]):[0-5]\d$/;
    }

    if ($attrName eq 'eventFn') {
        if ($cmd eq 'set') {
            my $syntaxError = PresenceSimulation_EventFnSyntaxError($attrValue);
            return $syntaxError if defined $syntaxError;
        }
        elsif ($cmd eq 'del') {
            PresenceSimulation_ClearError($hash, 'eventFn');
        }
    }
    elsif ($attrName eq 'eventFnEnabled' && $cmd eq 'set') {
        return 'eventFnEnabled must be 0 or 1'
            if !defined $attrValue || $attrValue !~ /^(?:0|1)$/;
        PresenceSimulation_ClearError($hash, 'eventFn') if !$attrValue;
    }

    if ($cmd eq 'set') {
        if ($attrName eq 'binMinutes') {
            return 'binMinutes must be one of 1, 5, 10, 15, 20, 30, or 60'
                if !PresenceSimulation_IsValidBinMinutes($attrValue);
        }

        my %integerRanges = (
            trainingDays => [1, 90], retentionDays => [1, 365], minTrainingMinutes => [0, 1440],
            saveInterval => [30, 1800], manualLockMinutes => [0, 1440],
        );
        if (exists $integerRanges{$attrName}) {
            my ($min, $max) = @{$integerRanges{$attrName}};
            return "$attrName must be an integer between $min and $max"
                if !defined $attrValue || $attrValue !~ /^\d+$/ || $attrValue < $min || $attrValue > $max;
        }
        if ($attrName eq 'probabilityFactor') {
            return 'probabilityFactor must be a number between 0.1 and 3.0'
                if !defined $attrValue || $attrValue !~ /^(?:\d+(?:\.\d*)?|\.\d+)$/
                || $attrValue < 0.1 || $attrValue > 3.0;
        }
    }

    my $playbackSensitive = $attrName =~ /^(?:
        device\d\d
        | trainingSource | dbLogDevice | trainingDays | retentionDays
        | binMinutes | minTrainingMinutes | weekdaySpecific
    )$/x;
    if (($cmd eq 'set' || $cmd eq 'del') && $playbackSensitive
        && PresenceSimulation_HasManagedPlaybackDevices($hash)) {
        return 'Cannot change device or model configuration while playback devices are active; '
            . 'set mode off and wait until stoppingPlayback is 0';
    }

    my $importRelevant = $attrName =~ /^(?:device\d\d|trainingSource|dbLogDevice|retentionDays)$/;
    if ($importRelevant && $hash->{helper}{importPid}) {
        PresenceSimulation_AbortRunningImport($hash, "attribute $attrName changed", 'aborted by configuration change');
    }

    if ($attrName eq 'disable' && $cmd eq 'set' && $attrValue) {
        PresenceSimulation_StopPlayback($hash, 1);
        PresenceSimulation_StopDryRun($hash);
        PresenceSimulation_AbortRunningImport($hash, 'module disabled', 'aborted by disable');
        RemoveInternalTimer($hash, 'PresenceSimulation_AutoImportTimer');
    }

    my $requiresReinitialization =
           $attrName =~ /^device\d\d$/
        || $attrName =~ /^device\d\dBlock\d\d$/
        || $attrName =~ /^globalBlock\d\d$/
        || $attrName =~ /^(?:
            trainingSource | dbLogDevice | importTime | trainingDays
            | retentionDays | binMinutes | minTrainingMinutes | weekdaySpecific
        )$/x;
    if ($requiresReinitialization) {
        if (ref $PresenceSimulation_DATA{$name} eq 'HASH') {
            $PresenceSimulation_DATA{$name}{state}{plannedBins} = {};
            $PresenceSimulation_DATA{$name}{state}{dryPlannedBins} = {};
            PresenceSimulation_MarkDirty($hash, 'state');
        }
        if ($attrName eq 'trainingSource' && $cmd eq 'set' && $attrValue eq 'dblog'
            && ref $PresenceSimulation_DATA{$name} eq 'HASH') {
            $PresenceSimulation_DATA{$name}{state}{activeSessions} = {};
            PresenceSimulation_MarkDirty($hash, 'state');
        }
        if ($attrName =~ /^(?:trainingSource|dbLogDevice|importTime)$/) {
            RemoveInternalTimer($hash, 'PresenceSimulation_AutoImportTimer');
            if (ref $PresenceSimulation_DATA{$name} eq 'HASH') {
                $PresenceSimulation_DATA{$name}{state}{autoImportFailures} = 0;
                $PresenceSimulation_DATA{$name}{state}{autoImportRetryAt} = 0;
            }
        }
        PresenceSimulation_Log($hash, 4, "attribute $attrName changed, scheduling reinitialization");
        PresenceSimulation_ScheduleInit($hash, 0.2);
    }

    if ($attrName eq 'disable' || $attrName eq 'disabledForIntervals') {
        PresenceSimulation_Log($hash, 4, "attribute $attrName changed, scheduling reinitialization");
        PresenceSimulation_ScheduleInit($hash, 0.2);
    }
    return;
}


# Returns device names referenced by configured devices, conditions, or DbLog configuration.
sub PresenceSimulation_RelevantDeviceNames {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my %relevant = ($name => 1);

    my $dbLogName = AttrVal($name, 'dbLogDevice', '');
    $relevant{$dbLogName} = 1 if $dbLogName ne '';

    for my $number (1 .. 30) {
        my $text = AttrVal($name, sprintf('device%02d', $number), '');
        if ($text ne '') {
            my @parts = eval { shellwords($text) };
            for my $part (@parts) {
                my ($key, $value) = split /=/, $part, 2;
                $relevant{$value} = 1
                    if defined $value && ($key eq 'device' || $key eq 'readingDevice') && $value ne '';
            }
        }

        for my $blockNumber (1 .. 10) {
            my $expression = AttrVal($name, sprintf('device%02dBlock%02d', $number, $blockNumber), '');
            while ($expression =~ /\[([^:\]\s]+):[^\]\s]+\]/g) {
                $relevant{$1} = 1;
            }
        }
    }

    for my $blockNumber (1 .. 20) {
        my $expression = AttrVal($name, sprintf('globalBlock%02d', $blockNumber), '');
        while ($expression =~ /\[([^:\]\s]+):[^\]\s]+\]/g) {
            $relevant{$1} = 1;
        }
    }
    return \%relevant;
}

# Checks whether a global definition event affects this module instance.
sub PresenceSimulation_GlobalEventRelevant {
    my ($hash, $event) = @_;
    return 0 if !defined $event;

    my @devices;
    if ($event =~ /^(?:DEFINED|DELETED|MODIFIED)\s+(\S+)/) {
        @devices = ($1);
    }
    elsif ($event =~ /^RENAMED\s+(\S+)\s+(\S+)/) {
        @devices = ($1, $2);
    }
    else {
        return 0;
    }

    my $relevant = PresenceSimulation_RelevantDeviceNames($hash);
    return scalar grep { $relevant->{$_} } @devices;
}

# Processes events from monitored devices and global FHEM events.

# Returns the current value from the configured observation source.
sub PresenceSimulation_ObservedReadingValue {
    my ($cfg) = @_;
    return undef if ref $cfg ne 'HASH';
    my $readingDevice = $cfg->{readingDevice} // $cfg->{device};
    return ReadingsVal($readingDevice, $cfg->{reading}, undef);
}

# Processes one observed reading value and preserves event order within a batch.
sub PresenceSimulation_ProcessObservedValue {
    my ($hash, $cfg, $value) = @_;
    my $name = $hash->{NAME};
    my $devName = $cfg->{device};
    my $state = PresenceSimulation_ClassifyValue($cfg, $value);
    return 0 if !defined $state;

    my $previous = $hash->{helper}{lastObserved}{$devName};
    $hash->{helper}{lastObserved}{$devName} = $state;
    return 1 if defined $previous && $previous eq $state;

    my $data = $PresenceSimulation_DATA{$name};
    my $mode = $data->{state}{mode} // 'off';
    my $readingDevice = $cfg->{readingDevice} // $devName;
    PresenceSimulation_Log(
        $hash, 5,
        "event $readingDevice:$cfg->{reading}=$value classified as $state for $devName in mode $mode"
    );

    if (PresenceSimulation_IsDisabled($name)) {
        PresenceSimulation_ProcessPlaybackTransition($hash, $cfg, $state)
            if $data->{state}{managed}{$devName};
    }
    elsif (($mode eq 'training' || $mode eq 'dryrun')
        && PresenceSimulation_TrainingSource($name) eq 'events') {
        PresenceSimulation_ProcessTrainingTransition($hash, $cfg, $state);
    }
    elsif ($mode eq 'playback' || $data->{state}{managed}{$devName}) {
        PresenceSimulation_ProcessPlaybackTransition($hash, $cfg, $state);
    }

    readingsSingleUpdate($hash, 'lastEvent', sprintf('%s %s %s', $readingDevice, $cfg->{reading}, $value), 0);
    return 1;
}

sub PresenceSimulation_Notify {
    my ($hash, $dev) = @_;
    my $name = $hash->{NAME};
    my $devName = $dev->{NAME};
    my $events = deviceEvents($dev, 1);
    return if !$events;

    if ($devName eq 'global') {
        for my $event (@{$events}) {
            if ($event =~ /^(?:INITIALIZED|REREADCFG)$/) {
                PresenceSimulation_ScheduleInit($hash, 0.2);
                PresenceSimulation_ScheduleTick($hash);
                last;
            }
            if (PresenceSimulation_GlobalEventRelevant($hash, $event)) {
                PresenceSimulation_ScheduleInit($hash, 0.5);
                last;
            }
        }
        return;
    }

    my $data = $PresenceSimulation_DATA{$name};
    return if !$data;
    my $configs = PresenceSimulation_AsArray($data->{config}{byReadingDevice}{$devName});
    return if !@{$configs};

    for my $cfg (@{$configs}) {
        my $processed = 0;
        for my $event (@{$events}) {
            my $value;
            if ($event =~ /^\Q$cfg->{reading}\E:\s*(.*)$/s) {
                $value = $1;
            }
            elsif ($cfg->{reading} eq 'state') {
                $value = $event;
            }
            next if !defined $value;
            $processed += PresenceSimulation_ProcessObservedValue($hash, $cfg, $value);
        }

        if (!$processed) {
            my $value = PresenceSimulation_ObservedReadingValue($cfg);
            PresenceSimulation_ProcessObservedValue($hash, $cfg, $value) if defined $value;
        }
    }
    return;
}


# Schedules a delayed module reinitialization.
sub PresenceSimulation_ScheduleInit {
    my ($hash, $delay) = @_;
    return if !$init_done || $hash->{helper}{teardown};
    $delay //= 0.2;
    RemoveInternalTimer($hash, 'PresenceSimulation_InitTimer');
    InternalTimer(gettimeofday() + $delay, 'PresenceSimulation_InitTimer', $hash, 0);
    return;
}

# Applies the configuration and rebuilds the model.
sub PresenceSimulation_InitTimer {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return if !$defs{$name} || $hash->{helper}{teardown};

    PresenceSimulation_InitializeErrorReadings($hash);
    my @errors;
    my $ok = eval {
        @errors = PresenceSimulation_BuildConfig($hash);
        my $eventFn = AttrVal($name, 'eventFn', '');
        if ($eventFn ne '') {
            my $eventFnError = PresenceSimulation_EventFnSyntaxError($eventFn);
            push @errors, $eventFnError if defined $eventFnError;
        }
        my @readingDevices = sort keys %{
            PresenceSimulation_AsHash($PresenceSimulation_DATA{$name}{config}{byReadingDevice})
        };
        setNotifyDev($hash, join(',', 'global', @readingDevices));

        my $trainingSource = PresenceSimulation_TrainingSource($name);
        if ($trainingSource eq 'dblog') {
            my $configError = PresenceSimulation_ValidateDbLogConfiguration($hash);
            push @errors, $configError if $configError;
            $PresenceSimulation_DATA{$name}{state}{activeSessions} = {};
        }

        my $mode = $PresenceSimulation_DATA{$name}{state}{mode} // 'off';
        if (@errors && $mode ne 'off') {
            PresenceSimulation_StopPlayback($hash, 1) if $mode eq 'playback';
            PresenceSimulation_StopDryRun($hash) if $mode eq 'dryrun';
            if ($mode eq 'training' || $mode eq 'dryrun') {
                $PresenceSimulation_DATA{$name}{state}{activeSessions} = {};
            }
            $PresenceSimulation_DATA{$name}{state}{mode} = 'off';
            $PresenceSimulation_DATA{$name}{state}{lastCoverageTick} = CORE::time();
            readingsBeginUpdate($hash);
            readingsBulkUpdate($hash, 'mode', 'off');
            readingsBulkUpdate($hash, 'state', 'off');
            readingsEndUpdate($hash, 1);
            PresenceSimulation_MarkDirty($hash, 'state');
        }

        PresenceSimulation_ReconcileRuntimeState($hash);
        PresenceSimulation_PruneRaw($hash);
        PresenceSimulation_RebuildModel($hash);
        PresenceSimulation_UpdateReadings($hash);
        1;
    };

    if (!$ok) {
        my $error = $@ || 'unknown initialization error';
        $error = PresenceSimulation_OneLineError($error);
        PresenceSimulation_SetError($hash, "Initialization failed: $error", 'configuration');
        PresenceSimulation_Log($hash, 1, "initialization failed: $error");
        return;
    }

    if (@errors) {
        PresenceSimulation_SetError($hash, join('; ', @errors), 'configuration');
    }
    else {
        PresenceSimulation_ClearError($hash, 'configuration');
    }

    my $autoImportError = PresenceSimulation_ScheduleAutoImport($hash);
    if ($autoImportError && !grep { $_ eq $autoImportError } @errors) {
        push @errors, $autoImportError;
        PresenceSimulation_SetError($hash, join('; ', @errors), 'configuration');
    }

    my $data = $PresenceSimulation_DATA{$name};
    my @devices = @{$data->{config}{order}};
    my $trainingSource = PresenceSimulation_TrainingSource($name);
    my $modelType = AttrVal($name, 'weekdaySpecific', 0) ? 'weekday-specific' : 'all-days';
    my $usableDays = scalar @{PresenceSimulation_AsArray($data->{model}{validDates})};
    my $sessions = $data->{model}{sessionCount} // 0;
    PresenceSimulation_Log(
        $hash, 3,
        "initialized: devices=" . scalar(@devices)
            . ", configReady=" . (PresenceSimulation_ConfigReady($hash) ? 1 : 0)
            . ", mode=" . ($data->{state}{mode} // 'off')
            . ", trainingSource=$trainingSource"
            . ($trainingSource eq 'dblog' ? ", dbLogDevice=" . AttrVal($name, 'dbLogDevice', '') : '')
            . ", model=$modelType, usableDays=$usableDays, sessions=$sessions"
    );

    return;
}

# Builds the internal device and blocking-condition configuration from attributes.
sub PresenceSimulation_BuildConfig {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my %byDevice;
    my %byReadingDevice;
    my @order;
    my @globalBlocks;
    my @errors;

    $hash->{helper}{lastObserved} = {};

    my $binMinutes = AttrVal($name, 'binMinutes', 15);
    push @errors, 'binMinutes must be one of 1, 5, 10, 15, 20, 30, or 60'
        if !PresenceSimulation_IsValidBinMinutes($binMinutes);

    for my $blockNumber (1 .. 20) {
        my $attrName = sprintf('globalBlock%02d', $blockNumber);
        my $value = AttrVal($name, $attrName, '');
        next if $value eq '';

        my ($block, $error) = PresenceSimulation_ParseBlockCondition(
            $attrName,
            $value,
            'global'
        );
        push @globalBlocks, $block if $block;
        push @errors, $error if $error;
    }

    for my $number (1 .. 30) {
        my $attrName = sprintf('device%02d', $number);
        my $value = AttrVal($name, $attrName, '');
        next if $value eq '';

        my ($cfg, $error) = PresenceSimulation_ParseDeviceConfig($attrName, $value);
        if ($error) {
            push @errors, $error;
            next;
        }

        if ($byDevice{$cfg->{device}}) {
            push @errors, "$attrName: device $cfg->{device} is configured more than once";
            next;
        }

        my @blocks;
        for my $blockNumber (1 .. 10) {
            my $blockAttr = sprintf('device%02dBlock%02d', $number, $blockNumber);
            my $blockValue = AttrVal($name, $blockAttr, '');
            next if $blockValue eq '';

            my ($block, $blockError) = PresenceSimulation_ParseBlockCondition(
                $blockAttr,
                $blockValue,
                'device'
            );
            push @blocks, $block if $block;
            push @errors, $blockError if $blockError;
        }
        $cfg->{blocks} = \@blocks;

        $byDevice{$cfg->{device}} = $cfg;
        push @{$byReadingDevice{$cfg->{readingDevice}}}, $cfg;
        push @order, $cfg->{device};
    }

    push @errors, 'At least one valid deviceNN attribute is required' if !@order;
    my $ready = @order && !@errors ? 1 : 0;
    $PresenceSimulation_DATA{$name}{config} = {
        byDevice       => \%byDevice,
        byReadingDevice => \%byReadingDevice,
        order          => \@order,
        globalBlocks   => \@globalBlocks,
        ready          => $ready,
    };

    for my $device (@order) {
        my $cfg = $byDevice{$device};
        my $val = ReadingsVal($cfg->{readingDevice}, $cfg->{reading}, undef);
        next if !defined $val;
        my $state = PresenceSimulation_ClassifyValue($cfg, $val);
        $hash->{helper}{lastObserved}{$device} = $state if defined $state;
    }

    readingsSingleUpdate($hash, 'configuredDevices', scalar @order, 1);
    return @errors;
}

# Parses and validates a device configuration.
sub PresenceSimulation_ParseDeviceConfig {
    my ($attrName, $text) = @_;
    my @parts;
    eval { @parts = shellwords($text); 1 } or return (undef, "$attrName: invalid quoting");

    my %allowed = map { $_ => 1 } qw(
        device onCommand offCommand reading readingDevice
        onRegex offRegex minDuration maxDuration
    );
    my %p;
    for my $part (@parts) {
        my ($key, $value) = split /=/, $part, 2;
        return (undef, "$attrName: expected key=value, got '$part'") if !defined $value;
        return (undef, "$attrName: unknown key '$key'") if !$allowed{$key};
        return (undef, "$attrName: duplicate key '$key'") if exists $p{$key};
        $p{$key} = $value;
    }

    return (undef, "$attrName: device is missing") if !defined $p{device} || $p{device} eq '';
    return (undef, "$attrName: onCommand must not be empty") if defined $p{onCommand} && $p{onCommand} eq '';
    return (undef, "$attrName: offCommand must not be empty") if defined $p{offCommand} && $p{offCommand} eq '';
    return (undef, "$attrName: reading must not be empty") if defined $p{reading} && $p{reading} eq '';
    return (undef, "$attrName: readingDevice must not be empty")
        if defined $p{readingDevice} && $p{readingDevice} eq '';
    return (undef, "$attrName: device $p{device} does not exist") if $init_done && !$defs{$p{device}};
    my $readingDevice = $p{readingDevice} // $p{device};
    return (undef, "$attrName: readingDevice $readingDevice does not exist")
        if $init_done && !$defs{$readingDevice};

    my $onPattern  = defined $p{onRegex}  ? $p{onRegex}  : '^on$';
    my $offPattern = defined $p{offRegex} ? $p{offRegex} : '^off$';
    my $onRe = eval { qr/$onPattern/ };
    return (undef, "$attrName: invalid onRegex: $@") if $@;
    my $offRe = eval { qr/$offPattern/ };
    return (undef, "$attrName: invalid offRegex: $@") if $@;

    return (undef, "$attrName: minDuration must be a positive integer")
        if defined $p{minDuration} && $p{minDuration} !~ /^\d+$/;
    return (undef, "$attrName: maxDuration must be a positive integer")
        if defined $p{maxDuration} && $p{maxDuration} !~ /^\d+$/;
    my $minDuration = defined $p{minDuration} ? int($p{minDuration}) : 1;
    my $maxDuration = defined $p{maxDuration} ? int($p{maxDuration}) : 240;
    return (undef, "$attrName: minDuration must be >= 1") if $minDuration < 1;
    return (undef, "$attrName: maxDuration must be >= minDuration") if $maxDuration < $minDuration;
    return (undef, "$attrName: maxDuration must be <= $PRESENCE_SIM_MAX_DURATION_MINUTES")
        if $maxDuration > $PRESENCE_SIM_MAX_DURATION_MINUTES;

    return ({
        device => $p{device},
        onCommand => $p{onCommand} // 'on', offCommand => $p{offCommand} // 'off',
        reading => $p{reading} // 'state', readingDevice => $readingDevice,
        onPattern => $onPattern, offPattern => $offPattern, onRe => $onRe, offRe => $offRe,
        minDuration => $minDuration, maxDuration => $maxDuration,
    }, undef);
}


# Parses one FHEM-style blocking condition into a safe expression tree.
sub PresenceSimulation_ParseBlockCondition {
    my ($attrName, $expression, $scope) = @_;
    my ($tokens, $tokenError) = PresenceSimulation_TokenizeCondition($expression);
    if ($tokenError) {
        my $block = {
            attrName   => $attrName,
            expression => $expression,
            scope      => $scope,
            parseError => $tokenError,
        };
        return ($block, "$attrName: $tokenError");
    }

    my $index = 0;
    my ($ast, $parseError) = PresenceSimulation_ParseConditionOr($tokens, \$index);
    if (!$parseError && $index < @{$tokens}) {
        $parseError = "unexpected token '$tokens->[$index]{text}'";
    }
    if ($parseError) {
        my $block = {
            attrName   => $attrName,
            expression => $expression,
            scope      => $scope,
            parseError => $parseError,
        };
        return ($block, "$attrName: $parseError");
    }

    return ({
        attrName   => $attrName,
        expression => $expression,
        scope      => $scope,
        ast        => $ast,
    }, undef);
}

# Converts a blocking-condition string into parser tokens without using Perl eval.
sub PresenceSimulation_TokenizeCondition {
    my ($text) = @_;
    my @tokens;
    pos($text) = 0;

    while ((pos($text) // 0) < length($text)) {
        if ($text =~ /\G\s+/gc) {
            next;
        }
        if ($text =~ /\G\[([^:\]\s]+):([^\]\s]+)\]/gc) {
            push @tokens, {
                type    => 'ref',
                device  => $1,
                reading => $2,
                text    => "[$1:$2]",
            };
            next;
        }
        if ($text =~ /\G(&&|\|\||>=|<=|==|!=|=~|!~|>|<|\beq\b|\bne\b)/gc) {
            push @tokens, { type => 'op', value => $1, text => $1 };
            next;
        }
        if ($text =~ /\G(\()/gc) {
            push @tokens, { type => 'lparen', text => $1 };
            next;
        }
        if ($text =~ /\G(\))/gc) {
            push @tokens, { type => 'rparen', text => $1 };
            next;
        }
        if ($text =~ /\G"((?:\\.|[^"\\])*)"/gc) {
            my $value = $1;
            $value =~ s/\\n/\n/g;
            $value =~ s/\\r/\r/g;
            $value =~ s/\\t/\t/g;
            $value =~ s/\\"/"/g;
            $value =~ s/\\\\/\\/g;
            push @tokens, { type => 'literal', kind => 'string', value => $value, text => qq{"$1"} };
            next;
        }
        if ($text =~ /\G'((?:\\.|[^'\\])*)'/gc) {
            my $value = $1;
            $value =~ s/\\'/'/g;
            $value =~ s/\\\\/\\/g;
            push @tokens, { type => 'literal', kind => 'string', value => $value, text => "'$1'" };
            next;
        }
        if ($text =~ /\G\/((?:\\.|[^\/\\])*)\/([imsx]*)/gc) {
            push @tokens, {
                type  => 'literal',
                kind  => 'regex',
                value => $1,
                flags => $2,
                text  => "/$1/$2",
            };
            next;
        }
        if ($text =~ /\G([-+]?(?:\d+(?:\.\d*)?|\.\d+))/gc) {
            push @tokens, { type => 'literal', kind => 'number', value => 0 + $1, text => $1 };
            next;
        }
        if ($text =~ /\G([A-Za-z_][A-Za-z0-9_.:-]*)/gc) {
            push @tokens, { type => 'literal', kind => 'string', value => $1, text => $1 };
            next;
        }

        my $position = pos($text) // 0;
        my $near = substr($text, $position, 20);
        return (undef, "invalid condition syntax near '$near'");
    }

    return (undef, 'condition is empty') if !@tokens;
    return (\@tokens, undef);
}

# Parses logical OR expressions.
sub PresenceSimulation_ParseConditionOr {
    my ($tokens, $indexRef) = @_;
    my ($node, $error) = PresenceSimulation_ParseConditionAnd($tokens, $indexRef);
    return (undef, $error) if $error;

    while ($$indexRef < @{$tokens}
        && $tokens->[$$indexRef]{type} eq 'op'
        && $tokens->[$$indexRef]{value} eq '||') {
        $$indexRef++;
        my ($right, $rightError) = PresenceSimulation_ParseConditionAnd($tokens, $indexRef);
        return (undef, $rightError) if $rightError;
        $node = { type => 'or', left => $node, right => $right };
    }
    return ($node, undef);
}

# Parses logical AND expressions.
sub PresenceSimulation_ParseConditionAnd {
    my ($tokens, $indexRef) = @_;
    my ($node, $error) = PresenceSimulation_ParseConditionComparison($tokens, $indexRef);
    return (undef, $error) if $error;

    while ($$indexRef < @{$tokens}
        && $tokens->[$$indexRef]{type} eq 'op'
        && $tokens->[$$indexRef]{value} eq '&&') {
        $$indexRef++;
        my ($right, $rightError) = PresenceSimulation_ParseConditionComparison($tokens, $indexRef);
        return (undef, $rightError) if $rightError;
        $node = { type => 'and', left => $node, right => $right };
    }
    return ($node, undef);
}

# Parses one comparison or a truth-value expression.
sub PresenceSimulation_ParseConditionComparison {
    my ($tokens, $indexRef) = @_;
    my ($left, $error) = PresenceSimulation_ParseConditionPrimary($tokens, $indexRef);
    return (undef, $error) if $error;

    if ($$indexRef < @{$tokens}
        && $tokens->[$$indexRef]{type} eq 'op'
        && $tokens->[$$indexRef]{value} !~ /^(?:&&|\|\|)$/) {
        my $operator = $tokens->[$$indexRef]{value};
        $$indexRef++;
        my ($right, $rightError) = PresenceSimulation_ParseConditionPrimary($tokens, $indexRef);
        return (undef, $rightError) if $rightError;
        return ({ type => 'compare', op => $operator, left => $left, right => $right }, undef);
    }

    return ({ type => 'truthy', value => $left }, undef);
}

# Parses references, literals, and parenthesized subexpressions.
sub PresenceSimulation_ParseConditionPrimary {
    my ($tokens, $indexRef) = @_;
    return (undef, 'unexpected end of condition') if $$indexRef >= @{$tokens};

    my $token = $tokens->[$$indexRef];
    if ($token->{type} eq 'lparen') {
        $$indexRef++;
        my ($node, $error) = PresenceSimulation_ParseConditionOr($tokens, $indexRef);
        return (undef, $error) if $error;
        return (undef, "missing ')'")
            if $$indexRef >= @{$tokens} || $tokens->[$$indexRef]{type} ne 'rparen';
        $$indexRef++;
        return ($node, undef);
    }

    if ($token->{type} eq 'ref') {
        $$indexRef++;
        return ({
            type    => 'ref',
            device  => $token->{device},
            reading => $token->{reading},
        }, undef);
    }

    if ($token->{type} eq 'literal') {
        $$indexRef++;
        return ({
            type  => 'literal',
            kind  => $token->{kind},
            value => $token->{value},
            flags => $token->{flags},
        }, undef);
    }

    return (undef, "unexpected token '$token->{text}'");
}

# Evaluates one parsed condition tree against current FHEM readings.
sub PresenceSimulation_EvaluateConditionNode {
    my ($node) = @_;
    return { ok => 0, error => 'missing expression node', reads => [] }
        if ref $node ne 'HASH';

    if ($node->{type} eq 'literal') {
        return {
            ok    => 1,
            value => $node->{value},
            kind  => $node->{kind},
            flags => $node->{flags},
            reads => [],
        };
    }

    if ($node->{type} eq 'ref') {
        my $device  = $node->{device};
        my $reading = $node->{reading};
        my $value = ReadingsVal($device, $reading, undef);
        my $read = {
            device  => $device,
            reading => $reading,
            value   => $value,
        };
        return {
            ok    => 0,
            error => "reading unavailable: $device:$reading",
            reads => [$read],
        } if !defined $value;
        return {
            ok    => 1,
            value => $value,
            kind  => looks_like_number($value) ? 'number' : 'string',
            reads => [$read],
        };
    }

    if ($node->{type} eq 'truthy') {
        my $result = PresenceSimulation_EvaluateConditionNode($node->{value});
        return $result if !$result->{ok};
        $result->{value} = $result->{value} ? 1 : 0;
        $result->{kind} = 'bool';
        return $result;
    }

    if ($node->{type} eq 'and' || $node->{type} eq 'or') {
        my $left = PresenceSimulation_EvaluateConditionNode($node->{left});
        return $left if !$left->{ok};

        if ($node->{type} eq 'and' && !$left->{value}) {
            return { ok => 1, value => 0, kind => 'bool', reads => $left->{reads} // [] };
        }
        if ($node->{type} eq 'or' && $left->{value}) {
            return { ok => 1, value => 1, kind => 'bool', reads => $left->{reads} // [] };
        }

        my $right = PresenceSimulation_EvaluateConditionNode($node->{right});
        return $right if !$right->{ok};
        return {
            ok    => 1,
            value => $node->{type} eq 'and'
                ? ($left->{value} && $right->{value} ? 1 : 0)
                : ($left->{value} || $right->{value} ? 1 : 0),
            kind  => 'bool',
            reads => [@{$left->{reads} // []}, @{$right->{reads} // []}],
        };
    }

    if ($node->{type} eq 'compare') {
        my $left = PresenceSimulation_EvaluateConditionNode($node->{left});
        return $left if !$left->{ok};
        my $right = PresenceSimulation_EvaluateConditionNode($node->{right});
        return $right if !$right->{ok};

        my $op = $node->{op};
        my ($matched, $error);
        if ($op =~ /^(?:>|>=|<|<=|==|!=)$/) {
            if (!looks_like_number($left->{value}) || !looks_like_number($right->{value})) {
                $error = "numeric operator $op requires numeric values";
            }
            elsif ($op eq '>')  { $matched = $left->{value} >  $right->{value}; }
            elsif ($op eq '>=') { $matched = $left->{value} >= $right->{value}; }
            elsif ($op eq '<')  { $matched = $left->{value} <  $right->{value}; }
            elsif ($op eq '<=') { $matched = $left->{value} <= $right->{value}; }
            elsif ($op eq '==') { $matched = $left->{value} == $right->{value}; }
            elsif ($op eq '!=') { $matched = $left->{value} != $right->{value}; }
        }
        elsif ($op eq 'eq') { $matched = "$left->{value}" eq "$right->{value}"; }
        elsif ($op eq 'ne') { $matched = "$left->{value}" ne "$right->{value}"; }
        elsif ($op eq '=~' || $op eq '!~') {
            my $pattern = $right->{value};
            my $flags = $right->{kind} eq 'regex' ? ($right->{flags} // '') : '';
            my $wrapped = $flags ne '' ? "(?$flags:$pattern)" : $pattern;
            my $regex = eval { qr/$wrapped/ };
            if ($@) {
                $error = "invalid regular expression: $@";
                $error = PresenceSimulation_OneLineError($error);
            }
            else {
                my $regexMatch = "$left->{value}" =~ $regex ? 1 : 0;
                $matched = $op eq '=~' ? $regexMatch : !$regexMatch;
            }
        }
        else {
            $error = "unsupported operator $op";
        }

        return {
            ok    => 0,
            error => $error,
            reads => [@{$left->{reads} // []}, @{$right->{reads} // []}],
        } if $error;

        return {
            ok    => 1,
            value => $matched ? 1 : 0,
            kind  => 'bool',
            reads => [@{$left->{reads} // []}, @{$right->{reads} // []}],
        };
    }

    return { ok => 0, error => "unknown expression node $node->{type}", reads => [] };
}

# Returns the first active global or device-specific block, using OR semantics.
sub PresenceSimulation_FindActiveBlock {
    my ($hash, $cfg) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};

    my @groups = (
        PresenceSimulation_AsArray($data->{config}{globalBlocks}),
        PresenceSimulation_AsArray($cfg->{blocks}),
    );

    for my $blocks (@groups) {
        for my $block (@{$blocks}) {
            my $result;
            if ($block->{parseError}) {
                $result = {
                    ok    => 0,
                    error => $block->{parseError},
                    reads => [],
                };
            }
            else {
                $result = PresenceSimulation_EvaluateConditionNode($block->{ast});
            }

            if (!$result->{ok} || $result->{value}) {
                my @actual = map {
                    my $value = defined $_->{value} ? $_->{value} : '<unavailable>';
                    "$_->{device}:$_->{reading}=$value"
                } @{$result->{reads} // []};

                return {
                    condition   => $block->{attrName},
                    expression  => $block->{expression},
                    reason      => $result->{ok} ? 'matched' : 'evaluationError',
                    errorDetail => $result->{ok} ? '' : ($result->{error} // 'unknown evaluation error'),
                    actual      => join(',', @actual),
                    error       => $result->{ok} ? 0 : 1,
                };
            }
        }
    }

    return undef;
}

# Maps a reading value to the on or off state.
sub PresenceSimulation_ClassifyValue {
    my ($cfg, $value) = @_;
    return 'on'  if $value =~ $cfg->{onRe};
    return 'off' if $value =~ $cfg->{offRe};
    return undef;
}

# Records real on/off transitions as training sessions.
sub PresenceSimulation_ProcessTrainingTransition {
    my ($hash, $cfg, $state) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    my $dev  = $cfg->{device};
    my $now  = CORE::time();

    if ($state eq 'on') {
        if ($data->{state}{activeSessions}{$dev}) {
            PresenceSimulation_Log($hash, 5, "training start ignored for $dev: session already active");
            return;
        }

        $data->{state}{activeSessions}{$dev} = {
            startedAt   => $now,
            date        => PresenceSimulation_Date($now),
            weekday     => PresenceSimulation_WeekdayIndex($now),
            startMinute => PresenceSimulation_MinuteOfDay($now),
        };
        PresenceSimulation_Log(
            $hash, 4,
            sprintf('training session started: %s at %s', $dev, PresenceSimulation_FormatDateTime($now))
        );
        PresenceSimulation_MarkDirty($hash, 'state');
        PresenceSimulation_UpdateReadings($hash);
        return;
    }

    my $session = delete $data->{state}{activeSessions}{$dev};
    if (!$session) {
        PresenceSimulation_Log($hash, 5, "training stop ignored for $dev: no active session");
        return;
    }

    my $date = $session->{date};
    my $duration = int(($now - $session->{startedAt} + 30) / 60);
    if ($duration < $cfg->{minDuration} || $duration > $cfg->{maxDuration}) {
        my $day = ($data->{raw}{days}{$date} //= PresenceSimulation_EmptyRawDay($date));
        $day->{discardedSessions} = int($day->{discardedSessions} // 0) + 1;
        $data->{state}{discardedSessions} = int($data->{state}{discardedSessions} // 0) + 1;
        PresenceSimulation_Log(
            $hash,
            4,
            "training session discarded: $dev, duration=${duration}min, "
                . "allowed=$cfg->{minDuration}..$cfg->{maxDuration}min"
        );
        PresenceSimulation_MarkDirty($hash, qw(raw state));
        PresenceSimulation_UpdateReadings($hash);
        return;
    }
    my $day = ($data->{raw}{days}{$date} //= PresenceSimulation_EmptyRawDay($date));

    push @{$day->{sessions}{$dev}}, {
        startMinute     => $session->{startMinute},
        durationMinutes => $duration,
        weekday         => $session->{weekday} // PresenceSimulation_WeekdayForDate($date),
        startedAt       => $session->{startedAt},
        endedAt         => $now,
    };

    PresenceSimulation_Log(
        $hash, 4,
        sprintf(
            'training session stored: %s, start=%02d:%02d, duration=%dmin',
            $dev,
            int($session->{startMinute} / 60),
            $session->{startMinute} % 60,
            $duration
        )
    );
    PresenceSimulation_MarkDirty($hash, qw(raw state));
    PresenceSimulation_UpdateReadings($hash);
    return;
}

# Handles command feedback and manual interventions during playback.
sub PresenceSimulation_ProcessPlaybackTransition {
    my ($hash, $cfg, $state) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    my $dev  = $cfg->{device};
    my $now  = CORE::time();

    my $expected = $data->{state}{expected}{$dev};
    if ($expected && $expected->{until} >= $now && $expected->{state} eq $state) {
        delete $data->{state}{expected}{$dev};
        delete $data->{state}{managed}{$dev} if $state eq 'off';
        PresenceSimulation_ClearPlaybackErrorAfterConfirmedOff($hash) if $state eq 'off';
        PresenceSimulation_Log($hash, 4, "playback feedback received: $dev -> $state");
        PresenceSimulation_MarkDirty($hash, 'state');
        PresenceSimulation_UpdateReadings($hash);
        return;
    }

    delete $data->{state}{expected}{$dev};

    if ($state eq 'off') {
        my $wasManaged = delete $data->{state}{managed}{$dev};
        PresenceSimulation_ClearPlaybackErrorAfterConfirmedOff($hash) if $wasManaged;
        my $lockMinutes = AttrVal($name, 'manualLockMinutes', 120);
        $data->{state}{manualLockUntil}{$dev} = $now + ($lockMinutes * 60) if $lockMinutes > 0;
        PresenceSimulation_Log(
            $hash, $wasManaged ? 3 : 4,
            "manual OFF detected: $dev, playback lock=${lockMinutes}min"
        );
        PresenceSimulation_MarkDirty($hash, 'state');
        PresenceSimulation_UpdateReadings($hash);
    }
    elsif ($state eq 'on') {
        if ($data->{state}{managed}{$dev}) {
            PresenceSimulation_Log($hash, 3, "unexpected ON feedback during playback: $dev remains managed");
        }
        else {
            PresenceSimulation_Log($hash, 3, "manual ON detected during playback: $dev is not managed");
        }
    }

    return;
}

# Reports an exhausted OFF cycle and ends module ownership without treating the
# physical device state as off. Future playback still requires an unambiguous
# observed OFF state before another ON command may be sent.
sub PresenceSimulation_ReleaseManagedOffFailure {
    my ($hash, $dev, $entry) = @_;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});
    my $attempts = int(PresenceSimulation_AsHash($entry)->{offAttempts} // 0);
    $attempts = $PRESENCE_SIM_OFF_MAX_ATTEMPTS if $attempts < 1;
    my $message = "$dev did not confirm off after $attempts attempts";

    delete $data->{state}{managed}{$dev};
    delete $data->{state}{expected}{$dev};
    PresenceSimulation_SetError($hash, $message, 'playback');
    PresenceSimulation_Log(
        $hash, 2,
        $message
            . '; released from playback management; '
            . 'no further automatic OFF commands will be sent'
    );
    PresenceSimulation_MarkDirty($hash, 'state');
    return 'failed';
}

# Clears transient playback errors after a confirmed OFF, but preserves the
# final diagnostic from an exhausted OFF cycle until a later successful ON or
# another subsystem error supersedes it.
sub PresenceSimulation_ClearPlaybackErrorAfterConfirmedOff {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return if ReadingsVal($name, 'lastErrorSource', '') ne 'playback';
    return if ReadingsVal($name, 'lastError', '')
        =~ / did not confirm off after \d+ attempts$/;
    PresenceSimulation_ClearError($hash, 'playback');
    return;
}

# Executes one bounded OFF attempt or confirms an already completed OFF.
sub PresenceSimulation_ProcessManagedOffEntry {
    my ($hash, $dev, $entry, $cfg, $now) = @_;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});
    return 'missing' if ref $entry ne 'HASH';
    return PresenceSimulation_ReleaseManagedOffFailure($hash, $dev, $entry)
        if $entry->{offFailed};
    return 'missing' if ref $cfg ne 'HASH';

    $entry->{stopping} = 1;

    my $value = PresenceSimulation_ObservedReadingValue($cfg);
    my $actual = defined $value ? PresenceSimulation_ClassifyValue($cfg, $value) : undef;
    if (defined $actual && $actual eq 'off') {
        delete $data->{state}{managed}{$dev};
        delete $data->{state}{expected}{$dev};
        PresenceSimulation_ClearPlaybackErrorAfterConfirmedOff($hash);
        PresenceSimulation_Log($hash, 3, "playback stop confirmed: $dev is off");
        PresenceSimulation_MarkDirty($hash, 'state');
        return 'confirmed';
    }

    return 'waiting' if ($entry->{offRetryDue} // 0) > $now;

    my $attempts = int($entry->{offAttempts} // 0);
    if ($attempts >= $PRESENCE_SIM_OFF_MAX_ATTEMPTS) {
        return PresenceSimulation_ReleaseManagedOffFailure($hash, $dev, $entry);
    }

    $attempts++;
    $entry->{offAttempts} = $attempts;
    my $delay = $PRESENCE_SIM_OFF_RETRY_DELAYS[$attempts - 1] // 60;
    $entry->{offRetryDue} = $now + $delay;
    $data->{state}{expected}{$dev} = { state => 'off', until => $now + 20 };

    my $error = CommandSet(undef, "$dev $cfg->{offCommand}");
    if ($error) {
        delete $data->{state}{expected}{$dev};
        $entry->{offLastError} = "$dev off attempt $attempts failed: $error";
        PresenceSimulation_SetError($hash, $entry->{offLastError}, 'playback');
        PresenceSimulation_Log(
            $hash, 2,
            "playback OFF attempt $attempts/$PRESENCE_SIM_OFF_MAX_ATTEMPTS failed for $dev: $error"
        );
    }
    else {
        $entry->{offLastError} = '';
        if (!$entry->{offEventEmitted}) {
            $entry->{offEventEmitted} = 1;
            PresenceSimulation_EmitSimulationEvent(
                $hash,
                'playback',
                $dev,
                'off',
                {
                    durationMinutes => $entry->{durationMinutes},
                    modelType       => $entry->{modelType},
                }
            );
        }
        PresenceSimulation_Log(
            $hash, 3,
            "playback OFF attempt $attempts/$PRESENCE_SIM_OFF_MAX_ATTEMPTS sent: $dev"
        );
    }

    PresenceSimulation_MarkDirty($hash, 'state');
    return $error ? 'command-error' : 'sent';
}

# Runs the module's main one-minute cycle.

# Confirms or retries OFF commands for playback sessions being stopped.
sub PresenceSimulation_ProcessPendingPlaybackStops {
    my ($hash, $now) = @_;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});
    my $managed = PresenceSimulation_AsHash($data->{state}{managed});

    for my $dev (sort keys %{$managed}) {
        my $entry = PresenceSimulation_AsHash($managed->{$dev});
        next if !$entry->{stopping};
        if ($entry->{offFailed}) {
            PresenceSimulation_ReleaseManagedOffFailure($hash, $dev, $entry);
            next;
        }
        my $cfg = PresenceSimulation_ConfigForManagedEntry($data, $dev, $entry);
        if (!$cfg) {
            PresenceSimulation_SetError(
                $hash,
                "Cannot stop managed device $dev: missing device configuration snapshot",
                'playback'
            );
            next;
        }

        PresenceSimulation_ProcessManagedOffEntry($hash, $dev, $entry, $cfg, $now);
    }
    return;
}

sub PresenceSimulation_Tick {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    return if !$defs{$name};

    PresenceSimulation_ScheduleTick($hash);
    my $data = $PresenceSimulation_DATA{$name};
    return if !$data;
    my $now  = CORE::time();
    PresenceSimulation_ProcessPendingPlaybackStops($hash, $now);
    if (PresenceSimulation_IsDisabled($name)) {
        $hash->{helper}{wasDisabled} = 1;
        PresenceSimulation_StopPlayback($hash, 1)
            if PresenceSimulation_HasManagedPlaybackDevices($hash);
        $data->{state}{lastCoverageTick} = $now;
        PresenceSimulation_UpdateReadings($hash);
        return;
    }
    if (delete $hash->{helper}{wasDisabled}) {
        PresenceSimulation_ScheduleAutoImport($hash)
            if PresenceSimulation_TrainingSource($name) eq 'dblog';
    }

    my $date = PresenceSimulation_Date($now);
    my $lastDate = $data->{state}{currentDate} // $date;

    if ($lastDate ne $date) {
        PresenceSimulation_Log($hash, 3, "day changed from $lastDate to $date, pruning data and rebuilding model");
        $data->{state}{currentDate} = $date;
        $data->{state}{lastCoverageTick} = $now;
        $data->{state}{coverageDate} = $date;
        $data->{state}{coverageSeconds} = 0;
        PresenceSimulation_PruneRaw($hash);
        PresenceSimulation_PrunePlaybackState($hash, $date);
        PresenceSimulation_RebuildModel($hash);
        PresenceSimulation_MarkDirty($hash, qw(raw state));
    }

    PresenceSimulation_CleanupRuntime($hash, $now);

    my $mode = $data->{state}{mode} // 'off';
    my $trainingSource = PresenceSimulation_TrainingSource($name);
    if ($mode eq 'training') {
        if ($trainingSource eq 'events' && PresenceSimulation_ConfigReady($hash)) {
            PresenceSimulation_UpdateCoverage($hash, $now, $date);
        }
        else {
            $data->{state}{lastCoverageTick} = $now;
        }
    }
    elsif ($mode eq 'playback') {
        $data->{state}{lastCoverageTick} = $now;
        PresenceSimulation_RunPlayback($hash, $now, $date);
    }
    elsif ($mode eq 'dryrun') {
        if ($trainingSource eq 'events' && PresenceSimulation_ConfigReady($hash)) {
            PresenceSimulation_UpdateCoverage($hash, $now, $date);
        }
        else {
            $data->{state}{lastCoverageTick} = $now;
        }
        PresenceSimulation_RunDryRun($hash, $now, $date);
    }
    else {
        $data->{state}{lastCoverageTick} = $now;
    }

    PresenceSimulation_UpdateReadings($hash);
    return;
}

# Schedules the next main cycle for the following minute.
sub PresenceSimulation_ScheduleTick {
    my ($hash) = @_;
    return if !$init_done || $hash->{helper}{teardown};
    RemoveInternalTimer($hash, 'PresenceSimulation_Tick');
    my $next = int(CORE::time() / 60) * 60 + 60.05;
    InternalTimer($next, 'PresenceSimulation_Tick', $hash, 0);
    return;
}

# Increments the recorded training time for the current day.
sub PresenceSimulation_UpdateCoverage {
    my ($hash, $now, $date) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};

    my $last = $data->{state}{lastCoverageTick} // ($now - 60);
    my $delta = $now - $last;
    $delta = 0 if $delta < 0;
    $delta = 90 if $delta > 90;

    my $day = ($data->{raw}{days}{$date} //= PresenceSimulation_EmptyRawDay($date));
    $day->{trainingSeconds} += int($delta);
    $day->{trainingSeconds} = 86400 if $day->{trainingSeconds} > 86400;
    $data->{state}{lastCoverageTick} = $now;
    $data->{state}{coverageDate} = $date;
    $data->{state}{coverageSeconds} = int($day->{trainingSeconds});

    # State is small and is persisted regularly. The much larger raw file is
    # only marked dirty hourly or when a session is completed.
    PresenceSimulation_MarkDirty($hash, 'state');
    my $lastRawCoverageSave = int($hash->{helper}{lastRawCoverageSave} // 0);
    if (($now - $lastRawCoverageSave) >= 3600) {
        $hash->{helper}{lastRawCoverageSave} = $now;
        PresenceSimulation_MarkDirty($hash, 'raw');
    }
    return;
}


# Runs real playback and sends commands to the configured devices.
sub PresenceSimulation_RunPlayback {
    my ($hash, $now, $date) = @_;
    return PresenceSimulation_RunSimulation($hash, $now, $date, 0);
}

# Runs virtual playback and emits readings instead of device commands.
sub PresenceSimulation_RunDryRun {
    my ($hash, $now, $date) = @_;
    return PresenceSimulation_RunSimulation($hash, $now, $date, 1);
}

# Returns one uniformly distributed value in the half-open interval [0, 1).
# The wrapper keeps probability decisions deterministic in self-tests without
# changing Perl's global random-number generator.
sub PresenceSimulation_Random {
    return rand();
}

# Converts one random value into a valid array index.
sub PresenceSimulation_RandomIndex {
    my ($count) = @_;
    return 0 if !defined $count || $count <= 1;

    my $draw = PresenceSimulation_Random();
    $draw = 0 if !defined $draw || !looks_like_number($draw) || $draw < 0;
    $draw = 0.999999999999 if $draw >= 1;
    return int($draw * $count);
}

# Formats an absolute minute of day as HH:MM.
sub PresenceSimulation_FormatMinuteOfDay {
    my ($minute) = @_;
    $minute = int($minute // 0);
    $minute = 0 if $minute < 0;
    $minute = 1439 if $minute > 1439;
    return sprintf('%02d:%02d', int($minute / 60), $minute % 60);
}

# Formats a time-block boundary. Unlike a start minute, the end of the final
# block may be represented as 24:00.
sub PresenceSimulation_FormatBlockBoundary {
    my ($minute) = @_;
    $minute = int($minute // 0);
    $minute = 0 if $minute < 0;
    $minute = 1440 if $minute > 1440;
    return '24:00' if $minute == 1440;
    return PresenceSimulation_FormatMinuteOfDay($minute);
}

# Removes pending plans from previous dates or already completed time bins.
sub PresenceSimulation_CleanupPlannedBins {
    my ($hash, $date, $currentBin, $plansKey) = @_;
    my $name = $hash->{NAME};
    my $state = $PresenceSimulation_DATA{$name}{state};
    my $plans = PresenceSimulation_AsHash($state->{$plansKey});
    my $changed = 0;

    for my $storedDate (keys %{$plans}) {
        if ($storedDate ne $date) {
            delete $plans->{$storedDate};
            $changed = 1;
        }
    }

    my $byDevice = PresenceSimulation_AsHash($plans->{$date});
    for my $dev (keys %{$byDevice}) {
        my $bins = PresenceSimulation_AsHash($byDevice->{$dev});
        for my $bin (keys %{$bins}) {
            if (PresenceSimulation_IsIntegerInRange($bin, 0, undef) && $bin < $currentBin) {
                delete $bins->{$bin};
                $changed = 1;
            }
        }
        delete $byDevice->{$dev} if !keys %{$bins};
    }
    delete $plans->{$date} if !keys %{$byDevice};

    PresenceSimulation_MarkDirty($hash, 'state') if $changed;
    return;
}

# Makes the single block decision and, on a hit, creates one persisted start plan.
sub PresenceSimulation_CreateBinPlan {
    my (
        $hash, $dev, $bin, $binMinutes, $minute,
        $binModel, $deviceModel, $cfg, $factor, $modelType, $historyDays,
    ) = @_;

    my $historicalProbability = $binModel->{probability} // 0;
    my $effectiveProbability = $historicalProbability * $factor;
    $effectiveProbability = 1 if $effectiveProbability > 1;
    $effectiveProbability = 0 if $effectiveProbability < 0;

    return (undef, 'zero') if $effectiveProbability <= 0;

    my $decisionDraw = PresenceSimulation_Random();
    PresenceSimulation_Log(
        $hash, 5,
        sprintf(
            'block decision: %s, bin=%d, historical=%.5f, factor=%.5f, effective=%.5f, draw=%.5f',
            $dev, $bin, $historicalProbability, $factor, $effectiveProbability, $decisionDraw
        )
    );
    return (undef, 'miss') if $decisionDraw >= $effectiveProbability;

    my @durations = @{$binModel->{durations} // []};
    if (!@durations) {
        @durations = @{$deviceModel->{allDurations} // []};
    }
    return (undef, 'no-duration') if !@durations;

    my $duration = $durations[PresenceSimulation_RandomIndex(scalar @durations)];
    $duration = int($duration);
    $duration = $cfg->{minDuration} if $duration < $cfg->{minDuration};
    $duration = $cfg->{maxDuration} if $duration > $cfg->{maxDuration};

    my $blockStart = $bin * $binMinutes;
    my $currentOffset = $minute - $blockStart;
    $currentOffset = 0 if $currentOffset < 0;
    $currentOffset = $binMinutes - 1 if $currentOffset >= $binMinutes;

    my @historicalOffsets = grep {
        PresenceSimulation_IsIntegerInRange($_, 0, $binMinutes - 1)
    } @{$binModel->{startOffsets} // []};
    my @eligibleOffsets = grep { $_ >= $currentOffset } @historicalOffsets;

    my $selectedOffset;
    if (@eligibleOffsets) {
        $selectedOffset = $eligibleOffsets[
            PresenceSimulation_RandomIndex(scalar @eligibleOffsets)
        ];
    }
    else {
        my $remaining = $binMinutes - $currentOffset;
        $remaining = 1 if $remaining < 1;
        $selectedOffset = $currentOffset + PresenceSimulation_RandomIndex($remaining);
    }

    return ({
        plannedStartMinute   => $blockStart + $selectedOffset,
        durationMinutes      => $duration,
        probabilityHistorical => 0 + $historicalProbability,
        probabilityEffective  => 0 + $effectiveProbability,
        probabilityFactor     => 0 + $factor,
        historyStarts        => int($binModel->{daysWithStart} // 0),
        historyDays          => int($historyDays // 0),
        historyPositionSamples => scalar(@historicalOffsets),
        modelType            => $modelType,
        createdAt            => CORE::time(),
    }, 'hit');
}

# Formats the shared ON diagnostic for dry-run and real playback.
sub PresenceSimulation_FormatSimulationOnLog {
    my ($modeLabel, $dev, $plan) = @_;
    return sprintf(
        '%s ON: %s, planned=%s, duration=%dmin, '
            . 'historical=%.2f%%, factor=%.3f, effective=%.2f%%, model=%s',
        $modeLabel,
        $dev,
        PresenceSimulation_FormatMinuteOfDay($plan->{plannedStartMinute}),
        $plan->{durationMinutes},
        $plan->{probabilityHistorical} * 100,
        $plan->{probabilityFactor},
        $plan->{probabilityEffective} * 100,
        $plan->{modelType},
    );
}

# Draws at most one switching event per model block. The block probability is
# evaluated once; a hit is then assigned a start minute sampled from historical
# positions inside the block. Pending plans are persisted in runtime state.
sub PresenceSimulation_RunSimulation {
    my ($hash, $now, $date, $dryRun) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    my $binMinutes = $data->{model}{binMinutes} || AttrVal($name, 'binMinutes', 15);
    if (!PresenceSimulation_IsValidBinMinutes($binMinutes)) {
        PresenceSimulation_SetError(
            $hash,
            'Simulation cannot run: binMinutes must be one of 1, 5, 10, 15, 20, 30, or 60',
            'configuration'
        );
        return;
    }
    my $minute = PresenceSimulation_MinuteOfDay($now);
    my $bin = int($minute / $binMinutes);
    my $factor = AttrVal($name, 'probabilityFactor', 1.0);
    my $weekday = PresenceSimulation_WeekdayIndex($now);
    my $weekdaySpecific = AttrVal($name, 'weekdaySpecific', 0);
    my $playbackModel = $weekdaySpecific
        ? $data->{model}{weekdays}{$weekday}
        : $data->{model}{allDays};
    my $managedKey    = $dryRun ? 'dryManaged' : 'managed';
    my $playedBinsKey = $dryRun ? 'dryPlayedBins' : 'playedBins';
    my $plannedBinsKey = $dryRun ? 'dryPlannedBins' : 'plannedBins';
    my $modeLabel     = $dryRun ? 'dry run' : 'playback';
    my $modeValue     = $dryRun ? 'dryrun' : 'playback';
    my $blockEvaluationFailed = 0;

    # Simulation remains inactive without training data for the selected model.
    return if !$playbackModel || !@{$playbackModel->{validDates} // []};

    PresenceSimulation_CleanupPlannedBins($hash, $date, $bin, $plannedBinsKey);

    for my $dev (@{$data->{config}{order}}) {
        my $cfg = $data->{config}{byDevice}{$dev};
        next if !$cfg;

        my $managed = $data->{state}{$managedKey}{$dev};
        if ($managed) {
            if ($dryRun) {
                if ($now >= ($managed->{offDue} // 0)) {
                    delete $data->{state}{dryManaged}{$dev};
                    PresenceSimulation_EmitSimulationEvent(
                        $hash,
                        'dryrun',
                        $dev,
                        'off',
                        {
                            durationMinutes => $managed->{durationMinutes},
                            modelType       => $managed->{modelType},
                        }
                    );
                    PresenceSimulation_Log($hash, 3, "dry run OFF: $dev");
                    PresenceSimulation_MarkDirty($hash, 'state');
                }
                next;
            }

            my $value = PresenceSimulation_ObservedReadingValue($cfg);
            my $actual = defined $value ? PresenceSimulation_ClassifyValue($cfg, $value) : undef;
            if (defined $actual && $actual eq 'off') {
                delete $data->{state}{managed}{$dev};
                delete $data->{state}{expected}{$dev};
                PresenceSimulation_ClearPlaybackErrorAfterConfirmedOff($hash);
                PresenceSimulation_Log($hash, 3, "managed device already off: $dev removed from playback state");
                PresenceSimulation_MarkDirty($hash, 'state');
                next;
            }

            if ($now >= $managed->{offDue}) {
                PresenceSimulation_ProcessManagedOffEntry(
                    $hash, $dev, $managed, $cfg, $now
                );
            }
            elsif (!defined $actual) {
                PresenceSimulation_Log($hash, 5, "playback state unreadable for managed device $dev");
            }
            next;
        }

        my $plan = $data->{state}{$plannedBinsKey}{$date}{$dev}{$bin};
        if ($data->{state}{$playedBinsKey}{$date}{$dev}{$bin}) {
            if ($plan) {
                delete $data->{state}{$plannedBinsKey}{$date}{$dev}{$bin};
                PresenceSimulation_MarkDirty($hash, 'state');
            }
            PresenceSimulation_Log($hash, 5, "$modeLabel skipped for $dev: time bin $bin was already played today");
            next;
        }

        if (!$plan) {
            my $deviceModel = $playbackModel->{devices}{$dev};
            if (!$deviceModel) {
                PresenceSimulation_Log($hash, 5, "$modeLabel skipped for $dev: no device model");
                next;
            }
            my $binModel = $deviceModel->{bins}{$bin};
            if (!$binModel) {
                PresenceSimulation_Log($hash, 5, "$modeLabel skipped for $dev: no historical starts in time bin $bin");
                next;
            }

            my $status;
            ($plan, $status) = PresenceSimulation_CreateBinPlan(
                $hash, $dev, $bin, $binMinutes, $minute,
                $binModel, $deviceModel, $cfg, $factor,
                ($weekdaySpecific ? 'weekday-specific' : 'all-days'),
                scalar(@{$playbackModel->{validDates} // []}),
            );

            if (!$plan) {
                $data->{state}{$playedBinsKey}{$date}{$dev}{$bin} = 1;
                PresenceSimulation_MarkDirty($hash, 'state');
                my $message = $status eq 'miss'
                    ? 'single block decision produced no event'
                    : $status eq 'zero'
                        ? 'effective block probability is zero'
                        : 'no historical duration available';
                PresenceSimulation_Log($hash, 5, "$modeLabel skipped for $dev: $message");
                next;
            }

            $data->{state}{$plannedBinsKey}{$date}{$dev}{$bin} = $plan;
            PresenceSimulation_MarkDirty($hash, 'state');
            PresenceSimulation_Log(
                $hash, 4,
                sprintf(
                    '%s planned: %s, bin=%d, start=%s, duration=%dmin, '
                        . 'historical=%.2f%%, factor=%.3f, effective=%.2f%%, model=%s',
                    $modeLabel, $dev, $bin,
                    PresenceSimulation_FormatMinuteOfDay($plan->{plannedStartMinute}),
                    $plan->{durationMinutes},
                    $plan->{probabilityHistorical} * 100,
                    $plan->{probabilityFactor},
                    $plan->{probabilityEffective} * 100,
                    $plan->{modelType},
                )
            );
        }

        next if $minute < $plan->{plannedStartMinute};

        # Real device state and manual locks are safety constraints for playback only.
        # A pending block plan is retained until the end of its block and can run
        # later if the real device becomes safely available.
        if (!$dryRun) {
            my $value = PresenceSimulation_ObservedReadingValue($cfg);
            my $actual = defined $value ? PresenceSimulation_ClassifyValue($cfg, $value) : undef;
            if (!defined $actual) {
                PresenceSimulation_Log($hash, 5, "playback plan waiting for $dev: unreadable state");
                next;
            }
            if ($actual ne 'off') {
                PresenceSimulation_Log($hash, 5, "playback plan waiting for $dev: device is already on");
                next;
            }
            if (($data->{state}{manualLockUntil}{$dev} // 0) > $now) {
                PresenceSimulation_Log($hash, 5, "playback plan waiting for $dev: manual lock is active");
                next;
            }
        }

        my $originalDuration = $plan->{durationMinutes};

        # Once a planned hit is due, blocking conditions are checked on every
        # simulation tick until the current block ends. The first blocked check
        # emits exactly one pending notification; the plan remains persisted and
        # may still start later in the same block without another probability draw.
        my $activeBlock = PresenceSimulation_FindActiveBlock($hash, $cfg);
        if ($activeBlock) {
            my $firstBlockedCheck = !$plan->{blockNotified};
            if ($firstBlockedCheck) {
                $plan->{blockNotified} = 1;
                PresenceSimulation_MarkDirty($hash, 'state');
                PresenceSimulation_EmitSimulationEvent(
                    $hash,
                    $modeValue,
                    $dev,
                    'blocked',
                    {
                        durationMinutes        => $originalDuration,
                        probabilityHistorical => $plan->{probabilityHistorical},
                        probabilityBlock      => $plan->{probabilityEffective},
                        probabilityFactor     => $plan->{probabilityFactor},
                        plannedStartMinute    => $plan->{plannedStartMinute},
                        historyStarts         => $plan->{historyStarts},
                        historyDays           => $plan->{historyDays},
                        historyPositionSamples => $plan->{historyPositionSamples},
                        pending               => 1,
                        retryUntil            => PresenceSimulation_FormatBlockBoundary(
                            ($bin + 1) * $binMinutes
                        ),
                        modelType              => $plan->{modelType},
                        blockCondition         => $activeBlock->{condition},
                        ($activeBlock->{error}
                            ? (blockReason => 'evaluationError')
                            : ()),
                    }
                );
            }

            my $level = $activeBlock->{error} ? 2 : ($firstBlockedCheck ? 3 : 5);
            my $logDetails = sprintf(
                '%s blocked%s: %s, condition=%s, reason=%s, expression=%s%s',
                $modeLabel,
                $firstBlockedCheck ? ' and pending' : ' plan still pending',
                $dev,
                $activeBlock->{condition},
                $activeBlock->{reason},
                $activeBlock->{expression},
                $activeBlock->{actual} ne '' ? ", actual=$activeBlock->{actual}" : ''
            );
            $logDetails .= ", error=$activeBlock->{errorDetail}" if $activeBlock->{error};
            PresenceSimulation_Log($hash, $level, $logDetails);
            if ($activeBlock->{error}) {
                $blockEvaluationFailed = 1;
                PresenceSimulation_SetError(
                    $hash,
                    "block condition $activeBlock->{condition} could not be evaluated: "
                        . $activeBlock->{errorDetail},
                    'blockCondition'
                );
            }
            next;
        }

        my $delayedMinutes = 0;
        my $duration = $originalDuration;
        if ($plan->{blockNotified}) {
            $delayedMinutes = $minute - $plan->{plannedStartMinute};
            $delayedMinutes = 0 if $delayedMinutes < 0;
            $duration -= $delayedMinutes;

            # Preserve the originally planned end time. If the remaining runtime
            # has already fallen below one minute, the pending plan is consumed
            # without switching and without a second event.
            if ($duration < 1) {
                $data->{state}{$playedBinsKey}{$date}{$dev}{$bin} = 1;
                delete $data->{state}{$plannedBinsKey}{$date}{$dev}{$bin};
                PresenceSimulation_Log(
                    $hash, 3,
                    sprintf(
                        '%s delayed plan expired without start: %s, planned=%s, '
                            . 'originalDuration=%dmin, delayed=%dmin',
                        $modeLabel,
                        $dev,
                        PresenceSimulation_FormatMinuteOfDay($plan->{plannedStartMinute}),
                        $originalDuration,
                        $delayedMinutes,
                    )
                );
                PresenceSimulation_MarkDirty($hash, 'state');
                next;
            }
        }

        if ($dryRun) {
            $data->{state}{dryManaged}{$dev} = {
                offDue          => $now + ($duration * 60),
                durationMinutes => $duration,
                modelType       => $plan->{modelType},
            };
        }
        else {
            $data->{state}{managed}{$dev} = {
                offDue          => $now + ($duration * 60),
                durationMinutes => $duration,
                modelType       => $plan->{modelType},
                readingDevice   => $cfg->{readingDevice},
                reading         => $cfg->{reading},
                onPattern       => $cfg->{onPattern},
                offPattern      => $cfg->{offPattern},
                offCommand      => $cfg->{offCommand},
                stopping        => 0,
                offAttempts     => 0,
                offFailed       => 0,
                offLastError    => '',
            };
        }
        $data->{state}{$playedBinsKey}{$date}{$dev}{$bin} = 1;

        my $eventDetails = {
            durationMinutes        => $duration,
            probabilityHistorical => $plan->{probabilityHistorical},
            probabilityBlock      => $plan->{probabilityEffective},
            probabilityFactor     => $plan->{probabilityFactor},
            plannedStartMinute     => $plan->{plannedStartMinute},
            historyStarts          => $plan->{historyStarts},
            historyDays            => $plan->{historyDays},
            historyPositionSamples => $plan->{historyPositionSamples},
            modelType              => $plan->{modelType},
        };
        if ($plan->{blockNotified}) {
            $eventDetails->{actualStartMinute} = $minute;
            $eventDetails->{delayedMinutes} = $delayedMinutes;
        }

        if ($dryRun) {
            delete $data->{state}{$plannedBinsKey}{$date}{$dev}{$bin};
            PresenceSimulation_EmitSimulationEvent($hash, 'dryrun', $dev, 'on', $eventDetails);
            my %logPlan = (%{$plan}, durationMinutes => $duration);
            PresenceSimulation_Log(
                $hash, 3,
                PresenceSimulation_FormatSimulationOnLog($modeLabel, $dev, \%logPlan)
            );
            PresenceSimulation_MarkDirty($hash, 'state');
            next;
        }

        $data->{state}{expected}{$dev} = { state => 'on', until => $now + 20 };
        my $error = CommandSet(undef, "$dev $cfg->{onCommand}");
        if ($error) {
            delete $data->{state}{managed}{$dev};
            delete $data->{state}{expected}{$dev};
            delete $data->{state}{$playedBinsKey}{$date}{$dev}{$bin};
            PresenceSimulation_SetError($hash, "$dev on failed: $error", 'playback');
        }
        else {
            delete $data->{state}{$plannedBinsKey}{$date}{$dev}{$bin};
            PresenceSimulation_ClearError($hash, 'playback');
            PresenceSimulation_EmitSimulationEvent($hash, 'playback', $dev, 'on', $eventDetails);
            my %logPlan = (%{$plan}, durationMinutes => $duration);
            PresenceSimulation_Log(
                $hash, 3,
                PresenceSimulation_FormatSimulationOnLog($modeLabel, $dev, \%logPlan)
            );
            PresenceSimulation_MarkDirty($hash, 'state');
        }
    }

    PresenceSimulation_ClearError($hash, 'blockCondition') if !$blockEvaluationFailed;
    return;
}

# Builds the compact placeholder map used by eventFn command templates.
# The percent-prefixed keys are required internally by FHEM's EvalSpecials();
# users reference them with dollar-prefixed placeholders in the attribute.
sub PresenceSimulation_EventFnSpecials {
    my ($hash, $eventText, $eventData) = @_;
    $eventData = {} if ref $eventData ne 'HASH';

    return (
        '%NAME'         => $hash->{NAME} // '',
        '%EVENT'        => $eventText // '',
        '%MODE'         => $eventData->{mode} // '',
        '%DEVICE'       => $eventData->{device} // '',
        '%ACTION'       => $eventData->{action} // '',
        '%EVENTDETAILS' => $eventData->{eventDetails} // '',
    );
}

# Executes eventFn as an inline FHEM command chain or Perl block.
# Functions from 99_myUtils.pm can be called explicitly from a Perl block.
sub PresenceSimulation_CallEventFn {
    my ($hash, $eventText, $eventData) = @_;
    my $name = $hash->{NAME};
    return if !AttrVal($name, 'eventFnEnabled', 1);

    my $handler = AttrVal($name, 'eventFn', '');
    return if $handler eq '';
    $handler =~ s/^\s+|\s+$//g;

    my $syntaxError = PresenceSimulation_EventFnSyntaxError($handler);
    if (defined $syntaxError) {
        PresenceSimulation_SetError($hash, $syntaxError, 'eventFn');
        return;
    }

    $hash->{helper} //= {};
    if ($hash->{helper}{eventFnActive}) {
        PresenceSimulation_Log($hash, 2, 'eventFn recursion suppressed');
        return;
    }

    local $hash->{helper}{eventFnActive} = 1;

    my %specials = PresenceSimulation_EventFnSpecials($hash, $eventText, $eventData);
    my $expanded = EvalSpecials($handler, %specials);
    my $error = AnalyzeCommandChain(undef, $expanded);
    if (defined $error && $error ne '') {
        $error = PresenceSimulation_OneLineError($error);
        PresenceSimulation_SetError($hash, "eventFn command failed: $error", 'eventFn');
        return;
    }

    PresenceSimulation_ClearError($hash, 'eventFn');
    return;
}

# Publishes one dry-run or playback action and invokes the optional event handler.
sub PresenceSimulation_EmitSimulationEvent {
    my ($hash, $mode, $dev, $action, $details) = @_;
    $details = {} if ref $details ne 'HASH';
    $mode = $mode eq 'playback' ? 'playback' : 'dryrun';

    my $timestamp = strftime('%Y-%m-%dT%H:%M:%S', localtime(CORE::time()));
    my @detailParts = ("timestamp=$timestamp");
    push @detailParts, 'duration=' . int($details->{durationMinutes}) . 'min'
        if defined $details->{durationMinutes};
    push @detailParts, 'pHistorical=' . sprintf('%.2f%%', $details->{probabilityHistorical} * 100)
        if defined $details->{probabilityHistorical};
    push @detailParts, 'pBlock=' . sprintf('%.2f%%', $details->{probabilityBlock} * 100)
        if defined $details->{probabilityBlock};
    push @detailParts, 'factor=' . sprintf('%.3f', $details->{probabilityFactor})
        if defined $details->{probabilityFactor};
    push @detailParts, 'planned=' . PresenceSimulation_FormatMinuteOfDay($details->{plannedStartMinute})
        if defined $details->{plannedStartMinute};
    push @detailParts, 'started=' . PresenceSimulation_FormatMinuteOfDay($details->{actualStartMinute})
        if defined $details->{actualStartMinute};
    push @detailParts, 'delayed=' . int($details->{delayedMinutes}) . 'min'
        if defined $details->{delayedMinutes};
    push @detailParts, 'history=' . int($details->{historyStarts}) . '/' . int($details->{historyDays})
        if defined $details->{historyStarts} && defined $details->{historyDays};
    push @detailParts, 'positionSamples=' . int($details->{historyPositionSamples})
        if defined $details->{historyPositionSamples};
    push @detailParts, 'pending=1' if $details->{pending};
    push @detailParts, 'retryUntil=' . $details->{retryUntil}
        if defined $details->{retryUntil} && $details->{retryUntil} ne '';
    push @detailParts, 'condition=' . $details->{blockCondition} if defined $details->{blockCondition};
    push @detailParts, 'reason=evaluationError'
        if defined $details->{blockReason} && $details->{blockReason} eq 'evaluationError';
    push @detailParts, 'model=' . $details->{modelType} if defined $details->{modelType};

    my $eventDetails = join(' ', @detailParts);
    my @eventParts = ($timestamp, "mode=$mode", "device=$dev", "action=$action");
    push @eventParts, @detailParts[1 .. $#detailParts] if @detailParts > 1;
    my $eventText = join(' ', @eventParts);

    my %eventData = (
        timestamp    => $timestamp,
        mode         => $mode,
        device       => $dev,
        action       => $action,
        eventDetails => $eventDetails,
        text         => $eventText,
        %{$details},
    );

    readingsSingleUpdate($hash, 'simulationEvent', $eventText, 1);
    PresenceSimulation_CallEventFn($hash, $eventText, \%eventData);
    return;
}

# Calculates probabilities and durations from the raw data.
sub PresenceSimulation_RebuildModel {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    return if !$data;

    my $trainingDays = int(AttrVal($name, 'trainingDays', 30));
    my $binMinutes   = int(AttrVal($name, 'binMinutes', 15));
    my $minSeconds   = int(AttrVal($name, 'minTrainingMinutes', 1200)) * 60;
    my $weekdaySpecific = AttrVal($name, 'weekdaySpecific', 0) ? 1 : 0;
    my $trainingSource = PresenceSimulation_TrainingSource($name);
    my $dbLogDevice = AttrVal($name, 'dbLogDevice', '');
    my @candidateDates = PresenceSimulation_PreviousDates($trainingDays);
    # trainingSource controls ongoing acquisition only. Model selection uses
    # the shared retained history in both modes: imported days are eligible by
    # their persisted source marker, while live event days must meet the
    # configured minimum recording coverage.
    my @validDates = grep {
        my $day = $data->{raw}{days}{$_};
        if (!$day) {
            0;
        }
        else {
            my $isImported = ($day->{importedFromDbLog} // '') ne '';
            $isImported || ($day->{trainingSeconds} // 0) >= $minSeconds;
        }
    } @candidateDates;

    my %sourceDays = (events => 0, dblog => 0);
    for my $date (@validDates) {
        my $day = PresenceSimulation_AsHash($data->{raw}{days}{$date});
        my $isImported = ($day->{importedFromDbLog} // '') ne '';
        $sourceDays{$isImported ? 'dblog' : 'events'}++;
    }

    my $rawChanged = 0;
    for my $date (keys %{$data->{raw}{days}}) {
        next if defined $data->{raw}{days}{$date}{weekday};
        $data->{raw}{days}{$date}{weekday} = PresenceSimulation_WeekdayForDate($date);
        $rawChanged = 1;
    }
    PresenceSimulation_MarkDirty($hash, 'raw') if $rawChanged;

    my $allDays = PresenceSimulation_BuildModelSection(
        $data, \@validDates, $binMinutes
    );

    my %weekdays;
    for my $weekday (0 .. 6) {
        my @weekdayDates = grep {
            PresenceSimulation_WeekdayForDate($_) == $weekday
        } @validDates;

        my $section = PresenceSimulation_BuildModelSection(
            $data, \@weekdayDates, $binMinutes
        );
        $section->{name} = PresenceSimulation_WeekdayName($weekday);
        $weekdays{$weekday} = $section;
    }

    $data->{model} = {
        schemaVersion         => $PRESENCE_SIM_SCHEMA,
        moduleVersion         => $PRESENCE_SIM_VERSION,
        deviceName            => $name,
        createdAt             => CORE::time(),
        binMinutes            => $binMinutes,
        trainingDaysRequested  => $trainingDays,
        retentionDaysConfigured => int(AttrVal($name, 'retentionDays', 90)),
        retentionDaysEffective  => PresenceSimulation_EffectiveRetentionDays($name),
        weekdaySpecific       => $weekdaySpecific,
        trainingSource        => $trainingSource,
        dbLogDevice           => $dbLogDevice,
        sourceDays            => \%sourceDays,
        validDates            => \@validDates,
        allDays               => $allDays,
        weekdays              => \%weekdays,
        deviceTotals          => $allDays->{deviceTotals},
        sessionCount          => $allDays->{sessionCount},
    };

    PresenceSimulation_UpdateReadings($hash);
    PresenceSimulation_Log(
        $hash, 3,
        "model rebuilt: type=" . ($weekdaySpecific ? 'weekday-specific' : 'all-days')
            . ", trainingSource=$trainingSource"
            . ", usableDays=" . scalar(@validDates)
            . ", eventDays=" . $sourceDays{events}
            . ", importedDays=" . $sourceDays{dblog}
            . ", sessions=" . ($allDays->{sessionCount} // 0)
            . ", binMinutes=$binMinutes"
            . ", retentionDays=" . PresenceSimulation_EffectiveRetentionDays($name)
    );
    return;
}

# Builds one model section for a supplied set of training dates.
sub PresenceSimulation_BuildModelSection {
    my ($data, $dates, $binMinutes) = @_;
    die 'binMinutes must be one of 1, 5, 10, 15, 20, 30, or 60'
        if !PresenceSimulation_IsValidBinMinutes($binMinutes);
    my %devices;
    my %deviceTotals;
    my $sessionCount = 0;

    for my $dev (@{$data->{config}{order}}) {
        $devices{$dev} = { bins => {}, allDurations => [] };
        $deviceTotals{$dev} = 0;
        my %daysWithStart;

        for my $date (@{$dates}) {
            my $sessions = $data->{raw}{days}{$date}{sessions}{$dev} // [];
            for my $session (@{$sessions}) {
                next if !defined $session->{startMinute} || !defined $session->{durationMinutes};
                my $bin = int($session->{startMinute} / $binMinutes);
                my $duration = int($session->{durationMinutes});

                push @{$devices{$dev}{bins}{$bin}{durations}}, $duration;
                push @{$devices{$dev}{bins}{$bin}{startOffsets}},
                    int($session->{startMinute}) - ($bin * $binMinutes);
                push @{$devices{$dev}{allDurations}}, $duration;
                $daysWithStart{$bin}{$date} = 1;
                $deviceTotals{$dev}++;
                $sessionCount++;
            }
        }

        for my $bin (keys %{$devices{$dev}{bins}}) {
            my $days = scalar keys %{$daysWithStart{$bin} // {}};
            $devices{$dev}{bins}{$bin}{daysWithStart} = $days;
            $devices{$dev}{bins}{$bin}{probability} = @{$dates}
                ? $days / scalar(@{$dates})
                : 0;
        }

    }

    return {
        validDates   => [@{$dates}],
        devices      => \%devices,
        deviceTotals => \%deviceTotals,
        sessionCount => $sessionCount,
    };
}

# Returns the effective raw-data retention period.
# The effective value never falls below trainingDays, so model input cannot be
# deleted while it is still part of the configured training window.
sub PresenceSimulation_EffectiveRetentionDays {
    my ($name) = @_;
    my $trainingDays  = int(AttrVal($name, 'trainingDays', 30));
    my $retentionDays = int(AttrVal($name, 'retentionDays', 90));
    $trainingDays  = 1 if $trainingDays < 1;
    $retentionDays = 1 if $retentionDays < 1;
    return $retentionDays < $trainingDays ? $trainingDays : $retentionDays;
}

# Removes raw data older than the configured retention period.
sub PresenceSimulation_PruneRaw {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    return if !$data;

    my $retentionDays = PresenceSimulation_EffectiveRetentionDays($name);
    my %keep = map { $_ => 1 } (
        PresenceSimulation_PreviousDates($retentionDays),
        PresenceSimulation_Date(CORE::time())
    );
    my $removed = 0;

    for my $date (keys %{PresenceSimulation_AsHash($data->{raw}{days})}) {
        if (!$keep{$date}) {
            delete $data->{raw}{days}{$date};
            $removed++;
        }
    }

    if ($removed) {
        PresenceSimulation_Log(
            $hash, 4,
            "pruned $removed old raw-data day(s), retentionDays=$retentionDays"
        );
        PresenceSimulation_MarkDirty($hash, 'raw');
    }
    return $removed;
}

# Keeps playback and dry-run markers only for the current day.
sub PresenceSimulation_PrunePlaybackState {
    my ($hash, $currentDate) = @_;
    my $name = $hash->{NAME};
    my $state = $PresenceSimulation_DATA{$name}{state};
    $state->{playedBins} = { $currentDate => ($state->{playedBins}{$currentDate} // {}) };
    $state->{dryPlayedBins} = { $currentDate => ($state->{dryPlayedBins}{$currentDate} // {}) };
    $state->{plannedBins} = { $currentDate => ($state->{plannedBins}{$currentDate} // {}) };
    $state->{dryPlannedBins} = { $currentDate => ($state->{dryPlannedBins}{$currentDate} // {}) };
    return;
}

# Removes expired expected events and manual locks.
sub PresenceSimulation_CleanupRuntime {
    my ($hash, $now) = @_;
    my $name = $hash->{NAME};
    my $state = $PresenceSimulation_DATA{$name}{state};

    for my $dev (keys %{$state->{expected}}) {
        delete $state->{expected}{$dev} if ($state->{expected}{$dev}{until} // 0) < $now;
    }
    for my $dev (keys %{$state->{manualLockUntil}}) {
        delete $state->{manualLockUntil}{$dev} if ($state->{manualLockUntil}{$dev} // 0) <= $now;
    }
    return;
}

# Switches safely between training, playback, dry-run, and off modes.
sub PresenceSimulation_SetMode {
    my ($hash, $mode) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};

    return 'mode must be training, playback, dryrun or off'
        if $mode !~ /^(?:training|playback|dryrun|off)$/;

    my $simulationMode = $mode eq 'playback' || $mode eq 'dryrun';
    if ($mode ne 'off') {
        my $configError = PresenceSimulation_EnsureConfigReady($hash);
        return $configError if defined $configError;
        PresenceSimulation_RebuildModel($hash) if $simulationMode;
    }
    return 'No usable training days are available'
        if $simulationMode && !@{$data->{model}{validDates} // []};

    if ($simulationMode) {
        my $weekdaySpecific = AttrVal($name, 'weekdaySpecific', 0);
        if ($weekdaySpecific) {
            my $weekday = PresenceSimulation_WeekdayIndex(CORE::time());
            my $weekdayDays = scalar @{$data->{model}{weekdays}{$weekday}{validDates} // []};
            return 'No usable training days are available for ' . PresenceSimulation_WeekdayName($weekday)
                if !$weekdayDays;
        }
        else {
            my $allDays = scalar @{$data->{model}{allDays}{validDates} // []};
            return 'No usable training days are available for the all-days model' if !$allDays;
        }
    }

    my $oldMode = $data->{state}{mode} // 'off';
    if ($oldMode eq $mode) {
        PresenceSimulation_Log($hash, 4, "mode remains $mode");
        return;
    }

    my $eventTraining = PresenceSimulation_TrainingSource($name) eq 'events';
    my $oldTrainingCapable = $eventTraining && ($oldMode eq 'training' || $oldMode eq 'dryrun');
    my $newTrainingCapable = $eventTraining && ($mode    eq 'training' || $mode    eq 'dryrun');

    if ($oldMode eq 'playback') {
        PresenceSimulation_StopPlayback($hash, 1);
    }
    elsif ($oldMode eq 'dryrun') {
        PresenceSimulation_StopDryRun($hash);
    }

    # Preserve open real-device sessions when switching between training and
    # dry-run. Discard them only when leaving all training-capable modes.
    if ($oldTrainingCapable && !$newTrainingCapable) {
        $data->{state}{activeSessions} = {};
    }

    $data->{state}{mode} = $mode;
    $data->{state}{lastCoverageTick} = CORE::time();
    if ($mode eq 'playback') {
        $data->{state}{playedBins} = {};
        $data->{state}{plannedBins} = {};
    }
    elsif ($mode eq 'dryrun') {
        $data->{state}{dryPlayedBins} = {};
        $data->{state}{dryPlannedBins} = {};
    }

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'mode',  $mode);
    readingsBulkUpdate($hash, 'state', $mode);
    readingsEndUpdate($hash, 1);

    PresenceSimulation_MarkDirty($hash, 'state');
    PresenceSimulation_UpdateReadings($hash);
    PresenceSimulation_Log($hash, 3, "mode changed: $oldMode -> $mode");
    return;
}

# Stops playback and optionally turns off managed devices.
sub PresenceSimulation_StopPlayback {
    my ($hash, $switchOff) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    my $now = CORE::time();

    for my $dev (keys %{PresenceSimulation_AsHash($data->{state}{managed})}) {
        my $entry = PresenceSimulation_AsHash($data->{state}{managed}{$dev});
        my $cfg = PresenceSimulation_ConfigForManagedEntry($data, $dev, $entry);
        if (!$cfg) {
            PresenceSimulation_SetError(
                $hash,
                "Cannot stop managed device $dev: missing device configuration snapshot",
                'playback'
            );
            next;
        }

        if (!$switchOff) {
            delete $data->{state}{managed}{$dev};
            next;
        }

        if (!$entry->{stopping}) {
            $entry->{stopping} = 1;
            $entry->{offRetryDue} = $now;
        }
        elsif (!defined $entry->{offRetryDue}) {
            $entry->{offRetryDue} = $now;
        }
    }

    PresenceSimulation_ProcessPendingPlaybackStops($hash, $now) if $switchOff;
    $data->{state}{plannedBins} = {};
    PresenceSimulation_MarkDirty($hash, 'state');
    return;
}



# Stops virtual playback without sending commands to real devices.
sub PresenceSimulation_StopDryRun {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    my $count = scalar keys %{PresenceSimulation_AsHash($data->{state}{dryManaged})};

    $data->{state}{dryManaged} = {};
    $data->{state}{dryPlannedBins} = {};
    PresenceSimulation_MarkDirty($hash, 'state');
    PresenceSimulation_Log($hash, 4, "dry run stopped: cleared $count virtual sessions") if $count;
    return;
}

# Reconciles persisted runtime state with current readings.
sub PresenceSimulation_ReconcileRuntimeState {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    my @warnings;
    my $changed = 0;

    for my $dev (keys %{$data->{state}{activeSessions}}) {
        my $cfg = $data->{config}{byDevice}{$dev};
        if (!$cfg) {
            delete $data->{state}{activeSessions}{$dev};
            $changed = 1;
            PresenceSimulation_Log($hash, 4, "removed stale training session for unconfigured device $dev");
            next;
        }
        my $value = PresenceSimulation_ObservedReadingValue($cfg);
        my $state = defined $value ? PresenceSimulation_ClassifyValue($cfg, $value) : undef;
        if (defined $state && $state eq 'off') {
            delete $data->{state}{activeSessions}{$dev};
            $changed = 1;
            PresenceSimulation_Log($hash, 4, "removed stale training session for $dev: current state is off");
        }
        elsif (!defined $state) {
            push @warnings, "cannot determine current state of active training device $dev";
        }
    }

    for my $dev (keys %{$data->{state}{managed}}) {
        my $entry = PresenceSimulation_AsHash($data->{state}{managed}{$dev});
        if ($entry->{offFailed}) {
            PresenceSimulation_ReleaseManagedOffFailure($hash, $dev, $entry);
            $changed = 1;
            next;
        }
        my $cfg = PresenceSimulation_ConfigForManagedEntry($data, $dev, $entry);
        if (!$cfg) {
            push @warnings, "cannot reconcile managed device $dev: missing configuration snapshot";
            next;
        }
        my $value = PresenceSimulation_ObservedReadingValue($cfg);
        my $state = defined $value ? PresenceSimulation_ClassifyValue($cfg, $value) : undef;
        if (defined $state && $state eq 'off') {
            delete $data->{state}{managed}{$dev};
            $changed = 1;
            PresenceSimulation_ClearPlaybackErrorAfterConfirmedOff($hash);
            PresenceSimulation_Log($hash, 4, "removed stale playback state for $dev: current state is off");
        }
        elsif (!defined $state) {
            push @warnings, "cannot determine current state of managed device $dev";
        }
    }

    for my $dev (keys %{$data->{state}{dryManaged}}) {
        if (!$data->{config}{byDevice}{$dev}) {
            delete $data->{state}{dryManaged}{$dev};
            $changed = 1;
            PresenceSimulation_Log($hash, 4, "removed stale dry-run state for unconfigured device $dev");
        }
    }

    PresenceSimulation_MarkDirty($hash, 'state') if $changed;
    if (@warnings) {
        PresenceSimulation_SetError($hash, join('; ', @warnings), 'runtime');
    }
    else {
        PresenceSimulation_ClearError($hash, 'runtime');
    }
    return;
}

# Returns a hash reference or an empty hash for invalid data.
sub PresenceSimulation_AsHash {
    my ($value) = @_;
    return ref $value eq 'HASH' ? $value : {};
}

# Returns an array reference or an empty array for invalid data.
sub PresenceSimulation_AsArray {
    my ($value) = @_;
    return ref $value eq 'ARRAY' ? $value : [];
}

# Counts all stored raw training sessions and the sessions of one date.
sub PresenceSimulation_CountRawSessions {
    my ($raw, $date) = @_;
    $raw = PresenceSimulation_AsHash($raw);
    my $days = PresenceSimulation_AsHash($raw->{days});

    my $total = 0;
    my $today = 0;
    my $todayDiscarded = 0;

    for my $dayDate (keys %{$days}) {
        my $day = PresenceSimulation_AsHash($days->{$dayDate});
        my $sessions = PresenceSimulation_AsHash($day->{sessions});
        my $dayCount = 0;

        for my $dev (keys %{$sessions}) {
            $dayCount += scalar @{PresenceSimulation_AsArray($sessions->{$dev})};
        }

        $total += $dayCount;
        if (defined $date && $dayDate eq $date) {
            $today = $dayCount;
            $todayDiscarded = int($day->{discardedSessions} // 0);
        }
    }

    return ($total, $today, $todayDiscarded);
}

# Updates the module status and statistics readings.
sub PresenceSimulation_UpdateReadings {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});
    return if !%{$data};

    my $model  = PresenceSimulation_AsHash($data->{model});
    my $state  = PresenceSimulation_AsHash($data->{state});
    my $weekdays = PresenceSimulation_AsHash($model->{weekdays});
    my $allDays  = PresenceSimulation_AsHash($model->{allDays});

    my $validDays = scalar @{PresenceSimulation_AsArray($model->{validDates})};
    my $sessions  = $model->{sessionCount} // 0;
    my ($rawSessions, $rawSessionsToday, $rawSessionsTodayDiscarded) =
        PresenceSimulation_CountRawSessions(
            $data->{raw}, PresenceSimulation_Date(CORE::time())
        );
    my $activeTraining = scalar keys %{PresenceSimulation_AsHash($state->{activeSessions})};
    my $activePlayback = scalar keys %{PresenceSimulation_AsHash($state->{managed})};
    my $stoppingPlayback = scalar grep { $_->{stopping} }
        values %{PresenceSimulation_AsHash($state->{managed})};
    my $activeDryRun  = scalar keys %{PresenceSimulation_AsHash($state->{dryManaged})};
    my $created = $model->{createdAt}
        ? PresenceSimulation_FormatDateTime($model->{createdAt})
        : '-';
    my $weekday = PresenceSimulation_WeekdayIndex(CORE::time());
    my $weekdayModel = PresenceSimulation_AsHash($weekdays->{$weekday});
    my $weekdayDays = scalar @{PresenceSimulation_AsArray($weekdayModel->{validDates})};
    my $weekdaySpecific = AttrVal($name, 'weekdaySpecific', 0) ? 1 : 0;
    my $effectiveDays = $weekdaySpecific
        ? $weekdayDays
        : scalar @{PresenceSimulation_AsArray($allDays->{validDates})};
    my $rawDays = scalar keys %{PresenceSimulation_AsHash($data->{raw}{days})};

    readingsBeginUpdate($hash);
    readingsBulkUpdateIfChanged($hash, 'trainingDaysUsed',      $validDays);
    readingsBulkUpdateIfChanged($hash, 'effectiveTrainingDays', $effectiveDays);
    readingsBulkUpdateIfChanged($hash, 'modelSessions',         $sessions);
    readingsBulkUpdateIfChanged($hash, 'rawSessions',           $rawSessions);
    readingsBulkUpdateIfChanged($hash, 'rawSessionsToday',          $rawSessionsToday);
    readingsBulkUpdateIfChanged(
        $hash, 'rawSessionsTodayDiscarded', $rawSessionsTodayDiscarded
    );
    readingsBulkUpdateIfChanged($hash, 'rawDays',                   $rawDays);
    readingsBulkUpdateIfChanged($hash, 'activeTraining',        $activeTraining);
    readingsBulkUpdateIfChanged($hash, 'activePlayback',        $activePlayback);
    readingsBulkUpdateIfChanged($hash, 'stoppingPlayback',      $stoppingPlayback);
    readingsBulkUpdateIfChanged($hash, 'activeDryRun',          $activeDryRun);
    readingsBulkUpdateIfChanged($hash, 'modelCreated',          $created);
    readingsEndUpdate($hash, 1);
    return;
}

# Creates a human-readable summary of the current model.
sub PresenceSimulation_ModelInfo {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});
    return 'Module data is not initialized' if !%{$data};

    my $model  = PresenceSimulation_AsHash($data->{model});
    my $state  = PresenceSimulation_AsHash($data->{state});
    my $config = PresenceSimulation_AsHash($data->{config});
    my $order  = PresenceSimulation_AsArray($config->{order});
    my $weekdays = PresenceSimulation_AsHash($model->{weekdays});
    my $allDays  = PresenceSimulation_AsHash($model->{allDays});
    my $deviceTotals = PresenceSimulation_AsHash($model->{deviceTotals});
    my $weekdaySpecific = AttrVal($name, 'weekdaySpecific', 0) ? 1 : 0;

    my @out;
    push @out, "Module version: $PRESENCE_SIM_VERSION";
    push @out, 'Mode: ' . ($state->{mode} // 'off');
    my $trainingSource = PresenceSimulation_TrainingSource($name);
    push @out, 'Training source: ' . $trainingSource;
    push @out, 'DbLog device: ' . (AttrVal($name, 'dbLogDevice', '') || '-');
    if ($trainingSource eq 'dblog') {
        push @out, 'Automatic import time: ' . AttrVal($name, 'importTime', '03:05');
        push @out, 'Next DbLog import: ' . ReadingsVal($name, 'nextDbLogImport', '-');
    }
    push @out, 'Configured devices: ' . scalar(@{$order});
    push @out, 'Configuration ready: ' . ($config->{ready} ? 'yes' : 'no');
    push @out, 'Configured global blocks: ' . scalar(@{PresenceSimulation_AsArray($config->{globalBlocks})});
    my $deviceBlockCount = 0;
    for my $device (@{$order}) {
        my $deviceConfig = PresenceSimulation_AsHash($config->{byDevice}{$device});
        $deviceBlockCount += scalar @{PresenceSimulation_AsArray($deviceConfig->{blocks})};
    }
    push @out, 'Configured device blocks: ' . $deviceBlockCount;
    push @out, 'Current weekday: ' . PresenceSimulation_WeekdayName(PresenceSimulation_WeekdayIndex(CORE::time()));
    push @out, 'Model type: ' . ($weekdaySpecific ? 'weekday-specific' : 'all-days');
    push @out, 'Bin size: ' . ($model->{binMinutes} // '-') . ' minutes';
    push @out, 'Requested training history: ' . ($model->{trainingDaysRequested} // '-') . ' calendar days';
    push @out, 'Raw-data retention: ' . PresenceSimulation_EffectiveRetentionDays($name)
        . ' calendar days (configured ' . int(AttrVal($name, 'retentionDays', 90)) . ')';
    push @out, 'Raw-data days stored: ' . scalar(keys %{PresenceSimulation_AsHash($data->{raw}{days})});
    push @out, 'Usable training days total: ' . scalar(@{PresenceSimulation_AsArray($model->{validDates})});
    my $sourceDays = PresenceSimulation_AsHash($model->{sourceDays});
    push @out, 'Usable event days: ' . int($sourceDays->{events} // 0);
    push @out, 'Usable imported DbLog days: ' . int($sourceDays->{dblog} // 0);
    my ($rawSessions, $rawSessionsToday, $rawSessionsTodayDiscarded) =
        PresenceSimulation_CountRawSessions(
            $data->{raw}, PresenceSimulation_Date(CORE::time())
        );
    push @out, 'Sessions in model: ' . ($model->{sessionCount} // 0);
    push @out, 'Raw sessions total: ' . $rawSessions;
    push @out, 'Raw sessions today: ' . $rawSessionsToday;
    push @out, 'Raw sessions discarded today: ' . $rawSessionsTodayDiscarded;
    push @out, 'Active dry-run sessions: ' . scalar(keys %{PresenceSimulation_AsHash($state->{dryManaged})});
    push @out, 'Discarded sessions: ' . int($state->{discardedSessions} // 0);
    push @out, 'Model created: ' . ($model->{createdAt}
        ? PresenceSimulation_FormatDateTime($model->{createdAt}) : '-');

    if ($weekdaySpecific) {
        for my $weekday (1 .. 6, 0) {
            my $weekdayModel = PresenceSimulation_AsHash($weekdays->{$weekday});
            push @out, sprintf(
                '%s: %d training days, %d sessions',
                PresenceSimulation_WeekdayName($weekday),
                scalar(@{PresenceSimulation_AsArray($weekdayModel->{validDates})}),
                $weekdayModel->{sessionCount} // 0
            );
        }
    }
    else {
        push @out, sprintf(
            'All days: %d training days, %d sessions',
            scalar(@{PresenceSimulation_AsArray($allDays->{validDates})}),
            $allDays->{sessionCount} // 0
        );
    }

    for my $dev (@{$order}) {
        my $count = $deviceTotals->{$dev} // 0;
        my $cfg = PresenceSimulation_AsHash($config->{byDevice}{$dev});
        my $readingDevice = $cfg->{readingDevice} // $dev;
        my $suffix = $readingDevice ne $dev
            ? " (observed via $readingDevice:$cfg->{reading})"
            : '';
        push @out, "$dev: $count sessions$suffix";
    }

    return join "\n", @out;
}

# Creates a human-readable summary of the latest DbLog import.
sub PresenceSimulation_ImportInfo {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $data = PresenceSimulation_AsHash($PresenceSimulation_DATA{$name});
    return 'Module data is not initialized' if !%{$data};

    my $state = PresenceSimulation_AsHash($data->{state});
    my $info = PresenceSimulation_AsHash($state->{importInfo});
    my @out;
    push @out, 'Training source: ' . PresenceSimulation_TrainingSource($name);
    push @out, 'DbLog device: ' . (AttrVal($name, 'dbLogDevice', '') || '-');
    push @out, 'State: ' . ($info->{state} // ReadingsVal($name, 'importState', 'idle'));
    push @out, 'Context: ' . ($info->{context} // '-');
    push @out, 'Requested days: ' . ($info->{days} // '-');
    push @out, 'Started: ' . ($info->{started} // '-');
    push @out, 'Finished: ' . ($info->{finished} // '-');
    push @out, 'Rows read: ' . int($info->{rows} // 0);
    push @out, 'Rows in target range: ' . int($info->{targetRows} // 0);
    push @out, 'Imported sessions: ' . int($info->{sessions} // 0);
    push @out, 'Days with rows: ' . int($info->{daysWithRows} // 0);
    push @out, 'First timestamp: ' . ($info->{firstTimestamp} || '-');
    push @out, 'Last timestamp: ' . ($info->{lastTimestamp} || '-');
    push @out, 'Automatic failures: ' . int($state->{autoImportFailures} // 0);
    push @out, 'Next automatic import: ' . ReadingsVal($name, 'nextDbLogImport', '-');
    push @out, 'Error: ' . ($info->{error} || '-');
    return join "\n", @out;
}

# Shows historical and effective block probability for a given time.
sub PresenceSimulation_GetProbability {
    my ($hash, $dev, $timeText, $weekdayText) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};

    return "Unknown configured device $dev" if !$data->{config}{byDevice}{$dev};
    return 'Time must be HH:MM' if $timeText !~ /^(\d\d?):(\d\d)$/;

    my ($hour, $minute) = ($1, $2);
    return 'Invalid time' if $hour > 23 || $minute > 59;

    my $binMinutes = $data->{model}{binMinutes} || 15;
    return 'Model binMinutes is invalid'
        if !PresenceSimulation_IsValidBinMinutes($binMinutes);
    my $bin = int((($hour * 60) + $minute) / $binMinutes);
    my $weekdaySpecific = AttrVal($name, 'weekdaySpecific', 0) ? 1 : 0;

    my ($selectedModel, $label);
    if (defined $weekdayText) {
        my $weekday = PresenceSimulation_ParseWeekday($weekdayText);
        return 'Weekday must be Montag..Sonntag, Monday..Sunday or 0..6' if !defined $weekday;
        $selectedModel = $data->{model}{weekdays}{$weekday};
        $label = PresenceSimulation_WeekdayName($weekday);
    }
    elsif ($weekdaySpecific) {
        my $weekday = PresenceSimulation_WeekdayIndex(CORE::time());
        $selectedModel = $data->{model}{weekdays}{$weekday};
        $label = PresenceSimulation_WeekdayName($weekday);
    }
    else {
        $selectedModel = $data->{model}{allDays};
        $label = 'Alle Tage';
    }

    my $days = scalar @{$selectedModel->{validDates} // []};
    return sprintf('%s %s %s: no usable training days', $dev, $label, $timeText) if !$days;

    my $entry = $selectedModel->{devices}{$dev}{bins}{$bin};
    return sprintf('%s %s %s: no historical starts in this time bin (%d training days)',
        $dev, $label, $timeText, $days) if !$entry;

    my $historicalProbability = $entry->{probability} // 0;
    my $factor = AttrVal($name, 'probabilityFactor', 1.0);
    my $effectiveProbability = $historicalProbability * $factor;
    $effectiveProbability = 1 if $effectiveProbability > 1;
    my $positionSamples = scalar @{$entry->{startOffsets} // []};
    return sprintf(
        '%s %s %s: historical block %.2f%%, factor %.3f, effective block %.2f%%, '
            . 'days with start %d of %d, start-position samples %d',
        $dev, $label, $timeText,
        $historicalProbability * 100, $factor, $effectiveProbability * 100,
        $entry->{daysWithStart} // 0, $days, $positionSamples
    );
}

# Marks data sections as changed and schedules persistence.
sub PresenceSimulation_MarkDirty {
    my ($hash, @parts) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    return if !$data;

    $data->{dirty}{$_} = 1 for grep { $_ eq 'raw' || $_ eq 'state' } @parts;
    return if $hash->{helper}{teardown};
    return if $hash->{helper}{saveScheduled};
    my $delay = AttrVal($name, 'saveInterval', 300);
    $hash->{helper}{saveScheduled} = 1;
    InternalTimer(gettimeofday() + $delay, 'PresenceSimulation_SaveDirty', $hash, 0);
    return;
}

# Saves all data changed since the last persistence run.
sub PresenceSimulation_SaveDirty {
    my ($hash) = @_;
    delete $hash->{helper}{saveScheduled};
    my $name = $hash->{NAME};
    return if !$defs{$name} || $defs{$name} != $hash || $hash->{helper}{teardown};
    PresenceSimulation_SaveAll($hash, 0);
    return;
}

# Writes durable raw data and runtime state to JSON files.
sub PresenceSimulation_SaveAll {
    my ($hash, $force) = @_;
    my $name = $hash->{NAME};
    my $data = $PresenceSimulation_DATA{$name};
    return if !$data;

    my $files = PresenceSimulation_FileNames($hash);
    my $json = JSON::PP->new->canonical(1)->allow_nonref(1);
    my (@errors, @savedParts);

    for my $part (qw(raw state)) {
        next if !$force && !$data->{dirty}{$part};
        my $payload = $data->{$part};
        $payload->{schemaVersion} = $PRESENCE_SIM_SCHEMA;
        $payload->{moduleVersion} = $PRESENCE_SIM_VERSION;
        $payload->{deviceName} = $name;

        my ($validated, $validationError) =
            PresenceSimulation_ValidatePersistedData($hash, $part, $payload);
        if (!$validated) {
            push @errors, "$part validation failed before save: $validationError";
            next;
        }

        my $encoded = eval { $json->encode($payload) };
        if ($@) {
            push @errors, "$part JSON encode failed: $@";
            next;
        }
        my $error = PresenceSimulation_WriteFileAtomic($files->{$part}, $encoded);
        if ($error) {
            push @errors, "$part: $error";
        }
        else {
            delete $data->{dirty}{$part};
            push @savedParts, $part;
        }
    }

    if (@errors) {
        PresenceSimulation_SetError($hash, join('; ', @errors), 'persistence');
    }
    elsif (@savedParts) {
        PresenceSimulation_ClearError($hash, 'persistence');
        PresenceSimulation_Log($hash, 4, 'saved data files: ' . join(', ', @savedParts));
    }
    return;
}


# Loads durable raw and runtime data; the probability model is rebuilt in memory.

# Returns true for an existing calendar date in YYYY-MM-DD form.
sub PresenceSimulation_ValidDateString {
    my ($date) = @_;
    return 0 if !defined $date || $date !~ /^\d{4}-\d{2}-\d{2}$/;
    my $epoch = PresenceSimulation_EpochFromDateTime("$date 00:00:00");
    return 0 if !defined $epoch;
    return PresenceSimulation_Date($epoch) eq $date ? 1 : 0;
}

sub PresenceSimulation_IsIntegerInRange {
    my ($value, $min, $max) = @_;
    return 0 if !defined $value || $value !~ /^-?\d+$/;
    return 0 if defined $min && $value < $min;
    return 0 if defined $max && $value > $max;
    return 1;
}

# Validates persisted data without converting older schemas or field layouts.
sub PresenceSimulation_ValidatePersistedData {
    my ($hash, $part, $loaded) = @_;
    return (undef, 'decoded content is not an object') if ref $loaded ne 'HASH';
    return (undef, 'missing schemaVersion') if !exists $loaded->{schemaVersion};

    my $schema = $loaded->{schemaVersion};
    return (undef, 'schemaVersion must be an integer')
        if !PresenceSimulation_IsIntegerInRange($schema, 0, undef);
    return (undef, "unsupported schema $schema; expected $PRESENCE_SIM_SCHEMA")
        if int($schema) != $PRESENCE_SIM_SCHEMA;
    return (undef, 'moduleVersion must be a non-empty scalar')
        if ref $loaded->{moduleVersion}
        || !defined $loaded->{moduleVersion}
        || $loaded->{moduleVersion} eq '';
    return (undef, 'deviceName must be a non-empty scalar')
        if ref $loaded->{deviceName}
        || !defined $loaded->{deviceName}
        || $loaded->{deviceName} eq '';
    if ($hash && defined $hash->{NAME} && $hash->{NAME} ne ''
        && $loaded->{deviceName} ne $hash->{NAME}) {
        return (undef, "deviceName $loaded->{deviceName} does not match $hash->{NAME}");
    }

    if ($part eq 'raw') {
        return (undef, 'raw.days must be an object') if ref $loaded->{days} ne 'HASH';
        for my $date (sort keys %{$loaded->{days}}) {
            return (undef, "raw day key $date is not a valid YYYY-MM-DD date")
                if !PresenceSimulation_ValidDateString($date);
            my $day = $loaded->{days}{$date};
            return (undef, "raw day $date must be an object") if ref $day ne 'HASH';
            return (undef, "raw day $date sessions must be an object")
                if ref $day->{sessions} ne 'HASH';
            return (undef, "raw day $date trainingSeconds must be an integer from 0 through 86400")
                if !PresenceSimulation_IsIntegerInRange($day->{trainingSeconds}, 0, 86400);
            return (undef, "raw day $date weekday must be 0 through 6")
                if !PresenceSimulation_IsIntegerInRange($day->{weekday}, 0, 6);
            return (undef, "raw day $date weekday does not match the date")
                if int($day->{weekday}) != PresenceSimulation_WeekdayForDate($date);
            if (exists $day->{discardedSessions}) {
                return (undef, "raw day $date discardedSessions must be a non-negative integer")
                    if !PresenceSimulation_IsIntegerInRange($day->{discardedSessions}, 0, undef);
            }
            for my $scalarKey (qw(source importedFromDbLog)) {
                next if !exists $day->{$scalarKey};
                return (undef, "raw day $date $scalarKey must be a scalar")
                    if ref $day->{$scalarKey};
            }
            if (exists $day->{importedAt}) {
                return (undef, "raw day $date importedAt must be a non-negative number")
                    if !looks_like_number($day->{importedAt}) || $day->{importedAt} < 0;
            }

            for my $dev (sort keys %{$day->{sessions}}) {
                return (undef, "raw day $date contains an empty device name") if $dev eq '';
                my $sessions = $day->{sessions}{$dev};
                return (undef, "raw day $date sessions for $dev must be an array")
                    if ref $sessions ne 'ARRAY';
                for my $index (0 .. $#{$sessions}) {
                    my $session = $sessions->[$index];
                    return (undef, "raw day $date session $dev/$index must be an object")
                        if ref $session ne 'HASH';
                    return (undef, "raw day $date session $dev/$index startMinute must be 0 through 1439")
                        if !PresenceSimulation_IsIntegerInRange($session->{startMinute}, 0, 1439);
                    return (undef, "raw day $date session $dev/$index durationMinutes must be a positive integer")
                        if !PresenceSimulation_IsIntegerInRange($session->{durationMinutes}, 1, undef);
                    if (exists $session->{weekday}) {
                        return (undef, "raw day $date session $dev/$index weekday must be 0 through 6")
                            if !PresenceSimulation_IsIntegerInRange($session->{weekday}, 0, 6);
                        return (undef, "raw day $date session $dev/$index weekday does not match the date")
                            if int($session->{weekday}) != PresenceSimulation_WeekdayForDate($date);
                    }
                    for my $epochKey (qw(startedAt endedAt importedAt)) {
                        next if !exists $session->{$epochKey};
                        return (undef, "raw day $date session $dev/$index $epochKey must be a non-negative number")
                            if !looks_like_number($session->{$epochKey}) || $session->{$epochKey} < 0;
                    }
                    for my $scalarKey (qw(source sourceDevice)) {
                        next if !exists $session->{$scalarKey};
                        return (undef, "raw day $date session $dev/$index $scalarKey must be a scalar")
                            if ref $session->{$scalarKey};
                    }
                    if (exists $session->{startedAt} && exists $session->{endedAt}
                        && $session->{endedAt} < $session->{startedAt}) {
                        return (undef, "raw day $date session $dev/$index ends before it starts");
                    }
                }
            }
        }
    }
    elsif ($part eq 'state') {
        for my $key (
            qw(activeSessions managed dryManaged expected manualLockUntil playedBins dryPlayedBins importInfo)
        ) {
            return (undef, "state.$key must be an object") if ref $loaded->{$key} ne 'HASH';
        }
        for my $key (qw(plannedBins dryPlannedBins)) {
            next if !exists $loaded->{$key};
            return (undef, "state.$key must be an object") if ref $loaded->{$key} ne 'HASH';
        }
        for my $key (
            qw(
                mode currentDate lastCoverageTick lastDbLogImportDate
                autoImportFailures autoImportRetryAt
                coverageDate coverageSeconds discardedSessions
            )
        ) {
            return (undef, "state.$key is missing") if !exists $loaded->{$key};
        }
        return (undef, 'state.mode must be training, playback, dryrun or off')
            if ($loaded->{mode} // '') !~ /^(?:training|playback|dryrun|off)$/;
        return (undef, 'state.currentDate must be a valid YYYY-MM-DD date')
            if !PresenceSimulation_ValidDateString($loaded->{currentDate});
        for my $key (qw(lastCoverageTick autoImportFailures autoImportRetryAt coverageSeconds discardedSessions)) {
            return (undef, "state.$key must be a non-negative integer")
                if !PresenceSimulation_IsIntegerInRange($loaded->{$key}, 0, undef);
        }
        return (undef, 'state.coverageSeconds must not exceed 86400')
            if $loaded->{coverageSeconds} > 86400;
        if (($loaded->{coverageDate} // '') ne '') {
            return (undef, 'state.coverageDate must be empty or a valid YYYY-MM-DD date')
                if !PresenceSimulation_ValidDateString($loaded->{coverageDate});
        }
        for my $dateKey (qw(lastDbLogImportDate)) {
            next if ($loaded->{$dateKey} // '') eq '';
            return (undef, "state.$dateKey must be empty or a valid YYYY-MM-DD date")
                if !PresenceSimulation_ValidDateString($loaded->{$dateKey});
        }

        for my $dev (sort keys %{$loaded->{activeSessions}}) {
            my $entry = $loaded->{activeSessions}{$dev};
            return (undef, "state.activeSessions.$dev must be an object") if ref $entry ne 'HASH';
            return (undef, "state.activeSessions.$dev.startedAt must be a non-negative number")
                if !looks_like_number($entry->{startedAt}) || $entry->{startedAt} < 0;
            return (undef, "state.activeSessions.$dev.date must be valid")
                if !PresenceSimulation_ValidDateString($entry->{date});
            return (undef, "state.activeSessions.$dev.weekday must be 0 through 6")
                if !PresenceSimulation_IsIntegerInRange($entry->{weekday}, 0, 6);
            return (undef, "state.activeSessions.$dev.startMinute must be 0 through 1439")
                if !PresenceSimulation_IsIntegerInRange($entry->{startMinute}, 0, 1439);
            return (undef, "state.activeSessions.$dev.weekday does not match its date")
                if int($entry->{weekday}) != PresenceSimulation_WeekdayForDate($entry->{date});
        }

        for my $dev (sort keys %{$loaded->{managed}}) {
            my $entry = $loaded->{managed}{$dev};
            return (undef, "state.managed.$dev must be an object") if ref $entry ne 'HASH';
            for my $key (qw(offDue durationMinutes)) {
                return (undef, "state.managed.$dev.$key must be a non-negative integer")
                    if !PresenceSimulation_IsIntegerInRange($entry->{$key}, 0, undef);
            }
            return (undef, "state.managed.$dev.durationMinutes must be at least 1")
                if $entry->{durationMinutes} < 1;
            for my $key (qw(reading onPattern offPattern offCommand modelType)) {
                return (undef, "state.managed.$dev.$key must be a non-empty scalar")
                    if ref $entry->{$key} || !defined $entry->{$key} || $entry->{$key} eq '';
            }
            if (exists $entry->{readingDevice}) {
                return (undef, "state.managed.$dev.readingDevice must be a non-empty scalar")
                    if ref $entry->{readingDevice}
                    || !defined $entry->{readingDevice}
                    || $entry->{readingDevice} eq '';
            }
            eval { qr/$entry->{onPattern}/ };
            return (undef, "state.managed.$dev.onPattern is not a valid regular expression") if $@;
            eval { qr/$entry->{offPattern}/ };
            return (undef, "state.managed.$dev.offPattern is not a valid regular expression") if $@;
            for my $flag (qw(stopping offEventEmitted offFailed)) {
                next if !exists $entry->{$flag};
                return (undef, "state.managed.$dev.$flag must be 0 or 1")
                    if !PresenceSimulation_IsIntegerInRange($entry->{$flag}, 0, 1);
            }
            for my $optional (qw(offRetryDue offAttempts)) {
                next if !exists $entry->{$optional};
                return (undef, "state.managed.$dev.$optional must be a non-negative integer")
                    if !PresenceSimulation_IsIntegerInRange($entry->{$optional}, 0, undef);
            }
            if (exists $entry->{offLastError}) {
                return (undef, "state.managed.$dev.offLastError must be a scalar")
                    if ref $entry->{offLastError};
            }
        }

        for my $dev (sort keys %{$loaded->{dryManaged}}) {
            my $entry = $loaded->{dryManaged}{$dev};
            return (undef, "state.dryManaged.$dev must be an object") if ref $entry ne 'HASH';
            for my $key (qw(offDue durationMinutes)) {
                return (undef, "state.dryManaged.$dev.$key must be a non-negative integer")
                    if !PresenceSimulation_IsIntegerInRange($entry->{$key}, 0, undef);
            }
            return (undef, "state.dryManaged.$dev.durationMinutes must be at least 1")
                if $entry->{durationMinutes} < 1;
            return (undef, "state.dryManaged.$dev.modelType must be a non-empty scalar")
                if ref $entry->{modelType}
                || !defined $entry->{modelType}
                || $entry->{modelType} eq '';
        }

        for my $binsKey (qw(playedBins dryPlayedBins)) {
            for my $date (sort keys %{$loaded->{$binsKey}}) {
                return (undef, "state.$binsKey date $date is invalid")
                    if !PresenceSimulation_ValidDateString($date);
                my $byDevice = $loaded->{$binsKey}{$date};
                return (undef, "state.$binsKey.$date must be an object")
                    if ref $byDevice ne 'HASH';
                for my $dev (sort keys %{$byDevice}) {
                    my $bins = $byDevice->{$dev};
                    return (undef, "state.$binsKey.$date.$dev must be an object")
                        if ref $bins ne 'HASH';
                    for my $bin (keys %{$bins}) {
                        return (undef, "state.$binsKey.$date.$dev bin $bin must be a non-negative integer")
                            if !PresenceSimulation_IsIntegerInRange($bin, 0, undef);
                        return (undef, "state.$binsKey.$date.$dev.$bin must be 0 or 1")
                            if !PresenceSimulation_IsIntegerInRange($bins->{$bin}, 0, 1);
                    }
                }
            }
        }

        for my $plansKey (qw(plannedBins dryPlannedBins)) {
            next if !exists $loaded->{$plansKey};
            for my $date (sort keys %{$loaded->{$plansKey}}) {
                return (undef, "state.$plansKey date $date is invalid")
                    if !PresenceSimulation_ValidDateString($date);
                my $byDevice = $loaded->{$plansKey}{$date};
                return (undef, "state.$plansKey.$date must be an object")
                    if ref $byDevice ne 'HASH';
                for my $dev (sort keys %{$byDevice}) {
                    my $bins = $byDevice->{$dev};
                    return (undef, "state.$plansKey.$date.$dev must be an object")
                        if ref $bins ne 'HASH';
                    for my $bin (sort keys %{$bins}) {
                        return (undef, "state.$plansKey.$date.$dev bin $bin must be a non-negative integer")
                            if !PresenceSimulation_IsIntegerInRange($bin, 0, undef);
                        my $plan = $bins->{$bin};
                        return (undef, "state.$plansKey.$date.$dev.$bin must be an object")
                            if ref $plan ne 'HASH';
                        for my $key (
                            qw(
                                plannedStartMinute durationMinutes historyStarts
                                historyDays historyPositionSamples createdAt
                            )
                        ) {
                            return (undef, "state.$plansKey.$date.$dev.$bin.$key must be a non-negative integer")
                                if !PresenceSimulation_IsIntegerInRange($plan->{$key}, 0, undef);
                        }
                        return (undef, "state.$plansKey.$date.$dev.$bin.plannedStartMinute must be 0 through 1439")
                            if $plan->{plannedStartMinute} > 1439;
                        return (undef, "state.$plansKey.$date.$dev.$bin.durationMinutes must be at least 1")
                            if $plan->{durationMinutes} < 1;
                        return (undef, "state.$plansKey.$date.$dev.$bin.historyDays must be at least 1")
                            if $plan->{historyDays} < 1;
                        for my $key (qw(probabilityHistorical probabilityEffective probabilityFactor)) {
                            return (undef, "state.$plansKey.$date.$dev.$bin.$key must be a non-negative number")
                                if !looks_like_number($plan->{$key}) || $plan->{$key} < 0;
                        }
                        return (undef, "state.$plansKey.$date.$dev.$bin.probabilityHistorical must not exceed 1")
                            if $plan->{probabilityHistorical} > 1;
                        return (undef, "state.$plansKey.$date.$dev.$bin.probabilityEffective must not exceed 1")
                            if $plan->{probabilityEffective} > 1;
                        return (undef, "state.$plansKey.$date.$dev.$bin.probabilityFactor must be greater than zero")
                            if $plan->{probabilityFactor} <= 0;
                        if (exists $plan->{blockNotified}) {
                            return (undef, "state.$plansKey.$date.$dev.$bin.blockNotified must be 0 or 1")
                                if !PresenceSimulation_IsIntegerInRange($plan->{blockNotified}, 0, 1);
                        }
                        return (undef, "state.$plansKey.$date.$dev.$bin.modelType must be a non-empty scalar")
                            if ref $plan->{modelType}
                            || !defined $plan->{modelType}
                            || $plan->{modelType} eq '';
                    }
                }
            }
        }

        for my $dev (sort keys %{$loaded->{expected}}) {
            my $entry = $loaded->{expected}{$dev};
            return (undef, "state.expected.$dev must be an object") if ref $entry ne 'HASH';
            return (undef, "state.expected.$dev.state must be on or off")
                if ($entry->{state} // '') !~ /^(?:on|off)$/;
            return (undef, "state.expected.$dev.until must be a non-negative integer")
                if !PresenceSimulation_IsIntegerInRange($entry->{until}, 0, undef);
        }
        for my $dev (sort keys %{$loaded->{manualLockUntil}}) {
            return (undef, "state.manualLockUntil.$dev must be a non-negative integer")
                if !PresenceSimulation_IsIntegerInRange($loaded->{manualLockUntil}{$dev}, 0, undef);
        }
    }
    else {
        return (undef, "unsupported persistence part $part");
    }

    return ($loaded, undef);
}

# Reads the main file and restores its backup if necessary.
sub PresenceSimulation_ReadJsonWithBackup {
    my ($hash, $part, $file) = @_;
    my ($loaded, $readError) = PresenceSimulation_ReadJsonFile($file);
    my ($validated, $validationError);
    if ($loaded) {
        ($validated, $validationError) = PresenceSimulation_ValidatePersistedData($hash, $part, $loaded);
        return ($validated, undef) if $validated;
    }

    my $mainError = $validationError || $readError || 'main file is unavailable';
    my $backup = "$file.bak";
    my ($backupData, $backupReadError) = PresenceSimulation_ReadJsonFile($backup);
    return (undef, $mainError) if !$backupData;

    my ($backupValidated, $backupValidationError) = PresenceSimulation_ValidatePersistedData($hash, $part, $backupData);
    if (!$backupValidated) {
        my $backupError = $backupValidationError || $backupReadError || 'backup is invalid';
        return (undef, "main file: $mainError; backup: $backupError");
    }

    if (-e $file) {
        my $corrupt = $file . '.corrupt.' . CORE::time();
        my $counter = 0;
        $corrupt .= '.' . ++$counter while -e $corrupt;
        return (undef, "cannot preserve invalid main file $file as $corrupt: $!")
            if !rename($file, $corrupt);
    }
    return (undef, "cannot restore $part backup $backup to $file: $!")
        if !copy($backup, $file);
    return (undef, "cannot restrict permissions for restored $part file $file: $!")
        if !chmod 0600, $file;

    PresenceSimulation_Log(
        $hash,
        2,
        "restored $part data from validated backup $backup; main error: $mainError"
    );
    return ($backupValidated, undef);
}

sub PresenceSimulation_LoadAll {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $files = PresenceSimulation_FileNames($hash);

    for my $part (qw(raw state)) {
        my ($loaded, $error) = PresenceSimulation_ReadJsonWithBackup($hash, $part, $files->{$part});
        if ($loaded) {
            $PresenceSimulation_DATA{$name}{$part} = $loaded;
            PresenceSimulation_Log($hash, 4, "loaded $part data from $files->{$part}");
        }
        elsif ($error && (-e $files->{$part} || -e "$files->{$part}.bak")) {
            PresenceSimulation_SetError($hash, "cannot load $part file: $error", 'persistence');
        }
        else {
            PresenceSimulation_Log($hash, 4, "$part file not found, using empty data structure");
        }
    }

    $PresenceSimulation_DATA{$name}{raw} = PresenceSimulation_EmptyRaw($name)
        if ref $PresenceSimulation_DATA{$name}{raw} ne 'HASH';
    $PresenceSimulation_DATA{$name}{model} = PresenceSimulation_EmptyModel($name);
    $PresenceSimulation_DATA{$name}{state} = PresenceSimulation_EmptyState($name)
        if ref $PresenceSimulation_DATA{$name}{state} ne 'HASH';

    PresenceSimulation_NormalizeInstanceData($hash);
    $PresenceSimulation_DATA{$name}{state}{lastCoverageTick} = CORE::time();
    return;
}


# Returns device-specific paths for the module data files.
sub PresenceSimulation_FileNames {
    my ($hash) = @_;
    return PresenceSimulation_FileNamesForName($hash->{NAME}, 1);
}

# Returns file names for an arbitrary device name, optionally creating the directory.
sub PresenceSimulation_FileNamesForName {
    my ($name, $createDirectory) = @_;
    my $safe = $name;
    $safe =~ s/[^A-Za-z0-9_.-]+/_/g;

    my $modpath = AttrVal('global', 'modpath', '.');
    my $dir = "$modpath/FHEM/FhemUtils";
    eval { make_path($dir) if $createDirectory && !-d $dir; 1 };

    return {
        raw   => "$dir/PresenceSimulation_Raw_$safe.json",
        state => "$dir/PresenceSimulation_State_$safe.json",
    };
}

# Writes a file atomically and creates a backup first.
sub PresenceSimulation_WriteFileAtomic {
    my ($file, $content) = @_;
    my $dir = dirname($file);
    eval { make_path($dir) if !-d $dir; 1 }
        or return "cannot create directory $dir: $@";

    my $tmp = "$file.tmp";
    my $bak = "$file.bak";
    my $error = FileWrite({ FileName => $tmp, ForceType => 'file', NoNL => 1 }, $content);
    return $error if $error;
    if (!chmod 0600, $tmp) {
        unlink $tmp;
        return "cannot restrict permissions for $tmp: $!";
    }

    if (-e $file) {
        if (!copy($file, $bak)) {
            unlink $tmp;
            return "backup copy $file to $bak failed: $!";
        }
        if (!chmod 0600, $bak) {
            unlink $tmp;
            return "cannot restrict permissions for $bak: $!";
        }
    }
    if (!rename($tmp, $file)) {
        unlink $tmp;
        return "rename $tmp to $file failed: $!";
    }
    return "cannot restrict permissions for $file: $!" if !chmod 0600, $file;
    return;
}

# Reads and decodes a JSON file.
sub PresenceSimulation_ReadJsonFile {
    my ($file) = @_;
    return (undef, undef) if !-e $file;

    my ($error, @content) = FileRead({ FileName => $file, ForceType => 'file' });
    return (undef, $error) if $error;

    my $decoded = eval { JSON::PP->new->decode(join('', @content)) };
    return (undef, $@) if $@;
    return ($decoded, undef);
}

# Formats a local timestamp consistently for readings, logs, and diagnostics.
sub PresenceSimulation_FormatDateTime {
    my ($epoch) = @_;
    return strftime('%Y-%m-%d %H:%M:%S', localtime($epoch));
}

# Formats a byte count with decimal units for diagnostics.
sub PresenceSimulation_FormatFileSize {
    my ($bytes) = @_;
    $bytes = int($bytes // 0);
    $bytes = 0 if $bytes < 0;
    return "$bytes B" if $bytes <= 1000;
    return sprintf('%.1f kB', $bytes / 1000) if $bytes < 1_000_000;
    return sprintf('%.1f MB', $bytes / 1_000_000) if $bytes < 1_000_000_000;
    return sprintf('%.1f GB', $bytes / 1_000_000_000);
}

# Converts an exception or command error into one log-friendly line.
sub PresenceSimulation_OneLineError {
    my ($message) = @_;
    $message //= '';
    $message =~ s/[\r\n]+/ /g;
    return $message;
}

# Creates an empty parsed configuration structure.
sub PresenceSimulation_EmptyConfig {
    return {
        byDevice        => {},
        byReadingDevice => {},
        order           => [],
        globalBlocks    => [],
        ready           => 0,
    };
}

# Creates the complete in-memory data frame for one module instance.
sub PresenceSimulation_NewInstanceData {
    my ($name) = @_;
    return {
        raw    => PresenceSimulation_EmptyRaw($name),
        model  => PresenceSimulation_EmptyModel($name),
        state  => PresenceSimulation_EmptyState($name),
        config => PresenceSimulation_EmptyConfig(),
        dirty  => {},
    };
}

# Creates one empty raw calendar day.
sub PresenceSimulation_EmptyRawDay {
    my ($date) = @_;
    return {
        weekday        => PresenceSimulation_WeekdayForDate($date),
        trainingSeconds  => 0,
        discardedSessions => 0,
        sessions          => {},
    };
}

# Creates an empty raw-data structure.
sub PresenceSimulation_EmptyRaw {
    my ($name) = @_;
    return {
        schemaVersion => $PRESENCE_SIM_SCHEMA,
        moduleVersion => $PRESENCE_SIM_VERSION,
        deviceName    => $name,
        days          => {},
    };
}

# Creates an empty model structure.
sub PresenceSimulation_EmptyModel {
    my ($name) = @_;
    return {
        schemaVersion         => $PRESENCE_SIM_SCHEMA,
        moduleVersion         => $PRESENCE_SIM_VERSION,
        deviceName            => $name,
        createdAt             => 0,
        binMinutes            => 15,
        trainingDaysRequested  => 30,
        retentionDaysConfigured => 90,
        retentionDaysEffective  => 90,
        weekdaySpecific       => 0,
        trainingSource        => 'events',
        dbLogDevice           => '',
        sourceDays            => { events => 0, dblog => 0 },
        validDates            => [],
        allDays               => { validDates => [], devices => {}, deviceTotals => {}, sessionCount => 0 },
        weekdays              => {},
        deviceTotals          => {},
        sessionCount          => 0,
    };
}

# Creates an empty persistent runtime-state structure.
sub PresenceSimulation_EmptyState {
    my ($name) = @_;
    return {
        schemaVersion    => $PRESENCE_SIM_SCHEMA,
        moduleVersion    => $PRESENCE_SIM_VERSION,
        deviceName       => $name,
        mode             => 'off',
        currentDate      => PresenceSimulation_Date(CORE::time()),
        lastCoverageTick => CORE::time(),
        lastDbLogImportDate => '',
        autoImportFailures => 0,
        autoImportRetryAt  => 0,
        coverageDate     => '',
        coverageSeconds  => 0,
        discardedSessions => 0,
        importInfo       => { state => 'idle' },
        activeSessions   => {},
        managed          => {},
        dryManaged       => {},
        expected         => {},
        manualLockUntil  => {},
        playedBins       => {},
        dryPlayedBins    => {},
        plannedBins      => {},
        dryPlannedBins   => {},
    };
}

# Returns the weekday of a timestamp as 0=Sunday through 6=Saturday.
sub PresenceSimulation_WeekdayIndex {
    my ($epoch) = @_;
    my @lt = localtime($epoch);
    return $lt[6];
}

# Determines the local weekday for a date in YYYY-MM-DD format.
sub PresenceSimulation_WeekdayForDate {
    my ($date) = @_;
    return 0 if !defined $date || $date !~ /^(\d{4})-(\d{2})-(\d{2})$/;
    my ($year, $month, $day) = ($1, $2, $3);
    my $epoch = mktime(0, 0, 12, $day, $month - 1, $year - 1900);
    return PresenceSimulation_WeekdayIndex($epoch);
}

# Returns the German name for a weekday index.
sub PresenceSimulation_WeekdayName {
    my ($weekday) = @_;
    my @names = qw(Sonntag Montag Dienstag Mittwoch Donnerstag Freitag Samstag);
    return defined $weekday && $weekday >= 0 && $weekday <= 6 ? $names[$weekday] : 'Unbekannt';
}

# Parses German, English, or numeric weekday input.
sub PresenceSimulation_ParseWeekday {
    my ($value) = @_;
    return undef if !defined $value;
    return int($value) if $value =~ /^[0-6]$/;

    my %map = (
        sonntag => 0, sunday => 0, so => 0, sun => 0,
        montag => 1, monday => 1, mo => 1, mon => 1,
        dienstag => 2, tuesday => 2, di => 2, tue => 2,
        mittwoch => 3, wednesday => 3, mi => 3, wed => 3,
        donnerstag => 4, thursday => 4, do => 4, thu => 4,
        freitag => 5, friday => 5, fr => 5, fri => 5,
        samstag => 6, saturday => 6, sa => 6, sat => 6,
    );
    return $map{lc($value)};
}

# Converts a local SQL timestamp into an epoch value.
sub PresenceSimulation_EpochFromDateTime {
    my ($value) = @_;
    return undef if !defined $value;
    return undef if $value !~ /^(\d{4})-(\d{2})-(\d{2})[ T_](\d{2}):(\d{2}):(\d{2})/;
    my ($year, $month, $day, $hour, $minute, $second) = ($1, $2, $3, $4, $5, $6);
    my $epoch = eval { mktime($second, $minute, $hour, $day, $month - 1, $year - 1900) };
    return $@ ? undef : $epoch;
}

# Formats a timestamp as a local ISO date.
sub PresenceSimulation_Date {
    my ($epoch) = @_;
    return strftime('%Y-%m-%d', localtime($epoch));
}

# Calculates the local minute since midnight.
sub PresenceSimulation_MinuteOfDay {
    my ($epoch) = @_;
    my @lt = localtime($epoch);
    return ($lt[2] * 60) + $lt[1];
}

# Returns the dates of previous calendar days.
sub PresenceSimulation_PreviousDates {
    my ($count) = @_;
    my @lt = localtime(CORE::time());
    my $noon = mktime(0, 0, 12, $lt[3], $lt[4], $lt[5]);
    my @dates;
    for my $offset (1 .. $count) {
        push @dates, PresenceSimulation_Date($noon - ($offset * 86400));
    }
    return @dates;
}

# Logs an error and updates the error reading.
sub PresenceSimulation_SetError {
    my ($hash, $message, $source) = @_;
    $source //= 'general';
    PresenceSimulation_Log($hash, 1, $message);
    my $name = $hash->{NAME};
    return if ReadingsVal($name, 'lastError', '') eq $message
        && ReadingsVal($name, 'lastErrorSource', '') eq $source;

    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, 'lastError', $message);
    readingsBulkUpdate($hash, 'lastErrorSource', $source);
    readingsBulkUpdate($hash, 'lastErrorTime', PresenceSimulation_FormatDateTime(CORE::time()));
    readingsEndUpdate($hash, 1);
    return;
}
1;

=pod

=encoding utf8

=item helper
=item summary Learns device switching behaviour and simulates presence
=item summary_DE Lernt Geräteschaltverhalten und simuliert Anwesenheit

=begin html

<a id="PresenceSimulation"></a>
<h3>PresenceSimulation</h3>
<p>
PresenceSimulation learns completed on/off sessions of configured devices and
creates a rolling probability model. The model can be played back with real
commands or evaluated virtually in dry-run mode. Training data can come from
live FHEM events, retained DbLog imports, or both. The selected training source
controls ongoing acquisition, while the model uses the shared retained history.
</p>

<a id="PresenceSimulation-define"></a>
<h4>Define</h4>
<p>
  <code>define &lt;name&gt; PresenceSimulation</code><br><br>
  Example:<br>
  <code>define PresenceSimulation PresenceSimulation</code>
</p>

<a id="PresenceSimulation-basic-setup"></a>
<h4>Basic setup</h4>
<p>PresenceSimulation needs at least one valid <code>deviceNN</code> attribute and
training data from live events, DbLog, or both.</p>

<p><b>Event-based training with standard on/off devices</b></p>
<pre>define PresenceSimulation PresenceSimulation
attr PresenceSimulation device01 device=Light_Kitchen</pre>
<p>With this minimal configuration, the defaults are
<code>trainingSource=events</code>, <code>mode=off</code>,
<code>onCommand=on</code>, <code>offCommand=off</code>,
<code>reading=state</code>, <code>readingDevice=device</code>,
<code>onRegex=^on$</code>, and <code>offRegex=^off$</code>. The command device
must exist. By default, its own reading is also used for live observation,
playback feedback, and DbLog imports.</p>
<p>If switching and observation belong to different FHEM devices, set the optional
<code>readingDevice</code>. Commands are still sent to <code>device</code>, while
state detection and DbLog queries use <code>readingDevice</code> and
<code>reading</code>. Sessions and model data remain stored under the logical
<code>device</code> name:</p>
<pre>attr PresenceSimulation device17 device=DOIF_PresenceSimulation_TV onCommand=cmd_1 offCommand=cmd_2 reading=state readingDevice=KODI onRegex=(?i:^(opened|connected)$) offRegex=(?i:^disconnected$)</pre>
<p>By default, an event-trained calendar day becomes usable only after
<code>minTrainingMinutes=1200</code> minutes of coverage, and only completed
previous calendar days are used by the model. A newly created event-training
instance therefore does not provide a useful model immediately. Start live training explicitly with:</p>
<pre>set PresenceSimulation mode training</pre>

<p><b>Quick start with existing DbLog history</b></p>
<pre>define PresenceSimulation PresenceSimulation
attr PresenceSimulation device01 device=Light_Kitchen
attr PresenceSimulation dbLogDevice DbLog
set PresenceSimulation importDbLog 30
get PresenceSimulation importInfo
get PresenceSimulation modelInfo
set PresenceSimulation mode dryrun</pre>
<p>A manual import is available while <code>trainingSource=events</code> remains
active. To disable live event training and enable the daily automatic DbLog
import, set <code>dbLogDevice</code> first and then use:</p>
<pre>attr PresenceSimulation trainingSource dblog</pre>
<p>Before enabling real playback, verify the imported or learned model with
<code>get &lt;name&gt; modelInfo</code> and test it with
<code>set &lt;name&gt; mode dryrun</code>. Blocking conditions,
<code>eventFn</code>, weekday-specific models, and probability adjustments are
optional.</p>

<a id="PresenceSimulation-set"></a>
<h4>Set</h4>
<ul>
  <li><code>mode training|playback|dryrun|off</code><br>
      Selects the operating mode. <code>training</code> records real events when
      <code>trainingSource=events</code>. <code>playback</code> sends real device
      commands. <code>dryrun</code> creates virtual switch events without sending
      commands. Both modes publish <code>simulationEvent</code>. <code>off</code> disables event training and simulation; scheduled DbLog acquisition remains controlled by <code>trainingSource</code> and the disable attributes.</li>
  <li><code>save</code><br>Writes raw data and runtime state immediately. The probability model is rebuilt from raw data.</li>
  <li><code>rebuildModel</code><br>Rebuilds the probability model from retained raw data.</li>
  <li><code>importDbLog [days]</code><br>Starts a nonblocking manual import from the
      device configured in <code>dbLogDevice</code>. It is available with both
      training sources. Without <code>days</code>, <code>retentionDays</code> is used.
      For every requested completed day, reconstructed DbLog sessions replace the
      retained raw sessions for that day. Each device configuration is queried by
      its <code>readingDevice</code> and <code>reading</code>; the reconstructed
      sessions are assigned to the logical <code>device</code>. Database credentials
      are passed to the worker through a randomized mode-0600 parameter file and are
      not included in the visible <code>BlockingCall</code> argument.</li>
  <li><code>resetTrainingData confirm</code><br>Deletes all collected and imported
      training data and rebuilds an empty model.</li>
</ul>

<a id="PresenceSimulation-get"></a>
<h4>Get</h4>
<ul>
  <li><code>modelInfo</code><br>Shows model type, training window, retained days,
      usable event and DbLog day counts, session counts, weekday statistics, and
      separate observation sources where configured.</li>
  <li><code>importInfo</code><br>Shows details of the latest DbLog import.</li>
  <li><code>fileInfo</code><br>Shows paths, human-readable decimal file sizes, and
      modification times of the raw-data and runtime-state JSON files. Sizes up to
      1000 bytes use <code>B</code>; larger values use <code>kB</code>, <code>MB</code>,
      or <code>GB</code>.</li>
  <li><code>probability &lt;device&gt; &lt;HH:MM&gt; [weekday]</code><br>Shows the
      historical block probability, configured factor, effective block probability,
      number of days with a start, and number of retained historical start positions
      for one configured device. The optional weekday can be a number, abbreviation,
      or English/German weekday name.</li>
</ul>

<a id="PresenceSimulation-probability-model"></a>
<h4>Probability model</h4>
<p>For every configured device and time block, the model calculates the historical
probability as the number of usable training days with at least one start in that
block divided by all usable training days. <code>probabilityFactor</code> is applied
once to this block probability and the result is limited to 100&nbsp;%.</p>
<p>Dry-run and playback make exactly one decision for each device/time-block pair.
A miss consumes the block without further draws. A hit creates one pending plan.
Its start minute is sampled from the retained historical positions inside the block;
when simulation begins after all retained positions, a minute from the remaining
part of the block is selected. The duration is sampled from the historical durations
of the block, with the device-wide duration list as fallback. Pending plans are
stored in runtime state, so saving or reloading does not repeat the block decision.
Blocking conditions are evaluated after the plan is due. The first active block
emits one <code>action=blocked</code> event with <code>pending=1</code> and the current
block boundary as <code>retryUntil=HH:MM</code>. The plan remains pending and the
conditions are checked again on every simulation tick until the block ends. If the
block clears, the plan starts and the following <code>action=on</code> event includes
<code>started=HH:MM</code> and <code>delayed=Nmin</code>. The delay is subtracted from
its sampled duration so that the originally planned end time is preserved. If less
than one full minute remains, the plan expires without switching or another event.
If the block remains active through the boundary, the plan expires without a second
blocked event. In real
playback, unknown, already-on, or manually locked device states also delay the attempt
within the current block without causing a new probability decision.</p>
<p>This block model intentionally permits at most one simulated start per device and
time block. It does not preserve the complete daily number or sequence of sessions.</p>

<a id="PresenceSimulation-attr"></a>
<h4>Attributes</h4>
<ul>
  <li><code>deviceNN</code><br>Configures one logical device, numbered 01 through 30. Syntax:
      <code>device=&lt;device&gt; [onCommand=on] [offCommand=off] [reading=state] [readingDevice=&lt;device&gt;]
      [onRegex=^on$] [offRegex=^off$] [minDuration=1] [maxDuration=240]</code>.
      <code>device</code> is the command target, model key, and device name used in
      <code>simulationEvent</code>. <code>onCommand</code> and
      <code>offCommand</code> are sent to this device. The optional
      <code>readingDevice</code> supplies live events, current playback feedback,
      and DbLog history; it defaults to <code>device</code>. <code>reading</code>
      and the regular expressions are always evaluated on that observation device.
      <code>minDuration</code> must be at least 1 minute; <code>maxDuration</code>
      must be between <code>minDuration</code> and 1440 minutes. Values containing
      spaces must be quoted.</li>
  <li><code>deviceNNBlockMM</code><br>Optional blocking conditions 01 through 10 for
      device NN. Example: <code>[Blind_Kitchen:state] eq "down"</code>. Multiple
      blocks are OR-connected. Within one block, <code>&amp;&amp;</code>, <code>||</code>,
      parentheses, numeric comparisons, string comparisons, and regex operators
      are supported.</li>
  <li><code>globalBlockNN</code><br>Optional global blocking conditions 01 through 20.
      Example: <code>[Weather:brightness] &gt; 300</code>.</li>
  <li><code>trainingSource events|dblog</code><br>Controls ongoing data acquisition,
      not selection of retained model data. In both modes the model uses sufficiently
      covered event days together with retained imported DbLog days. Default:
      <code>events</code>. Event mode records live events and performs DbLog imports only
      when requested manually. DbLog mode records no live sessions and additionally
      enables the daily automatic import. DbLog mode requires an explicitly configured
      <code>dbLogDevice</code>.</li>
  <li><code>dbLogDevice</code><br>Name of the DbLog device used for manual or automatic
      imports. Required for <code>importDbLog</code> in either training mode and for
      <code>trainingSource=dblog</code>. No default.</li>
  <li><code>importTime</code><br>Daily automatic DbLog import time in HH:MM format.
      Used only with <code>trainingSource=dblog</code>. Default: <code>03:05</code>.</li>
  <li><code>trainingDays</code><br>Number of completed calendar days used by the model.
      Range 1 through 90, default 30.</li>
  <li><code>retentionDays</code><br>Number of completed calendar days retained in raw
      data. Range 1 through 365, default 90. The effective value is never lower
      than <code>trainingDays</code>.</li>
  <li><code>binMinutes</code><br>Model time-bin size: 1, 5, 10, 15, 20, 30, or 60 minutes.
      Default 15.</li>
  <li><code>minTrainingMinutes</code><br>Minimum event-training coverage for a day to be
      valid. Range 0 through 1440, default 1200.</li>
  <li><code>saveInterval</code><br>Delay for batched persistence in seconds. Range 30
      through 1800, default 300.</li>
  <li><code>manualLockMinutes</code><br>Lock time after a manual intervention during
      playback. Range 0 through 1440, default 120.</li>
  <li><code>probabilityFactor</code><br>Multiplier applied once to each historical
      block probability. The effective value is limited to 100&nbsp;%. A change affects
      block decisions that have not yet been planned; an existing pending plan keeps
      the factor with which it was created. Range 0.1 through 3.0, default 1.0.</li>
  <li><code>weekdaySpecific 0|1</code><br>Uses one model for all days (0, default) or
      separate models for each weekday (1).</li>
  <li><code>eventFn</code><br>Optional handler executed for every
      <code>simulationEvent</code>. The attribute directly contains a FHEM command,
      command chain, or Perl block. The available placeholders are deliberately
      limited to <code>$NAME</code>, <code>$MODE</code>, <code>$DEVICE</code>,
      <code>$ACTION</code>, <code>$EVENT</code>, and <code>$EVENTDETAILS</code>.
      <code>$EVENT</code> contains the complete event text. <code>$EVENTDETAILS</code>
      contains all remaining key/value details, including timestamp, duration,
      probabilities, history, model, and the matching blocking-condition name when
      available. Block expressions and observed values are deliberately kept out of the
      event text and remain available in the FHEM log. Placeholder expansion is
      command-neutral; the called FHEM command is responsible for its own
      quoting and parameter syntax. For the FHEM <code>msg</code> command, pass the event
      explicitly as <code>msgText</code> and protect the leading year with an empty
      <code>msgPrio</code> parameter.<br><br>
      A function from <code>99_myUtils.pm</code> can be called explicitly from a
      Perl block. The handler runs synchronously and should return quickly. Errors
      are caught and reported through <code>lastError</code> with source
      <code>eventFn</code>.</li>
  <li><code>eventFnEnabled 0|1</code><br>Controls execution of a configured
      <code>eventFn</code>. The default is 1. Value 0 keeps the complete handler
      attribute stored but suppresses its execution; <code>simulationEvent</code>
      continues to be published unchanged. Changes take effect with the next event
      and do not rebuild or reset plans. Deleting the attribute restores the default
      value 1. Disabling clears an existing error whose source is
      <code>eventFn</code>.</li>
  <li><code>disable 0|1</code>, <code>disabledForIntervals</code><br>Use the standard FHEM disable controls. Managed playback devices are switched off when the disabled state becomes active.</li>
</ul>

<p>Inline command example:</p>
<pre>attr PresenceSimulation eventFn msg @Bewohner msgPrio="" msgText="$EVENT"</pre>
<p>Perl block calling a function from <code>99_myUtils.pm</code>:</p>
<pre>attr PresenceSimulation eventFn { myPresenceSimulationEvent("$MODE", "$DEVICE", "$ACTION", "$EVENTDETAILS") }</pre>
<pre>sub myPresenceSimulationEvent {
    my ($mode, $device, $action, $eventDetails) = @_;
    fhem("msg \@Bewohner $device: $action ($mode) $eventDetails");
    return;
}</pre>

<a id="PresenceSimulation-readings"></a>
<h4>Readings</h4>
<ul>
  <li><code>state</code>, <code>mode</code>: current operating mode.</li>
  <li><code>activeTraining</code>: currently open real training sessions.</li>
  <li><code>activePlayback</code>: devices currently managed by real playback.</li>
  <li><code>stoppingPlayback</code>: devices currently waiting for OFF confirmation
      or another bounded automatic OFF attempt.</li>
  <li><code>activeDryRun</code>: currently active virtual sessions.</li>
  <li><code>simulationEvent</code>: event-generating on, off, or blocked action from
      dry-run or real playback. The value contains a <code>mode=</code> field. Planned
      on/blocked events additionally include historical <code>pHistorical</code>,
      effective <code>pBlock</code>, <code>factor</code>, planned start time, history,
      and start-position sample count. The first blocked event also contains
      <code>pending=1</code> and <code>retryUntil=HH:MM</code>. If the block later clears
      within the same time block, the resulting on event adds <code>started=HH:MM</code>
      and <code>delayed=Nmin</code>; its <code>duration</code> is reduced by that delay so
      the originally planned end time is retained. If less than one minute remains,
      the plan expires without an on event. A blocked event contains
      <code>condition=&lt;attribute&gt;</code>; <code>reason=evaluationError</code> is added
      only when the condition could not be evaluated. The full expression and observed
      values are written to the log, and evaluation failures use
      <code>lastErrorSource=blockCondition</code>.</li>
  <li><code>lastEvent</code>: last processed device event; updated without generating an event.</li>
  <li><code>configuredDevices</code>: number of valid configured devices.</li>
  <li><code>rawSessions</code>: total number of completed on/off sessions retained
      across all configured devices and calendar days. A raw session starts with
      a recognized on transition and ends with the corresponding off transition.
      Its start time and duration are stored before the data is aggregated into
      the probability model.</li>
  <li><code>rawSessionsToday</code>: number of completed raw sessions recorded for
      the current raw-data calendar day. A device that is still on is not counted until
      a matching off transition completes the session.</li>
  <li><code>rawSessionsTodayDiscarded</code>: number of event-training sessions assigned
      to the current raw-data calendar day that were discarded because their rounded
      duration was outside the configured <code>minDuration</code>/<code>maxDuration</code>
      range.</li>
  <li><code>rawDays</code>: number of calendar-day records retained in the raw-data
      store. A retained day can contain no completed session, for example when
      event-training coverage was recorded but no configured device was switched.</li>
  <li><code>modelSessions</code>, <code>trainingDaysUsed</code>,
      <code>effectiveTrainingDays</code>, <code>modelCreated</code>: active model status.</li>
  <li><code>importState</code>, <code>nextDbLogImport</code>: DbLog import status.</li>
  <li><code>lastError</code>, <code>lastErrorSource</code>, <code>lastErrorTime</code>:
      latest subsystem-specific error. All three readings are <code>none</code>
      when no error is active.</li>
</ul>

<a id="PresenceSimulation-notes"></a>
<h4>Notes</h4>
<ul>
  <li>Changing device or model attributes while real playback owns devices is rejected. Set the module to <code>off</code> and wait until <code>stoppingPlayback</code> is 0 before changing those attributes.</li>
  <li>An unresolved OFF request is attempted at most three times: immediately,
      after one minute, and after another five minutes. If OFF is still not
      confirmed after the final grace period, no further automatic command is
      sent and the device is released from playback management without claiming
      that it is physically off. The failure remains visible through
      <code>lastError</code> with source <code>playback</code> until a later successful
      playback ON action clears it or another error supersedes it. Future playback
      still sends ON only when the observed device state is unambiguously OFF.</li>
  <li>Changing <code>trainingSource</code> does not delete or hide retained raw
      data. In both modes, imported DbLog days and sufficiently covered event days
      remain eligible for the model. The currently configured <code>dbLogDevice</code>
      controls future imports but does not invalidate imports retained from another
      DbLog device. Automatic imports are still scheduled only in DbLog mode.</li>
  <li>Persistent data is stored below <code>FHEM/FhemUtils</code> in separate
      raw-data and runtime-state JSON files. The probability model is rebuilt in
      memory from raw data after startup and configuration changes. The files are
      named <code>PresenceSimulation_Raw_&lt;name&gt;.json</code> and
      <code>PresenceSimulation_State_&lt;name&gt;.json</code>; they follow the FHEM
      device name and are moved automatically when the definition is renamed.
      Permanently deleting the FHEM definition also deletes its data files.</li>
  <li>FHEMWEB uses the internal default <code>devStateIcon</code> mapping
      <code>off:rc_STOP training:rc_REC dryrun:rc_PLAY playback:rc_PLAYgreen</code>.
      It is not written as an attribute and can be overridden with a normal
      device-specific <code>devStateIcon</code> attribute.</li>
</ul>

=end html

=begin html_DE

<a id="PresenceSimulation"></a>
<h3>PresenceSimulation &ndash; Anwesenheitssimulation</h3>
<p>
PresenceSimulation lernt abgeschlossene Ein-/Ausschaltvorg&auml;nge der
konfigurierten Ger&auml;te und erzeugt daraus ein rollierendes
Wahrscheinlichkeitsmodell. Das Modell kann mit echten Schaltbefehlen abgespielt
oder im Dry-Run-Modus rein virtuell ausgewertet werden. Die Trainingsdaten
k&ouml;nnen aus laufenden FHEM-Events, aus beibehaltenen DbLog-Importen oder aus
beiden Quellen stammen. Die gew&auml;hlte Trainingsquelle steuert die laufende
Erfassung, w&auml;hrend das Modell den gemeinsamen gespeicherten Datenbestand nutzt.
</p>

<a id="PresenceSimulation-define"></a>
<h4>Define</h4>
<p>
  <code>define &lt;Name&gt; PresenceSimulation</code><br><br>
  Beispiel:<br>
  <code>define PresenceSimulation PresenceSimulation</code>
</p>

<a id="PresenceSimulation-basic-setup"></a>
<h4>Grundkonfiguration</h4>
<p>PresenceSimulation ben&ouml;tigt mindestens ein g&uuml;ltiges
<code>deviceNN</code>-Attribut sowie Trainingsdaten aus Live-Events, DbLog oder
beiden Quellen.</p>

<p><b>Event-basiertes Training mit normalen Ein-/Aus-Ger&auml;ten</b></p>
<pre>define PresenceSimulation PresenceSimulation
attr PresenceSimulation device01 device=Licht_Kueche</pre>
<p>Bei dieser Minimalkonfiguration gelten die Standardwerte
<code>trainingSource=events</code>, <code>mode=off</code>,
<code>onCommand=on</code>, <code>offCommand=off</code>,
<code>reading=state</code>, <code>readingDevice=device</code>,
<code>onRegex=^on$</code> und <code>offRegex=^off$</code>. Das Schalt-Device muss
existieren. Standardm&auml;&szlig;ig wird dessen eigenes Reading auch f&uuml;r
Live-Beobachtung, Playback-R&uuml;ckmeldung und DbLog-Import verwendet.</p>
<p>Liegen Schalten und Zustandserkennung auf unterschiedlichen FHEM-Devices, kann
optional <code>readingDevice</code> gesetzt werden. Befehle werden weiterhin an
<code>device</code> gesendet; Zustandserkennung und DbLog-Abfragen verwenden
<code>readingDevice</code> und <code>reading</code>. Sessions und Modelldaten
bleiben unter dem logischen Namen aus <code>device</code> gespeichert:</p>
<pre>attr PresenceSimulation device17 device=DOIF_PresenceSimulation_TV onCommand=cmd_1 offCommand=cmd_2 reading=state readingDevice=KODI onRegex=(?i:^(opened|connected)$) offRegex=(?i:^disconnected$)</pre>
<p>Standardm&auml;&szlig;ig wird ein per Event trainierter Kalendertag erst nach
<code>minTrainingMinutes=1200</code> Minuten erfasster Trainingszeit nutzbar.
Au&szlig;erdem verwendet das Modell nur abgeschlossene vorherige Kalendertage. Eine
neu angelegte Event-Trainingsinstanz besitzt deshalb nicht sofort ein nutzbares
Modell. Das Live-Training wird ausdr&uuml;cklich gestartet mit:</p>
<pre>set PresenceSimulation mode training</pre>

<p><b>Schnellstart mit vorhandener DbLog-Historie</b></p>
<pre>define PresenceSimulation PresenceSimulation
attr PresenceSimulation device01 device=Licht_Kueche
attr PresenceSimulation dbLogDevice DbLog
set PresenceSimulation importDbLog 30
get PresenceSimulation importInfo
get PresenceSimulation modelInfo
set PresenceSimulation mode dryrun</pre>
<p>Ein manueller Import ist m&ouml;glich, w&auml;hrend
<code>trainingSource=events</code> aktiv bleibt. Um das Live-Event-Training
auszuschalten und den t&auml;glichen automatischen DbLog-Import zu aktivieren,
zuerst <code>dbLogDevice</code> setzen und danach:</p>
<pre>attr PresenceSimulation trainingSource dblog</pre>
<p>Vor echtem Playback sollte das importierte oder gelernte Modell mit
<code>get &lt;Name&gt; modelInfo</code> gepr&uuml;ft und mit
<code>set &lt;Name&gt; mode dryrun</code> getestet werden. Sperrbedingungen,
<code>eventFn</code>, Wochentagsmodelle und Wahrscheinlichkeitsanpassungen sind
optional.</p>

<a id="PresenceSimulation-set"></a>
<h4>Set</h4>
<ul>
  <li><code>mode training|playback|dryrun|off</code><br>
      W&auml;hlt die Betriebsart. <code>training</code> zeichnet reale Events auf,
      wenn <code>trainingSource=events</code> gesetzt ist. <code>playback</code>
      sendet echte Ger&auml;tebefehle. <code>dryrun</code> erzeugt virtuelle
      Schalt-Events, ohne Befehle zu senden. Beide Betriebsarten ver&ouml;ffentlichen
      <code>simulationEvent</code>. <code>off</code> beendet Training
      und Simulation.</li>
  <li><code>save</code><br>Schreibt Rohdaten und Laufzeitstatus sofort. Das Wahrscheinlichkeitsmodell wird aus den Rohdaten neu aufgebaut.</li>
  <li><code>rebuildModel</code><br>Erzeugt das Wahrscheinlichkeitsmodell aus den
      gespeicherten Rohdaten neu.</li>
  <li><code>importDbLog [Tage]</code><br>Startet einen nichtblockierenden Import aus
      dem in <code>dbLogDevice</code> konfigurierten Device. Der Befehl ist bei
      beiden Trainingsquellen verf&uuml;gbar. Ohne Tagesangabe wird
      <code>retentionDays</code> verwendet. F&uuml;r jeden angeforderten abgeschlossenen
      Tag ersetzen die aus DbLog rekonstruierten Sessions die gespeicherten
      Rohsessions dieses Tages. Jede Ger&auml;tekonfiguration wird anhand von
      <code>readingDevice</code> und <code>reading</code> abgefragt; die
      rekonstruierten Sessions werden dem logischen <code>device</code> zugeordnet.
      Datenbank-Zugangsdaten werden dem Worker &uuml;ber eine zuf&auml;llig benannte
      Parameterdatei mit Rechten 0600 &uuml;bergeben und stehen nicht im sichtbaren
      <code>BlockingCall</code>-Argument.</li>
  <li><code>resetTrainingData confirm</code><br>L&ouml;scht alle gesammelten und
      importierten Trainingsdaten und erzeugt ein leeres Modell.</li>
</ul>

<a id="PresenceSimulation-get"></a>
<h4>Get</h4>
<ul>
  <li><code>modelInfo</code><br>Zeigt Modelltyp, Trainingsfenster, gespeicherte Tage,
      nutzbare Event- und DbLog-Tage, Sitzungszahlen, Wochentagsstatistik und
      gegebenenfalls getrennte Beobachtungs-Devices.</li>
  <li><code>importInfo</code><br>Zeigt Details des letzten DbLog-Imports.</li>
  <li><code>fileInfo</code><br>Zeigt Pfade, menschenlesbare dezimale Dateigr&ouml;&szlig;en
      und &Auml;nderungszeiten der JSON-Dateien f&uuml;r Rohdaten und Laufzeitstatus. Bis
      einschlie&szlig;lich 1000 Byte wird <code>B</code> verwendet, dar&uuml;ber
      <code>kB</code>, <code>MB</code> oder <code>GB</code>.</li>
  <li><code>probability &lt;Device&gt; &lt;HH:MM&gt; [Wochentag]</code><br>Zeigt die
      historische Blockwahrscheinlichkeit, den konfigurierten Faktor, die wirksame
      Blockwahrscheinlichkeit, die Zahl der Tage mit einem Start und die Zahl der
      gespeicherten historischen Startpositionen f&uuml;r ein konfiguriertes Ger&auml;t.
      Der optionale Wochentag kann als Zahl, Abk&uuml;rzung oder deutscher/englischer
      Name angegeben werden.</li>
</ul>

<a id="PresenceSimulation-probability-model-de"></a>
<h4>Wahrscheinlichkeitsmodell</h4>
<p>F&uuml;r jedes konfigurierte Ger&auml;t und jeden Zeitblock berechnet das Modell die
historische Wahrscheinlichkeit als Anzahl nutzbarer Trainingstage mit mindestens
einem Start in diesem Block geteilt durch alle nutzbaren Trainingstage.
<code>probabilityFactor</code> wird einmal auf diese Blockwahrscheinlichkeit
angewendet; das Ergebnis wird auf 100&nbsp;% begrenzt.</p>
<p>Dry Run und Playback treffen f&uuml;r jede Kombination aus Ger&auml;t und Zeitblock
genau eine Entscheidung. Ein Fehlschlag verbraucht den Block ohne weitere Ziehung.
Ein Treffer erzeugt genau einen ausstehenden Plan. Dessen Startminute wird aus den
gespeicherten historischen Positionen innerhalb des Blocks gezogen. Beginnt die
Simulation erst nach allen gespeicherten Positionen, wird eine Minute aus dem
verbleibenden Teil des Blocks gew&auml;hlt. Die Dauer wird aus den historischen
Dauern des Blocks gezogen; ersatzweise werden alle Dauern des Ger&auml;ts verwendet.
Ausstehende Pl&auml;ne werden im Laufzeitstatus gespeichert, sodass Speichern oder
Neuladen die Blockentscheidung nicht wiederholt. Blockbedingungen werden ausgewertet,
sobald der Plan f&auml;llig ist. Die erste aktive Sperre erzeugt genau ein
<code>action=blocked</code>-Ereignis mit <code>pending=1</code> und dem Ende des
aktuellen Zeitblocks als <code>retryUntil=HH:MM</code>. Der Plan bleibt bestehen und
die Bedingungen werden bei jedem Simulationstick bis zum Blockende erneut gepr&uuml;ft.
F&auml;llt die Sperre weg, wird der Plan ausgef&uuml;hrt; das folgende
<code>action=on</code>-Ereignis enth&auml;lt <code>started=HH:MM</code> und
<code>delayed=Nmin</code>. Die Verz&ouml;gerung wird von der gezogenen Dauer abgezogen,
sodass der urspr&uuml;nglich geplante Endzeitpunkt erhalten bleibt. Ist weniger als
eine volle Minute Restdauer vorhanden, verf&auml;llt der Plan ohne Einschalten und ohne
weiteres Ereignis. Bleibt die Sperre bis zum Blockende aktiv, verf&auml;llt der Plan ohne
ein zweites blocked-Ereignis. Beim echten Playback verschieben ein
unbekannter, bereits eingeschalteter oder manuell gesperrter Ger&auml;tezustand den
Versuch innerhalb des aktuellen Blocks ebenfalls, ohne eine neue
Wahrscheinlichkeitsentscheidung auszul&ouml;sen.</p>
<p>Dieses Blockmodell erlaubt bewusst h&ouml;chstens einen simulierten Start je Ger&auml;t
und Zeitblock. Die vollst&auml;ndige t&auml;gliche Anzahl oder Reihenfolge der Sessions
wird dadurch nicht erhalten.</p>

<a id="PresenceSimulation-attr"></a>
<h4>Attribute</h4>
<ul>
  <li><code>deviceNN</code><br>Konfiguriert ein logisches Ger&auml;t, nummeriert von 01 bis 30. Syntax:
      <code>device=&lt;Ger&auml;t&gt; [onCommand=on] [offCommand=off] [reading=state] [readingDevice=&lt;Ger&auml;t&gt;]
      [onRegex=^on$] [offRegex=^off$] [minDuration=1] [maxDuration=240]</code>.
      <code>device</code> ist Schaltziel, Modellschl&uuml;ssel und der in
      <code>simulationEvent</code> verwendete Ger&auml;tename. <code>onCommand</code>
      und <code>offCommand</code> werden an dieses Device gesendet. Das optionale
      <code>readingDevice</code> liefert Live-Events, aktuelle
      Playback-R&uuml;ckmeldungen und DbLog-Historie; ohne Angabe entspricht es
      <code>device</code>. <code>reading</code> und die regul&auml;ren Ausdr&uuml;cke
      werden immer auf diesem Beobachtungs-Device ausgewertet.
      <code>minDuration</code> muss mindestens 1 Minute betragen;
      <code>maxDuration</code> muss zwischen <code>minDuration</code> und 1440
      Minuten liegen. Werte mit Leerzeichen m&uuml;ssen in Anf&uuml;hrungszeichen
      stehen.</li>
  <li><code>deviceNNBlockMM</code><br>Optionale Sperrbedingungen 01 bis 10 f&uuml;r
      Ger&auml;t NN. Beispiel: <code>[Jalousie_Kueche:state] eq "down"</code>.
      Mehrere Blocks sind ODER-verkn&uuml;pft. Innerhalb eines Blocks werden
      <code>&amp;&amp;</code>, <code>||</code>, Klammern, Zahlen- und Textvergleiche sowie
      Regex-Operatoren unterst&uuml;tzt.</li>
  <li><code>globalBlockNN</code><br>Optionale globale Sperrbedingungen 01 bis 20.
      Beispiel: <code>[Wetter:Helligkeit] &gt; 300</code>.</li>
  <li><code>trainingSource events|dblog</code><br>Steuert die laufende Datenerfassung,
      nicht die Auswahl der gespeicherten Modelldaten. In beiden Modi verwendet das
      Modell ausreichend erfasste Event-Tage zusammen mit beibehaltenen
      DbLog-Importtagen. Standard: <code>events</code>. Der Event-Modus zeichnet
      Live-Events auf und importiert DbLog-Daten nur auf manuellen Befehl. Der
      DbLog-Modus zeichnet keine Live-Sessions auf und aktiviert zus&auml;tzlich den
      t&auml;glichen automatischen Import. Der DbLog-Modus erfordert ein ausdr&uuml;cklich
      gesetztes <code>dbLogDevice</code>.</li>
  <li><code>dbLogDevice</code><br>Name des f&uuml;r manuelle oder automatische Importe
      verwendeten DbLog-Devices. Erforderlich f&uuml;r <code>importDbLog</code> in
      beiden Trainingsmodi und f&uuml;r <code>trainingSource=dblog</code>.
      Kein Standardwert.</li>
  <li><code>importTime</code><br>T&auml;glicher automatischer DbLog-Import im Format HH:MM.
      Wird nur bei <code>trainingSource=dblog</code> verwendet.
      Standard: <code>03:05</code>.</li>
  <li><code>trainingDays</code><br>Anzahl abgeschlossener Kalendertage f&uuml;r das Modell.
      Bereich 1 bis 90, Standard 30.</li>
  <li><code>retentionDays</code><br>Anzahl abgeschlossener Kalendertage in den
      Rohdaten. Bereich 1 bis 365, Standard 90. Der wirksame Wert ist nie
      kleiner als <code>trainingDays</code>.</li>
  <li><code>binMinutes</code><br>L&auml;nge eines Modell-Zeitblocks: 1, 5, 10, 15,
      20, 30 oder 60 Minuten. Standard 15.</li>
  <li><code>minTrainingMinutes</code><br>Mindest-Aufzeichnungszeit eines Tages beim
      Event-Training. Bereich 0 bis 1440, Standard 1200.</li>
  <li><code>saveInterval</code><br>Verz&ouml;gerung f&uuml;r geb&uuml;ndeltes Speichern in
      Sekunden. Bereich 30 bis 1800, Standard 300.</li>
  <li><code>manualLockMinutes</code><br>Sperrzeit nach einem manuellen Eingriff im
      Playback. Bereich 0 bis 1440, Standard 120.</li>
  <li><code>probabilityFactor</code><br>Multiplikator, der einmal auf jede
      historische Blockwahrscheinlichkeit angewendet wird. Der wirksame Wert ist auf
      100&nbsp;% begrenzt. Eine &Auml;nderung wirkt auf noch nicht geplante
      Blockentscheidungen; ein bereits ausstehender Plan beh&auml;lt den Faktor, mit dem
      er erzeugt wurde. Bereich 0,1 bis 3,0, Standard 1,0.</li>
  <li><code>weekdaySpecific 0|1</code><br>Ein gemeinsames Modell f&uuml;r alle Tage
      (0, Standard) oder getrennte Modelle je Wochentag (1).</li>
  <li><code>eventFn</code><br>Optionaler Handler, der bei jedem
      <code>simulationEvent</code> ausgef&uuml;hrt wird. Das Attribut enth&auml;lt direkt
      einen FHEM-Befehl, eine Befehlskette oder einen Perl-Block. Die verf&uuml;gbaren
      Platzhalter sind bewusst auf <code>$NAME</code>, <code>$MODE</code>,
      <code>$DEVICE</code>, <code>$ACTION</code>, <code>$EVENT</code> und
      <code>$EVENTDETAILS</code> beschr&auml;nkt. <code>$EVENT</code> enth&auml;lt den
      vollst&auml;ndigen Ereignistext. <code>$EVENTDETAILS</code> fasst alle weiteren
      Schl&uuml;ssel/Wert-Details zusammen, darunter Zeitstempel, Dauer,
      Wahrscheinlichkeiten, Historie, Modell und gegebenenfalls den Namen der
      zutreffenden Sperrbedingung. Ausdruck und gelesene Istwerte werden bewusst nicht
      in den Eventtext aufgenommen und bleiben im FHEM-Log verf&uuml;gbar. Die
      Platzhalterersetzung ist befehlsneutral; der aufgerufene FHEM-Befehl ist
      selbst f&uuml;r seine Anf&uuml;hrungszeichen und Parametersyntax verantwortlich. Beim
      FHEM-Befehl <code>msg</code> muss das Ereignis ausdr&uuml;cklich als
      <code>msgText</code> &uuml;bergeben und die f&uuml;hrende Jahreszahl mit einem leeren
      <code>msgPrio</code>-Parameter gesch&uuml;tzt werden.<br><br>
      Eine Funktion aus <code>99_myUtils.pm</code> kann ausdr&uuml;cklich aus einem
      Perl-Block aufgerufen werden. Der Handler wird synchron ausgef&uuml;hrt und
      sollte daher schnell zur&uuml;ckkehren. Fehler werden abgefangen und &uuml;ber
      <code>lastError</code> mit Quelle <code>eventFn</code> gemeldet.</li>
  <li><code>eventFnEnabled 0|1</code><br>Steuert die Ausf&uuml;hrung einer
      konfigurierten <code>eventFn</code>. Standard ist 1. Bei Wert 0 bleibt das
      vollst&auml;ndige Handler-Attribut gespeichert, wird aber nicht ausgef&uuml;hrt;
      <code>simulationEvent</code> wird unver&auml;ndert weiter erzeugt. Eine
      &Auml;nderung wirkt ab dem n&auml;chsten Ereignis und baut keine Pl&auml;ne neu auf.
      Das L&ouml;schen des Attributs stellt den Standardwert 1 wieder her. Beim
      Deaktivieren wird ein vorhandener Fehler mit Quelle <code>eventFn</code>
      gel&ouml;scht.</li>
  <li><code>disable 0|1</code>, <code>disabledForIntervals</code><br>Verwendet die standardm&auml;&szlig;igen FHEM-Deaktivierungsfunktionen. Wenn der deaktivierte Zustand aktiv wird, werden vom Playback verwaltete Ger&auml;te ausgeschaltet.</li>
</ul>

<p>Beispiel f&uuml;r einen direkten FHEM-Befehl:</p>
<pre>attr PresenceSimulation eventFn msg @Bewohner msgPrio="" msgText="$EVENT"</pre>
<p>Perl-Block mit Aufruf einer Funktion aus <code>99_myUtils.pm</code>:</p>
<pre>attr PresenceSimulation eventFn { myPresenceSimulationEvent("$MODE", "$DEVICE", "$ACTION", "$EVENTDETAILS") }</pre>
<pre>sub myPresenceSimulationEvent {
    my ($mode, $device, $action, $eventDetails) = @_;
    fhem("msg \@Bewohner $device: $action ($mode) $eventDetails");
    return;
}</pre>

<a id="PresenceSimulation-readings"></a>
<h4>Readings</h4>
<ul>
  <li><code>state</code>, <code>mode</code>: aktuelle Betriebsart.</li>
  <li><code>activeTraining</code>: aktuell offene reale Trainingssitzungen.</li>
  <li><code>activePlayback</code>: aktuell vom echten Playback verwaltete Ger&auml;te.</li>
  <li><code>stoppingPlayback</code>: Ger&auml;te, die aktuell auf eine
      OFF-Best&auml;tigung oder einen weiteren begrenzten automatischen
      OFF-Versuch warten.</li>
  <li><code>activeDryRun</code>: aktuell aktive virtuelle Sitzungen.</li>
  <li><code>simulationEvent</code>: Event erzeugende Aktion on, off oder blocked aus
      Dry Run oder echtem Playback. Der Wert enth&auml;lt ein <code>mode=</code>-Feld.
      Geplante on/blocked-Ereignisse enthalten zus&auml;tzlich die historische
      Wahrscheinlichkeit <code>pHistorical</code>, den wirksamen Wert
      <code>pBlock</code>, <code>factor</code>, die geplante Startzeit, Historie und
      Anzahl der Startpositions-Stichproben. Das erste blocked-Ereignis enth&auml;lt
      zus&auml;tzlich <code>pending=1</code> und <code>retryUntil=HH:MM</code>. F&auml;llt die
      Sperre noch im selben Zeitblock weg, erg&auml;nzt das folgende on-Ereignis
      <code>started=HH:MM</code> und <code>delayed=Nmin</code>; seine
      <code>duration</code> wird um diese Verz&ouml;gerung reduziert, damit der geplante
      Endzeitpunkt erhalten bleibt. Bei weniger als einer Minute Restdauer gibt es
      kein on-Ereignis. Ein blockiertes Ereignis
      enth&auml;lt <code>condition=&lt;Attribut&gt;</code>;
      <code>reason=evaluationError</code> wird nur erg&auml;nzt, wenn die Bedingung nicht
      ausgewertet werden konnte. Der vollst&auml;ndige Ausdruck und die gelesenen Istwerte
      stehen im Log; Auswertungsfehler verwenden
      <code>lastErrorSource=blockCondition</code>.</li>
  <li><code>lastEvent</code>: letztes verarbeitetes Ger&auml;teereignis; wird ohne Event aktualisiert.</li>
  <li><code>configuredDevices</code>: Anzahl g&uuml;ltig konfigurierter Ger&auml;te.</li>
  <li><code>rawSessions</code>: Gesamtzahl der gespeicherten abgeschlossenen
      Ein-/Ausschalt-Sessions aller konfigurierten Ger&auml;te und Kalendertage.
      Eine Raw-Session beginnt mit einem erkannten Einschaltvorgang und endet mit
      dem zugeh&ouml;rigen Ausschaltvorgang. Startzeit und Dauer werden gespeichert,
      bevor die Daten im Wahrscheinlichkeitsmodell zusammengefasst werden.</li>
  <li><code>rawSessionsToday</code>: Anzahl der dem aktuellen Rohdaten-Kalendertag
      zugeordneten abgeschlossenen Raw-Sessions. Ein noch eingeschaltetes Ger&auml;t wird
      erst nach dem passenden Ausschaltvorgang gez&auml;hlt.</li>
  <li><code>rawSessionsTodayDiscarded</code>: Anzahl der dem aktuellen
      Rohdaten-Kalendertag zugeordneten Event-Trainingssitzungen, die wegen einer
      gerundeten Dauer au&szlig;erhalb von <code>minDuration</code>/<code>maxDuration</code>
      verworfen wurden.</li>
  <li><code>rawDays</code>: Anzahl der in den Rohdaten gespeicherten Kalendertage.
      Ein gespeicherter Tag kann keine abgeschlossene Session enthalten, etwa wenn
      Trainingszeit erfasst, aber kein konfiguriertes Ger&auml;t geschaltet wurde.</li>
  <li><code>modelSessions</code>, <code>trainingDaysUsed</code>,
      <code>effectiveTrainingDays</code>, <code>modelCreated</code>: Status des aktiven Modells.</li>
  <li><code>importState</code>, <code>nextDbLogImport</code>: Status des DbLog-Imports.</li>
  <li><code>lastError</code>, <code>lastErrorSource</code>, <code>lastErrorTime</code>:
      letzter Fehler mit Teilbereich und Zeitpunkt. Ohne aktiven Fehler sind
      alle drei Readings mit <code>none</code> belegt.</li>
</ul>

<a id="PresenceSimulation-notes"></a>
<h4>Hinweise</h4>
<ul>
  <li>&Auml;nderungen an Ger&auml;te- oder Modellattributen werden abgelehnt, solange das echte Playback Ger&auml;te verwaltet. Zuerst <code>mode off</code> setzen und warten, bis <code>stoppingPlayback</code> den Wert 0 hat.</li>
  <li>Ein ungekl&auml;rter OFF-Befehl wird h&ouml;chstens dreimal versucht: sofort,
      nach einer Minute und nach weiteren f&uuml;nf Minuten. Bleibt die
      OFF-R&uuml;ckmeldung auch nach der letzten Best&auml;tigungsfrist aus, werden
      keine weiteren automatischen Befehle gesendet und das Ger&auml;t wird aus der
      Playback-Verwaltung entlassen, ohne es als physisch ausgeschaltet zu behandeln.
      Der Fehler bleibt in <code>lastError</code> mit Quelle <code>playback</code>
      sichtbar, bis eine sp&auml;tere erfolgreiche Playback-ON-Aktion ihn l&ouml;scht oder
      ein anderer Fehler ihn ersetzt. Auch k&uuml;nftiges Playback sendet ON nur bei
      einem eindeutig erkannten OFF-Zustand.</li>
  <li>Eine &Auml;nderung von <code>trainingSource</code> l&ouml;scht oder verbirgt keine
      gespeicherten Rohdaten. In beiden Modi bleiben importierte DbLog-Tage und
      ausreichend erfasste Event-Tage f&uuml;r das Modell nutzbar. Das aktuell
      konfigurierte <code>dbLogDevice</code> steuert k&uuml;nftige Importe, macht aber
      gespeicherte Importe aus einem anderen DbLog-Device nicht ung&uuml;ltig.
      Automatische Importe werden weiterhin nur im DbLog-Modus geplant.</li>
  <li>Dauerhafte Daten werden unter <code>FHEM/FhemUtils</code> getrennt als Rohdaten und Laufzeitstatus gespeichert. Das Modell wird nach dem Start und nach Konfigurations&auml;nderungen aus den Rohdaten neu aufgebaut. Die Dateien hei&szlig;en <code>PresenceSimulation_Raw_&lt;name&gt;.json</code> und <code>PresenceSimulation_State_&lt;name&gt;.json</code>; sie folgen dem FHEM-Device und werden beim Umbenennen automatisch mitgef&uuml;hrt. Beim dauerhaften
      L&ouml;schen der Definition werden auch die Datendateien dieser Instanz entfernt.</li>
  <li>FHEMWEB verwendet intern standardm&auml;&szlig;ig die
      <code>devStateIcon</code>-Zuordnung
      <code>off:rc_STOP training:rc_REC dryrun:rc_PLAY playback:rc_PLAYgreen</code>.
      Sie wird nicht als Attribut angelegt und kann mit einem normalen
      ger&auml;tespezifischen <code>devStateIcon</code>-Attribut &uuml;berschrieben werden.</li>
</ul>

=end html_DE

=for :application/json;q=META.json 98_PresenceSimulation.pm
{
  "meta-spec": {
    "version": "2",
    "url": "https://metacpan.org/pod/CPAN::Meta::Spec"
  },
  "name": "FHEM-PresenceSimulation",
  "abstract": "Learns device switching behaviour and simulates presence",
  "description": "A rolling FHEM presence simulation based on historical device switching sessions. Retained event and DbLog days share one model while trainingSource controls ongoing acquisition and automatic imports. Command targets can use separate observation devices for live feedback and DbLog history. Bounded OFF retries and hardened nonblocking DbLog workers improve runtime safety. It supports switchable generic inline event handlers, real playback, dry-run events, weekday models, and blocking conditions.",
  "version": "v1.1.10",
  "x_release_date": "2026-06-28",
  "release_status": "testing",
  "license": [
    "gpl_2"
  ],
  "author": [
    "Flachzange <>"
  ],
  "dynamic_config": 0,
  "generated_by": "FHEM::Meta",
  "x_lang": {
    "de": {
      "abstract": "Lernt Geräteschaltverhalten und simuliert Anwesenheit",
      "description": "Eine rollierende FHEM-Anwesenheitssimulation auf Basis historischer Geräteschaltungen. Gespeicherte Event- und DbLog-Tage bilden ein gemeinsames Modell, w\u00e4hrend trainingSource die laufende Erfassung und automatische Importe steuert. Schaltziele k\u00f6nnen getrennte Beobachtungs-Devices f\u00fcr Live-R\u00fcckmeldungen und DbLog-Historie verwenden. Begrenzte OFF-Wiederholungen und geh\u00e4rtete nichtblockierende DbLog-Worker verbessern die Laufzeitsicherheit. Unterst\u00fctzt echtes Playback, Dry-Run-Ereignisse, Inline-Eventhandler, Wochentagsmodelle und Sperrbedingungen."
    }
  },
  "x_ai_assisted": {
    "tool": "OpenAI ChatGPT",
    "statement": "Developed iteratively under human direction; reviewed, tested, licensed, maintained, and published by the human maintainer."
  },
  "keywords": [
    "FHEM",
    "presence simulation",
    "devices",
    "DbLog",
    "hybrid training",
    "dry run",
    "event handler",
    "probability model",
    "reading device"
  ],
  "prereqs": {
    "runtime": {
      "requires": {
        "perl": "5.014",
        "FHEM": "5.00918623",
        "FHEM::Meta": "0.001006",
        "Blocking": "0",
        "Digest::SHA": "0",
        "File::Basename": "0",
        "File::Copy": "0",
        "File::Path": "0",
        "File::Spec": "0",
        "File::Temp": "0",
        "JSON::PP": "0",
        "POSIX": "0",
        "Scalar::Util": "0",
        "Text::ParseWords": "0",
        "Time::HiRes": "0",
        "strict": "0",
        "warnings": "0"
      }
    }
  },
  "x_support_status": "experimental"
}
=end :application/json;q=META.json

=cut
