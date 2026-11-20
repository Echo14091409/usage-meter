<#
Usage Meter for Windows (EXPERIMENTAL)

A tray icon that shows your Claude plan limits (5-hour, weekly, model-specific) by asking Claude Code itself:
it runs   claude -p "/usage" --output-format json   and reads the answer. No message goes to a model, no tokens
are used, no login is held, and this script makes no network connections of its own.

Start it with "Usage Meter.cmd" next to this file. Needs Windows 10 or 11 and Claude Code signed in with a Claude plan.

  -Once       check once, print one line, exit (no tray icon)
  -SelfTest   run the built-in tests and exit
  -ClaudePath use this claude executable instead of looking for one
  -DataDir    where settings and history are kept (default: %APPDATA%\Usage Meter)

Copyright (C) 2026 Echo14091409. GNU General Public License v3.0; see LICENSE in the repository.
This file must stay plain ASCII (Windows PowerShell 5.1 misreads other characters in scripts without a BOM).
#>
param(
    [switch]$SelfTest,
    [switch]$Once,
    [string]$ClaudePath = '',
    [string]$DataDir = ''
)

$ErrorActionPreference = 'Stop'
$script:Version = '0.12.0 experimental'
$script:Dot = [string][char]0x00B7           # the middle dot Claude Code prints between fields
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
if (-not $DataDir) { $DataDir = Join-Path $env:APPDATA 'Usage Meter' }

# ---------------------------------------------------------------- reading the /usage text

# "Nov 23 at 6:59am (Europe/Rome)", "Jan 2 at 7am" or just "10:49am": the next such moment, in local time.
function ConvertTo-ResetTime([string]$s, [datetime]$now) {
    $m = [regex]::Match($s, '^(?:([A-Za-z]{3})[A-Za-z]*\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*([AaPp][Mm])?(?:\s*\(([^)]+)\))?\s*$')
    if (-not $m.Success) { return $null }
    $hour = [int]$m.Groups[3].Value
    if ($m.Groups[5].Success) {
        $hour = $hour % 12
        if ($m.Groups[5].Value.ToLower() -eq 'pm') { $hour += 12 }
    }
    $minute = 0
    if ($m.Groups[4].Success) { $minute = [int]$m.Groups[4].Value }
    if ($hour -gt 23 -or $minute -gt 59) { return $null }
    if (-not $m.Groups[1].Success) {
        $d = New-Object datetime($now.Year, $now.Month, $now.Day, $hour, $minute, 0)
        if ($d -lt $now.AddMinutes(-1)) { $d = $d.AddDays(1) }
        return $d
    }
    $months = @('jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec')
    $mi = [array]::IndexOf($months, $m.Groups[1].Value.ToLower())
    if ($mi -lt 0) { return $null }
    try { $d = New-Object datetime($now.Year, ($mi + 1), ([int]$m.Groups[2].Value), $hour, $minute, 0) } catch { return $null }
    # No year in the text: a date more than a day in the past means next year.
    if ($d -lt $now.AddDays(-1)) { $d = $d.AddYears(1) }
    return $d
}

# Reads lines such as
#   Current session: 11% used <dot> resets Nov 20 at 10:49am (Europe/Rome)      -> 5-hour window
#   Current week (all models): 31% used <dot> resets Nov 23 at 6:59am (...)     -> weekly limit
#   Current week (Fable): 29% used <dot> resets Nov 23 at 6:59am (...)          -> a model-specific weekly limit
# The text is not a documented format. A limit whose reset cannot be read is left out rather than guessed,
# except a session at 0 %, which is a window that is not running.
function ConvertFrom-UsageText([string]$text, [datetime]$now) {
    $report = @{ five = $null; week = $null; models = @() }
    $pattern = '(?m)^\s*Current (session|week)(?: \(([^)]+)\))?:\s*(\d+(?:\.\d+)?)\s*% used(?:\s*' + $script:Dot + '\s*resets\s+(.+?))?\s*$'
    $modelLines = @()
    foreach ($m in [regex]::Matches($text, $pattern)) {
        $pct = [double]::Parse($m.Groups[3].Value, $script:Inv)
        $reset = $null
        if ($m.Groups[4].Success) { $reset = ConvertTo-ResetTime $m.Groups[4].Value $now }
        $name = $null
        if ($m.Groups[2].Success) { $name = $m.Groups[2].Value.Trim() }
        if ($m.Groups[1].Value -eq 'session') {
            if ($null -eq $reset -and $pct -eq 0) { $reset = $now }
            if ($null -ne $reset) { $report.five = @{ name = '5-hour limit'; pct = $pct; reset = $reset; hours = 5.0 } }
        } elseif ($null -eq $name -or $name.ToLower() -eq 'all models') {
            if ($null -ne $reset) { $report.week = @{ name = 'Weekly limit'; pct = $pct; reset = $reset; hours = 168.0 } }
        } else {
            $modelLines += @{ name = $name; pct = $pct; reset = $reset }
        }
    }
    foreach ($l in $modelLines) {
        $reset = $l.reset
        if ($null -eq $reset -and $null -ne $report.week) { $reset = $report.week.reset }
        if ($null -ne $reset) {
            $report.models += @{ name = ('Weekly ' + $l.name + ' limit'); model = $l.name; pct = $l.pct; reset = $reset; hours = 168.0 }
        }
    }
    return $report
}

# Every limit of a report as one list: 5-hour, weekly, then the model ones.
function Get-Limits($report) {
    $all = @()
    if ($null -ne $report) {
        if ($null -ne $report.five) { $all += $report.five }
        if ($null -ne $report.week) { $all += $report.week }
        foreach ($m in $report.models) { $all += $m }
    }
    return , $all
}

# ---------------------------------------------------------------- pace and notifications

# Where a window ends up if use carries on at the window's average rate so far. $null when there is nothing
# sensible to say: under a tenth of the window has passed, nothing is used yet, or it has already reset.
function Get-Pace([double]$pct, [datetime]$reset, [double]$hours, [datetime]$now) {
    $window = $hours * 3600.0
    $elapsed = $window - ($reset - $now).TotalSeconds
    if ($now -ge $reset -or $elapsed -lt ($window / 10.0) -or $pct -le 0) { return $null }
    $atReset = $pct * $window / $elapsed
    $runsOut = $null
    $full = $reset.AddSeconds(-$window).AddSeconds($elapsed * 100.0 / $pct)
    if ($pct -lt 100 -and $full -lt $reset) { $runsOut = $full }
    return @{ atReset = $atReset; runsOut = $runsOut }
}

function Format-Clock([datetime]$d, [datetime]$now) {
    if ($d.Date -eq $now.Date) { return $d.ToString('HH:mm', $script:Inv) }
    return $d.ToString('ddd HH:mm', $script:Inv)
}

function Format-Reset([datetime]$reset, [datetime]$now) {
    $s = [int]($reset - $now).TotalSeconds
    if ($s -le 0) { return 'reset' }
    if ($s -lt 3600) { return ('resets in ' + [Math]::Max(1, [int][Math]::Floor($s / 60)) + ' min') }
    if ($s -lt 86400) { return ('resets in ' + [int][Math]::Floor($s / 3600) + ' h ' + [int][Math]::Floor(($s % 3600) / 60) + ' min') }
    return ('resets ' + (Format-Clock $reset $now))
}

function Format-Pace($pace, [datetime]$now) {
    if ($null -eq $pace) { return '' }
    if ($null -ne $pace.runsOut) { return ('full by ' + (Format-Clock $pace.runsOut $now) + ' at this pace') }
    return ('on pace for ' + [int][Math]::Round($pace.atReset) + '%')
}

# Which notifications a reading calls for. $state remembers, per limit, what was already said about its
# current window, so each kind comes once per window. $rules: level (0 = off), pace, reset.
function Get-Alerts($report, [hashtable]$state, [hashtable]$rules, [datetime]$now) {
    $events = @()
    foreach ($l in (Get-Limits $report)) {
        $key = $l.name
        if ($state.ContainsKey($key)) {
            $e = $state[$key]
            # A window we warned about is over: its time has come, or the reading belongs to a later window.
            if ($now -ge $e.reset -or ($l.reset - $e.reset).TotalSeconds -gt 3600) {
                if (($e.level -or $e.full -or $e.pace) -and $rules.reset) {
                    $events += @{ title = ($l.name + ' has reset'); body = 'You have the full allowance again.' }
                }
                $state.Remove($key)
            }
        }
        if ($l.reset -le $now) { continue }
        $e = @{ reset = $l.reset; level = $false; full = $false; pace = $false }
        if ($state.ContainsKey($key)) { $e = $state[$key]; $e.reset = $l.reset }
        $shown = [int][Math]::Round($l.pct)
        $when = (Format-Reset $l.reset $now)
        $when = $when.Substring(0, 1).ToUpper() + $when.Substring(1) + '.'
        if ($l.pct -ge 100) {
            if (-not $e.full) { $events += @{ title = ($l.name + ' reached'); body = $when } }
            $e.full = $true; $e.level = $true; $e.pace = $true
        } else {
            if ($rules.level -gt 0 -and $l.pct -ge $rules.level -and -not $e.level) {
                $events += @{ title = ($l.name + ' at ' + $shown + '%'); body = $when }
                $e.level = $true
            }
            if ($rules.pace -and -not $e.pace -and $l.pct -ge 30) {
                $p = Get-Pace $l.pct $l.reset $l.hours $now
                if ($null -ne $p -and $null -ne $p.runsOut) {
                    $events += @{ title = ($l.name + ' on pace to run out'); body = ('At ' + $shown + '% now; full by ' + (Format-Clock $p.runsOut $now) + ' at this pace. ' + $when) }
                    $e.pace = $true
                }
            }
        }
        if ($e.level -or $e.full -or $e.pace) { $state[$key] = $e }
    }
    return , $events
}

# ---------------------------------------------------------------- asking Claude Code

function Find-Claude {
    if ($ClaudePath) { return $ClaudePath }
    $candidates = @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:USERPROFILE '.claude\local\claude.exe'),
        (Join-Path $env:APPDATA 'npm\claude.cmd')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

# Starts   claude -p "/usage" ...   without a window and returns the process; the answer is read when it ends.
function Start-UsageProcess([string]$claude) {
    $arguments = '-p "/usage" --output-format json --strict-mcp-config --setting-sources "" --no-session-persistence'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($claude -match '\.(cmd|bat)$') {
        # A .cmd shim (npm install) has to go through the command interpreter.
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /s /c ""' + $claude + '" ' + $arguments + '"'
    } else {
        $psi.FileName = $claude
        $psi.Arguments = $arguments
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.WorkingDirectory = $env:TEMP
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    return @{ process = $p; out = $p.StandardOutput.ReadToEndAsync(); err = $p.StandardError.ReadToEndAsync(); started = (Get-Date) }
}

# Turns a finished process into a report, or throws a message meant for the user.
function Read-UsageResult($run) {
    $text = ''
    $isError = $false
    try {
        $o = ConvertFrom-Json $run.out.Result
        if ($o.result) { $text = [string]$o.result }
        if ($o.is_error) { $isError = $true }
    } catch { }
    $report = ConvertFrom-UsageText $text (Get-Date)
    if ($isError -or ($null -eq $report.five -and $null -eq $report.week)) {
        if ($isError -or $run.process.ExitCode -ne 0) {
            $hint = ($run.err.Result -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
            if (-not $hint) { $hint = 'exit code ' + $run.process.ExitCode }
            throw ('Claude Code failed: ' + $hint)
        }
        throw 'Claude Code answered but reported no plan limits (not signed in with a Claude plan, or a changed format).'
    }
    return $report
}

function Get-UsageNow {
    $claude = Find-Claude
    if (-not $claude) { throw 'Claude Code (the claude command) was not found.' }
    $run = Start-UsageProcess $claude
    if (-not $run.process.WaitForExit(60000)) {
        try { $run.process.Kill() } catch { }
        throw 'Claude Code did not answer within 60 seconds.'
    }
    return (Read-UsageResult $run)
}

function Format-Summary($report) {
    $parts = @()
    if ($null -ne $report.five) { $parts += ('5h ' + [int][Math]::Round($report.five.pct) + '%') }
    if ($null -ne $report.week) { $parts += ('week ' + [int][Math]::Round($report.week.pct) + '%') }
    foreach ($m in $report.models) { $parts += ($m.model + ' ' + [int][Math]::Round($m.pct) + '%') }
    return ($parts -join ' | ')
}

# ---------------------------------------------------------------- settings and history (local files only)

function Read-Settings {
    $s = @{ minutes = 5; notify = $false; level = 80; pace = $true; reset = $true }
    $file = Join-Path $DataDir 'settings.json'
    if (Test-Path -LiteralPath $file) {
        try {
            $o = ConvertFrom-Json (Get-Content -LiteralPath $file -Raw)
            foreach ($k in @($s.Keys)) { if ($null -ne $o.$k) { $s[$k] = $o.$k } }
        } catch { }
    }
    return $s
}

function Save-Settings([hashtable]$s) {
    [void](New-Item -ItemType Directory -Force -Path $DataDir)
    Set-Content -LiteralPath (Join-Path $DataDir 'settings.json') -Value (ConvertTo-Json $s) -Encoding UTF8
}

# The model figures of a history entry as one comparable string, whether it was just made or read from the file.
function Get-ModelKey($m) {
    if ($null -eq $m) { return '' }
    $names = @()
    if ($m -is [hashtable]) { $names = @($m.Keys) } else { $names = @($m.PSObject.Properties | ForEach-Object { $_.Name }) }
    $parts = @()
    foreach ($n in ($names | Sort-Object)) {
        $v = $null
        if ($m -is [hashtable]) { $v = $m[$n] } else { $v = $m.$n }
        $parts += ($n + '=' + ([double]$v).ToString('0.###', $script:Inv))
    }
    return ($parts -join ';')
}

function ConvertTo-Unix([datetime]$d) { return [double]([DateTimeOffset]$d).ToUnixTimeSeconds() }

# Appends a reading in the same shape the Mac app uses ({t, s, r, f, fr, m}); 60 days are kept.
# Unchanged readings are written at most every 30 minutes. Returns the number of entries kept.
function Add-History($report, [datetime]$now) {
    if ($null -eq $report.week) { return 0 }
    [void](New-Item -ItemType Directory -Force -Path $DataDir)
    $file = Join-Path $DataDir 'history.json'
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $file) {
        try { $old = ConvertFrom-Json (Get-Content -LiteralPath $file -Raw); foreach ($x in $old) { [void]$list.Add($x) } } catch { }
    }
    $entry = @{ t = (ConvertTo-Unix $now); s = $report.week.pct; r = (ConvertTo-Unix $report.week.reset) }
    if ($null -ne $report.five -and $report.five.reset -gt $now) { $entry.f = $report.five.pct; $entry.fr = (ConvertTo-Unix $report.five.reset) }
    $models = @{}
    foreach ($m in $report.models) { $models[$m.model] = $m.pct }
    $entry.m = $models
    if ($list.Count -gt 0) {
        $last = $list[$list.Count - 1]
        $same = ($last.s -eq $entry.s) -and ($last.f -eq $entry.f) -and ((Get-ModelKey $last.m) -eq (Get-ModelKey $entry.m))
        if ($same -and [Math]::Abs($last.r - $entry.r) -lt 3600 -and ($entry.t - $last.t) -lt 1800) { return $list.Count }
    }
    [void]$list.Add($entry)
    $cutoff = (ConvertTo-Unix $now) - 60 * 86400
    $kept = @($list | Where-Object { $_.t -ge $cutoff })
    Set-Content -LiteralPath $file -Value (ConvertTo-Json -InputObject $kept -Depth 5 -Compress) -Encoding UTF8
    return $kept.Count
}

# ---------------------------------------------------------------- built-in tests

function Invoke-SelfTest {
    $script:failed = 0
    function Check($ok, [string]$what) { if (-not $ok) { $script:failed++; Write-Host ('FAIL: ' + $what) } }
    $d = $script:Dot
    $now = New-Object datetime(2026, 11, 20, 10, 33, 0)
    $real = "You are currently using your subscription to power your Claude Code usage`r`n`r`n" +
            "Current session: 11% used $d resets Nov 20 at 10:49am (Europe/Rome)`r`n" +
            "Current week (all models): 31% used $d resets Nov 23 at 6:59am (Europe/Rome)`r`n" +
            "Current week (Fable): 29% used $d resets Nov 23 at 6:59am (Europe/Rome)`r`n`r`n" +
            "What's contributing to your usage?`r`n  79%  Start fresh when you switch tasks $d run /clear`r`n"

    # 1. The real text (Windows line ends): session, week and one model row.
    $r = ConvertFrom-UsageText $real $now
    Check ($r.five.pct -eq 11) ('session 11 %, got ' + $r.five.pct)
    Check ($r.five.reset -eq (New-Object datetime(2026, 11, 20, 10, 49, 0))) ('session reset, got ' + $r.five.reset)
    Check ($r.week.pct -eq 31) ('week 31 %, got ' + $r.week.pct)
    Check ($r.week.reset -eq (New-Object datetime(2026, 11, 23, 6, 59, 0))) ('week reset, got ' + $r.week.reset)
    Check ($r.models.Count -eq 1 -and $r.models[0].model -eq 'Fable' -and $r.models[0].pct -eq 29) 'one model row: Fable 29 %'
    Check ((Format-Summary $r) -eq '5h 11% | week 31% | Fable 29%') ('summary, got ' + (Format-Summary $r))
    Check ((Get-Limits $r).Count -eq 3) 'three limits in all'

    # 2. Unix line ends, "Current week:" without a model list, no model row, empty text.
    $plain = "Current session: 4% used $d resets 3:50pm`nCurrent week: 32% used $d resets Nov 23 at 7am"
    $r2 = ConvertFrom-UsageText $plain $now
    Check ($r2.five.reset -eq (New-Object datetime(2026, 11, 20, 15, 50, 0))) ('time-only reset is today, got ' + $r2.five.reset)
    Check ($r2.week.reset -eq (New-Object datetime(2026, 11, 23, 7, 0, 0)) -and $r2.models.Count -eq 0) 'week without minutes; no model rows'
    $r3 = ConvertFrom-UsageText '' $now
    Check ($null -eq $r3.five -and $null -eq $r3.week -and $r3.models.Count -eq 0) 'empty text gives nothing'
    $r4 = ConvertFrom-UsageText 'Estimated cost:        $0.0000' $now
    Check ($null -eq $r4.five -and $null -eq $r4.week) 'a signed-out answer gives nothing'

    # 3. Reset times: 12am/12pm, a time already past today, next year, rubbish.
    Check ((ConvertTo-ResetTime '12am' $now) -eq (New-Object datetime(2026, 11, 21, 0, 0, 0))) '12am is midnight, tomorrow'
    Check ((ConvertTo-ResetTime 'Nov 20 at 12:30pm' $now) -eq (New-Object datetime(2026, 11, 20, 12, 30, 0))) '12:30pm is half past noon'
    Check ((ConvertTo-ResetTime 'Jan 2 at 7am (Europe/Rome)' (New-Object datetime(2026, 12, 29, 12, 0, 0))) -eq (New-Object datetime(2027, 1, 2, 7, 0, 0))) 'January read in December is next year'
    Check ($null -eq (ConvertTo-ResetTime 'soon' $now)) 'unreadable reset gives nothing'
    $bare = ConvertFrom-UsageText "Current session: 0% used`nCurrent week (Fable): 5% used" $now
    Check ($bare.five.pct -eq 0 -and $bare.five.reset -eq $now) 'idle session = 0 %, reset now'
    Check ($bare.models.Count -eq 0) 'a model line with no reset and no weekly line is dropped'

    # 4. Pace: half-way through the week at 30 % = 60 %; at 80 % it runs out Fri 16:00.
    $weekReset = New-Object datetime(2026, 11, 23, 7, 0, 0)
    $half = New-Object datetime(2026, 11, 19, 19, 0, 0)
    $p = Get-Pace 30 $weekReset 168 $half
    Check ([Math]::Abs($p.atReset - 60) -lt 0.01 -and $null -eq $p.runsOut) '30 % at half-time = 60 % at reset'
    $p = Get-Pace 80 $weekReset 168 $half
    Check ($p.runsOut -eq (New-Object datetime(2026, 11, 20, 16, 0, 0))) ('80 % at half-time runs out Fri 16:00, got ' + $p.runsOut)
    Check ($null -eq (Get-Pace 5 $weekReset 168 (New-Object datetime(2026, 11, 16, 12, 0, 0)))) 'too early for a projection'
    Check ($null -eq (Get-Pace 0 $weekReset 168 $half)) 'nothing used: no projection'
    Check ($null -eq (Get-Pace 50 $weekReset 168 $weekReset.AddHours(1))) 'already reset: no projection'
    Check ((Format-Pace (Get-Pace 30 $weekReset 168 $half) $half) -eq 'on pace for 60%') 'pace text'
    Check ((Format-Reset $weekReset $half) -eq 'resets Mon 07:00') ('reset text, got ' + (Format-Reset $weekReset $half))
    Check ((Format-Reset $half.AddMinutes(130) $half) -eq 'resets in 2 h 10 min') 'reset text within a day'

    # 5. Notifications: once per window; "reached" alone when jumping to 100; reset announced after a warning.
    function Wk([double]$pct, [datetime]$reset) { return @{ five = $null; week = @{ name = 'Weekly limit'; pct = $pct; reset = $reset; hours = 168.0 }; models = @() } }
    $rules = @{ level = 80; pace = $false; reset = $true }
    $st = @{}
    Check ((Get-Alerts (Wk 40 $weekReset) $st $rules $half).Count -eq 0) 'nothing below the level'
    $ev = Get-Alerts (Wk 82 $weekReset) $st $rules $half
    Check ($ev.Count -eq 1 -and $ev[0].title -eq 'Weekly limit at 82%' -and $ev[0].body -eq 'Resets Mon 07:00.') ('level alert, got ' + ($ev | ForEach-Object { $_.title + ' / ' + $_.body }))
    Check ((Get-Alerts (Wk 85 $weekReset) $st $rules $half).Count -eq 0) 'not repeated in the same window'
    $ev = Get-Alerts (Wk 100 $weekReset) $st $rules $half
    Check ($ev.Count -eq 1 -and $ev[0].title -eq 'Weekly limit reached') 'reached alert'
    $ev = Get-Alerts (Wk 3 $weekReset.AddDays(7)) $st $rules $weekReset.AddHours(1)
    Check ($ev.Count -eq 1 -and $ev[0].title -eq 'Weekly limit has reset') ('reset alert, got ' + ($ev | ForEach-Object { $_.title }))
    Check ((Get-Alerts (Wk 3 $weekReset.AddDays(7)) $st $rules $weekReset.AddHours(2)).Count -eq 0) 'reset not repeated'
    $jump = @{}
    $ev = Get-Alerts (Wk 100 $weekReset) $jump $rules $half
    Check ($ev.Count -eq 1 -and $ev[0].title -eq 'Weekly limit reached') 'only "reached" when jumping to 100'
    $quiet = @{}
    [void](Get-Alerts (Wk 20 $weekReset) $quiet $rules $half)
    Check ((Get-Alerts (Wk 1 $weekReset.AddDays(7)) $quiet $rules $weekReset.AddHours(1)).Count -eq 0) 'a quiet window resets quietly'
    $ps = @{}
    $ev = Get-Alerts (Wk 60 $weekReset) $ps @{ level = 80; pace = $true; reset = $true } $half
    Check ($ev.Count -eq 1 -and $ev[0].title -eq 'Weekly limit on pace to run out' -and $ev[0].body.Contains('Sun 03:00')) ('pace alert, got ' + ($ev | ForEach-Object { $_.title + ' / ' + $_.body }))
    Check ((Get-Alerts (Wk 95 $weekReset) @{} @{ level = 0; pace = $false; reset = $true } $half).Count -eq 0) 'level 0 = no level alerts'

    # 6. History file: written, deduplicated, readable again.
    $saved = $DataDir
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('um-test-' + [guid]::NewGuid().ToString('N'))
    Set-Variable -Name DataDir -Value $tmp -Scope Script
    try {
        $rr = ConvertFrom-UsageText $real $now
        Check ((Add-History $rr $now) -eq 1) 'first reading stored'
        Check ((Add-History $rr $now.AddMinutes(2)) -eq 1) 'unchanged reading two minutes later skipped'
        $rr.five.pct = 14
        Check ((Add-History $rr $now.AddMinutes(4)) -eq 2) 'changed 5-hour figure stored'
        $back = ConvertFrom-Json (Get-Content -LiteralPath (Join-Path $tmp 'history.json') -Raw)
        Check (@($back).Count -eq 2 -and $back[1].f -eq 14 -and $back[0].m.Fable -eq 29 -and $back[0].s -eq 31) 'history file reads back'
        $s = Read-Settings
        Check ($s.minutes -eq 5 -and $s.notify -eq $false -and $s.level -eq 80) 'default settings'
        $s.minutes = 15; $s.notify = $true
        Save-Settings $s
        $s2 = Read-Settings
        Check ($s2.minutes -eq 15 -and $s2.notify -eq $true) 'settings saved and loaded'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Set-Variable -Name DataDir -Value $saved -Scope Script
    }

    # 7. This file is plain ASCII.
    $bytes = [IO.File]::ReadAllBytes($PSCommandPath)
    Check (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'the script is plain ASCII'

    # 8. The tray icon, menu and panel can be built (not shown).
    try {
        Initialize-Ui
        $ui = New-Ui
        $script:report = ConvertFrom-UsageText $real (Get-Date)
        $script:report.five.reset = (Get-Date).AddHours(2)
        $script:report.week.reset = (Get-Date).AddDays(3)
        $script:report.models[0].reset = (Get-Date).AddDays(3)
        $script:asOf = Get-Date
        Update-Ui $ui
        $bmp = New-Object Drawing.Bitmap(340, 400)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $height = Show-Limits $g 340
        $g.Dispose(); $bmp.Dispose()
        Check ($height -gt 150) ('panel draws three limits, height ' + $height)
        Check ($ui.icon.Text -like '5h 11%*') ('tray tooltip, got ' + $ui.icon.Text)
        Check ($ui.menu.Items.Count -ge 7) 'menu built'
        $ui.icon.Visible = $false
        $ui.icon.Dispose()
    } catch {
        Check $false ('building the tray UI failed: ' + $_.Exception.Message)
    }

    if ($script:failed -eq 0) { Write-Host 'all tests passed'; return 0 }
    Write-Host ([string]$script:failed + ' failed')
    return 1
}

# ---------------------------------------------------------------- tray icon and panel

function Initialize-Ui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if (-not ('UsageMeterNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UsageMeterNative {
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
    // Seconds since the last keyboard or mouse input.
    public static double IdleSeconds() {
        LASTINPUTINFO i = new LASTINPUTINFO();
        i.cbSize = (uint)Marshal.SizeOf(i);
        if (!GetLastInputInfo(ref i)) return 0;
        return unchecked((uint)Environment.TickCount - i.dwTime) / 1000.0;
    }
}
'@
    }
}

# A small square icon with the 5-hour % written in it ("-" while there is no reading).
function New-TrayIcon([string]$text, [bool]$stale) {
    $bmp = New-Object Drawing.Bitmap(32, 32)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $back = [Drawing.Color]::FromArgb(255, 37, 99, 235)
    if ($stale) { $back = [Drawing.Color]::FromArgb(255, 120, 120, 120) }
    $brush = New-Object Drawing.SolidBrush($back)
    $g.FillRectangle($brush, 0, 0, 32, 32)
    $size = 17
    if ($text.Length -ge 3) { $size = 12 }
    $font = New-Object Drawing.Font('Segoe UI', $size, [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString($text, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, 0, 32, 32)), $fmt)
    $g.Dispose(); $brush.Dispose(); $font.Dispose()
    $handle = $bmp.GetHicon()
    $icon = [Drawing.Icon]::FromHandle($handle).Clone()
    [void][UsageMeterNative]::DestroyIcon($handle)
    $bmp.Dispose()
    return $icon
}

function Test-Stale { return ($null -eq $script:asOf -or ((Get-Date) - $script:asOf).TotalMinutes -gt 20) }

# Draws the limits into $g and returns the height used.
function Show-Limits($g, [int]$width) {
    $now = Get-Date
    $bold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    $plain = New-Object Drawing.Font('Segoe UI', 9)
    $small = New-Object Drawing.Font('Segoe UI', 8)
    $grey = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 110, 110, 110))
    $track = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 225, 225, 225))
    $right = New-Object Drawing.StringFormat
    $right.Alignment = 'Far'
    $pad = 14
    $y = 12
    $g.DrawString('Plan limits', $bold, [Drawing.Brushes]::Black, $pad, $y)
    $y += 20
    $sub = 'No reading yet'
    if ($null -ne $script:asOf) { $sub = 'As of ' + $script:asOf.ToString('HH:mm', $script:Inv) + ', from Claude Code' }
    if ($script:problem) { $sub = $script:problem }
    $subRect = New-Object Drawing.RectangleF($pad, $y, ($width - 2 * $pad), 34)
    $g.DrawString($sub, $small, $grey, $subRect)
    $y += [int]$g.MeasureString($sub, $small, ($width - 2 * $pad)).Height + 8
    $stale = Test-Stale
    foreach ($l in (Get-Limits $script:report)) {
        $pct = $l.pct
        if ($l.reset -le $now) { $pct = 0 }
        $title = $l.name
        if ($l.hours -eq 5) { $title = 'Current 5-hour window' }
        $shown = ([string][int][Math]::Round($pct)) + '% used'
        if ($stale) { $shown = '~' + $shown }
        $g.DrawString($title, $plain, [Drawing.Brushes]::Black, $pad, $y)
        $g.DrawString($shown, $plain, [Drawing.Brushes]::Black, (New-Object Drawing.RectangleF($pad, $y, ($width - 2 * $pad), 18)), $right)
        $y += 20
        $g.FillRectangle($track, $pad, $y, ($width - 2 * $pad), 7)
        $color = [Drawing.Color]::FromArgb(255, 37, 99, 235)
        if ($pct -ge 90) { $color = [Drawing.Color]::FromArgb(255, 220, 38, 38) } elseif ($pct -ge 70) { $color = [Drawing.Color]::FromArgb(255, 234, 138, 0) }
        if ($stale) { $color = [Drawing.Color]::FromArgb(255, 150, 150, 150) }
        $fill = New-Object Drawing.SolidBrush($color)
        $g.FillRectangle($fill, $pad, $y, [int](($width - 2 * $pad) * [Math]::Min([Math]::Max($pct / 100.0, 0), 1)), 7)
        $fill.Dispose()
        $y += 11
        $line = Format-Reset $l.reset $now
        if (-not $stale -and $l.reset -gt $now) {
            $pace = Format-Pace (Get-Pace $l.pct $l.reset $l.hours $now) $now
            if ($pace) { $line = $line + ' ' + $script:Dot + ' ' + $pace }
        }
        $g.DrawString($line, $small, $grey, $pad, $y)
        $y += 24
    }
    $note = 'Each check asks Claude Code for its /usage report: no tokens used. Nothing leaves this PC; this tool collects no data.'
    $g.DrawString($note, $small, $grey, (New-Object Drawing.RectangleF($pad, $y, ($width - 2 * $pad), 44)))
    $y += [int]$g.MeasureString($note, $small, ($width - 2 * $pad)).Height + 8
    $bold.Dispose(); $plain.Dispose(); $small.Dispose(); $grey.Dispose(); $track.Dispose()
    return $y
}

function New-Ui {
    $ui = @{}
    $ui.icon = New-Object Windows.Forms.NotifyIcon
    $ui.icon.Text = 'Usage Meter'
    $ui.icon.Icon = New-TrayIcon '-' $true

    $form = New-Object Windows.Forms.Form
    $form.FormBorderStyle = 'FixedToolWindow'
    $form.Text = 'Usage Meter ' + $script:Version
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = 'Manual'
    $form.BackColor = [Drawing.Color]::White
    $form.ClientSize = New-Object Drawing.Size(340, 300)
    $canvas = New-Object Windows.Forms.Panel
    $canvas.Dock = 'Fill'
    $refresh = New-Object Windows.Forms.Button
    $refresh.Text = 'Refresh'
    $refresh.Size = New-Object Drawing.Size(90, 28)
    $refresh.Anchor = 'Bottom, Right'
    $form.Controls.Add($refresh)
    $form.Controls.Add($canvas)
    $ui.form = $form; $ui.canvas = $canvas; $ui.refresh = $refresh

    $menu = New-Object Windows.Forms.ContextMenuStrip
    $ui.menu = $menu
    $ui.itemShow = $menu.Items.Add('Show limits')
    $ui.itemRefresh = $menu.Items.Add('Refresh now')
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $ui.itemEvery = New-Object Windows.Forms.ToolStripMenuItem('Check automatically')
    [void]$menu.Items.Add($ui.itemEvery)
    $ui.everyItems = @{}
    foreach ($n in @(0, 2, 5, 15, 30)) {
        $label = 'Every ' + $n + ' min'
        if ($n -eq 0) { $label = 'Off' }
        $it = New-Object Windows.Forms.ToolStripMenuItem($label)
        $it.Tag = $n
        [void]$ui.itemEvery.DropDownItems.Add($it)
        $ui.everyItems[$n] = $it
    }
    $ui.itemNotify = New-Object Windows.Forms.ToolStripMenuItem('Notify me when a limit is close')
    [void]$menu.Items.Add($ui.itemNotify)
    $ui.itemLevel = New-Object Windows.Forms.ToolStripMenuItem('Warn at')
    [void]$menu.Items.Add($ui.itemLevel)
    $ui.levelItems = @{}
    foreach ($n in @(50, 70, 80, 90)) {
        $it = New-Object Windows.Forms.ToolStripMenuItem(([string]$n + '%'))
        $it.Tag = $n
        [void]$ui.itemLevel.DropDownItems.Add($it)
        $ui.levelItems[$n] = $it
    }
    $ui.itemStartup = New-Object Windows.Forms.ToolStripMenuItem('Start with Windows')
    [void]$menu.Items.Add($ui.itemStartup)
    $ui.itemFolder = $menu.Items.Add('Open data folder')
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $ui.itemQuit = $menu.Items.Add('Quit')
    $ui.icon.ContextMenuStrip = $menu
    return $ui
}

# Puts the latest reading into the tray icon and its tooltip, and repaints the panel.
function Update-Ui($ui) {
    $stale = Test-Stale
    $text = '-'
    $tip = 'Usage Meter: no reading yet'
    if ($null -ne $script:report) {
        if ($null -ne $script:report.five) {
            $p = $script:report.five.pct
            if ($script:report.five.reset -le (Get-Date)) { $p = 0 }
            $text = [string][int][Math]::Round($p)
        }
        $tip = Format-Summary $script:report
        if ($stale) { $tip = $tip + ' (out of date)' }
    }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }      # Windows limits tray tooltips
    $old = $ui.icon.Icon
    $ui.icon.Icon = New-TrayIcon $text $stale
    if ($null -ne $old) { $old.Dispose() }
    $ui.icon.Text = $tip
    $ui.canvas.Invalidate()
}

function Get-StartupLink { return (Join-Path ([Environment]::GetFolderPath('Startup')) 'Usage Meter.lnk') }

function Set-Startup([bool]$on) {
    $link = Get-StartupLink
    if (-not $on) { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue; return }
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($link)
    $s.TargetPath = (Join-Path $PSHOME 'powershell.exe')
    $s.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $s.WorkingDirectory = (Split-Path -Parent $PSCommandPath)
    $s.Description = 'Usage Meter'
    $s.Save()
}

function Start-Tray {
    $created = $false
    $mutex = New-Object Threading.Mutex($true, 'UsageMeterTraySingleInstance', [ref]$created)
    if (-not $created) { return }                       # already running
    Initialize-Ui
    [Windows.Forms.Application]::EnableVisualStyles()
    $script:settings = Read-Settings
    $script:report = $null
    $script:asOf = $null
    $script:problem = ''
    $script:run = $null
    $script:alertState = @{}
    $script:ui = New-Ui
    $ui = $script:ui
    $script:context = New-Object Windows.Forms.ApplicationContext

    $script:startCheck = {
        if ($null -ne $script:run) { return }
        $claude = Find-Claude
        if (-not $claude) { $script:problem = 'Claude Code (the claude command) was not found.'; Update-Ui $script:ui; return }
        try { $script:run = Start-UsageProcess $claude } catch { $script:problem = 'Could not start Claude Code: ' + $_.Exception.Message; Update-Ui $script:ui }
    }

    $script:syncMenu = {
        foreach ($n in $script:ui.everyItems.Keys) { $script:ui.everyItems[$n].Checked = ($script:settings.minutes -eq $n) }
        foreach ($n in $script:ui.levelItems.Keys) { $script:ui.levelItems[$n].Checked = ($script:settings.level -eq $n) }
        $script:ui.itemNotify.Checked = [bool]$script:settings.notify
        $script:ui.itemLevel.Enabled = [bool]$script:settings.notify
        $script:ui.itemStartup.Checked = (Test-Path -LiteralPath (Get-StartupLink))
    }

    $script:showPanel = {
        $f = $script:ui.form
        $bmp = New-Object Drawing.Bitmap(10, 10)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $h = Show-Limits $g 340
        $g.Dispose(); $bmp.Dispose()
        $f.ClientSize = New-Object Drawing.Size(340, ($h + 40))
        $script:ui.refresh.Location = New-Object Drawing.Point((340 - 90 - 12), ($h + 4))
        $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $f.Location = New-Object Drawing.Point(($area.Right - $f.Width - 12), ($area.Bottom - $f.Height - 12))
        $f.Show()
        $f.Activate()
    }

    $ui.canvas.Add_Paint({ param($sender, $e) [void](Show-Limits $e.Graphics 340) })
    $ui.form.Add_FormClosing({ param($sender, $e) if ($e.CloseReason -eq 'UserClosing') { $e.Cancel = $true; $sender.Hide() } })
    $ui.form.Add_Deactivate({ $script:ui.form.Hide() })
    $ui.refresh.Add_Click({ & $script:startCheck })
    $ui.icon.Add_MouseClick({ param($sender, $e)
        if ($e.Button -eq 'Left') { if ($script:ui.form.Visible) { $script:ui.form.Hide() } else { & $script:showPanel } }
    })
    $ui.menu.Add_Opening({ & $script:syncMenu })
    $ui.itemShow.Add_Click({ & $script:showPanel })
    $ui.itemRefresh.Add_Click({ & $script:startCheck })
    foreach ($it in $ui.everyItems.Values) {
        $it.Add_Click({ param($sender, $e) $script:settings.minutes = [int]$sender.Tag; Save-Settings $script:settings })
    }
    foreach ($it in $ui.levelItems.Values) {
        $it.Add_Click({ param($sender, $e) $script:settings.level = [int]$sender.Tag; Save-Settings $script:settings })
    }
    $ui.itemNotify.Add_Click({
        $script:settings.notify = -not [bool]$script:settings.notify
        Save-Settings $script:settings
        if ($script:settings.notify) {
            $script:ui.icon.ShowBalloonTip(5000, 'Usage Meter notifications are on', ('You will hear from it when a limit passes ' + $script:settings.level + '%.'), 'Info')
        }
    })
    $ui.itemStartup.Add_Click({ Set-Startup (-not (Test-Path -LiteralPath (Get-StartupLink))) })
    $ui.itemFolder.Add_Click({ [void](New-Item -ItemType Directory -Force -Path $DataDir); Start-Process explorer.exe $DataDir })
    $ui.itemQuit.Add_Click({ $script:ui.icon.Visible = $false; $script:context.ExitThread() })

    # One timer drives everything: it picks up a finished check, starts the next one when due, and
    # refreshes the icon so "out of date" shows without a click.
    $script:ticks = 0
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        try {
            if ($null -ne $script:run) {
                $run = $script:run
                if ($run.process.HasExited) {
                    $script:run = $null
                    try {
                        $script:report = Read-UsageResult $run
                        $script:asOf = Get-Date
                        $script:problem = ''
                        [void](Add-History $script:report $script:asOf)
                    } catch { $script:problem = $_.Exception.Message }
                    Update-Ui $script:ui
                } elseif (((Get-Date) - $run.started).TotalSeconds -gt 60) {
                    try { $run.process.Kill() } catch { }
                    $script:run = $null
                    $script:problem = 'Claude Code did not answer within 60 seconds.'
                    Update-Ui $script:ui
                }
            }
            $script:ticks++
            if ($script:ticks % 20 -ne 0) { return }             # the rest every 10 seconds
            if ($script:settings.notify -and $null -ne $script:report) {
                $rules = @{ level = [double]$script:settings.level; pace = [bool]$script:settings.pace; reset = [bool]$script:settings.reset }
                foreach ($ev in (Get-Alerts $script:report $script:alertState $rules (Get-Date))) {
                    if ((Test-Stale) -and ($ev.title -notlike '* has reset')) { continue }
                    $script:ui.icon.ShowBalloonTip(8000, $ev.title, $ev.body, 'Info')
                }
            }
            $minutes = [int]$script:settings.minutes
            $age = [double]::PositiveInfinity
            if ($null -ne $script:asOf) { $age = ((Get-Date) - $script:asOf).TotalSeconds }
            # Automatic checks pause after 10 minutes without keyboard or mouse use.
            if ($minutes -gt 0 -and $null -eq $script:run -and $age -ge ($minutes * 60 - 15) -and [UsageMeterNative]::IdleSeconds() -lt 600) { & $script:startCheck }
            if ($script:ticks % 120 -eq 0) { Update-Ui $script:ui }
        } catch { $script:problem = $_.Exception.Message }
    })

    $ui.icon.Visible = $true
    Update-Ui $ui
    & $script:startCheck
    $timer.Start()
    [Windows.Forms.Application]::Run($script:context)
    $timer.Stop()
    $ui.icon.Dispose()
    $mutex.ReleaseMutex()
}

# ---------------------------------------------------------------- entry

if ($SelfTest) { $code = Invoke-SelfTest | Select-Object -Last 1; exit $code }
if ($Once) {
    try { Write-Output (Format-Summary (Get-UsageNow)); exit 0 }
    catch { Write-Output $_.Exception.Message; exit 1 }
}
Start-Tray
