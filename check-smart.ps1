# Daily SMART health check. Reads attributes only -- never runs a self-test, so
# it costs the drives nothing. Mails you only when something is wrong or has
# changed since yesterday, so a quiet mailbox means healthy drives.
#
# Needs administrator / root rights (raw disk access). Run as SYSTEM (Windows) or root (macOS, Linux) from a scheduler.
# Runs on Windows (PowerShell 5.1 or 7), macOS and Linux (PowerShell 7 = pwsh). Needs smartmontools (smartctl).
#   -TestOnly   print the report, send no mail
#
# Pure ASCII on purpose: PowerShell 5.1 reads .ps1 files in the system codepage.

param([switch]$TestOnly)

$ErrorActionPreference = 'Continue'
# $IsWindows only exists in PowerShell 7; Windows PowerShell 5.1 is always Windows.
$onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows
$hostName  = [Environment]::MachineName
# smartctl lives in sbin on Linux/macOS, which a scheduler's PATH often lacks, so look in the usual places too.
$sc = $null
foreach ($c in 'C:\Program Files\smartmontools\bin\smartctl.exe', '/usr/sbin/smartctl', '/usr/local/sbin/smartctl', '/opt/homebrew/sbin/smartctl', '/usr/bin/smartctl') {
    if (Test-Path $c) { $sc = $c; break }
}
if (-not $sc) { $cmd = Get-Command smartctl -ErrorAction SilentlyContinue; if ($cmd) { $sc = $cmd.Source } }
$here      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$cfgPath   = Join-Path $here 'config.json'
$statePath = Join-Path $here 'last-state.json'
$logPath   = Join-Path $here 'smart.log'

# --- thresholds -------------------------------------------------------------
$TEMP_WARN = 55      # celsius; HDDs above this shorten their life
$SPARE_MIN = 90      # NVMe available_spare percent
$USED_MAX  = 80      # NVMe percentage_used

function Log($m) { "$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content $logPath }

if (-not $sc) { Log 'smartctl not found - install smartmontools'; "smartctl not found - install smartmontools"; exit 1 }
# On macOS/Linux reading the disks needs root. Windows reports the same problem as "no devices found" below.
if (-not $onWindows -and (& id -u) -ne '0') { Log 'not running as root - use sudo'; "not running as root - use sudo"; exit 1 }

# --- enumerate devices ------------------------------------------------------
$devices = @()
foreach ($line in (& $sc --scan 2>$null)) {
    if ($line -match '^(\S+)\s+-d\s+(\S+)') {
        $devices += [pscustomobject]@{ Dev = $matches[1]; Type = $matches[2] }
    }
}
if (-not $devices) { Log 'no devices found (not running as admin?)'; exit 1 }

$prev = $null
if (Test-Path $statePath) {
    try { $prev = Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $prev = $null }
}

$state  = @{}
$issues = New-Object System.Collections.Generic.List[string]
$report = New-Object System.Collections.Generic.List[string]

foreach ($d in $devices) {
    # On Linux/macOS --scan labels ordinary SATA disks "-d scsi", and forcing that hides their ATA attributes: let smartctl auto-detect instead.
    $dArg = if ($d.Type -eq 'scsi' -and -not $onWindows) { @() } else { @('-d', $d.Type) }
    $raw = & $sc -H -A -i -j @dArg $d.Dev 2>$null
    if (-not $raw) { $issues.Add("$($d.Dev): smartctl returned nothing"); continue }
    try { $j = $raw | ConvertFrom-Json } catch { $issues.Add("$($d.Dev): unparseable smartctl output"); continue }

    $model  = if ($j.model_name) { $j.model_name } else { 'unknown' }
    $serial = if ($j.serial_number) { $j.serial_number } else { '' }
    $tag    = "$model ($($d.Dev))"
    $vals   = @{}

    # overall health verdict
    $passed = $true
    if ($null -ne $j.smart_status) { $passed = [bool]$j.smart_status.passed }
    if (-not $passed) { $issues.Add("CRITICAL  $tag : SMART overall-health = FAILED") }
    $vals['health'] = if ($passed) { 'PASSED' } else { 'FAILED' }

    if ($j.temperature -and $null -ne $j.temperature.current) {
        $t = [int]$j.temperature.current
        $vals['temp'] = $t
        if ($t -gt $TEMP_WARN) { $issues.Add("WARN      $tag : temperature ${t}C (over $TEMP_WARN)") }
    }
    if ($j.power_on_time -and $null -ne $j.power_on_time.hours) { $vals['hours'] = [int]$j.power_on_time.hours }

    if ($d.Type -eq 'nvme' -and $j.nvme_smart_health_information_log) {
        $n = $j.nvme_smart_health_information_log
        $vals['spare']  = [int]$n.available_spare
        $vals['used']   = [int]$n.percentage_used
        $vals['media']  = [int]$n.media_errors
        $vals['critwarn'] = [int]$n.critical_warning
        if ($vals['spare'] -lt $SPARE_MIN) { $issues.Add("WARN      $tag : available spare $($vals['spare'])% (under $SPARE_MIN)") }
        if ($vals['used']  -gt $USED_MAX)  { $issues.Add("WARN      $tag : wear $($vals['used'])% (over $USED_MAX)") }
        if ($vals['media'] -gt 0)          { $issues.Add("CRITICAL  $tag : $($vals['media']) media/data integrity errors") }
        if ($vals['critwarn'] -ne 0)       { $issues.Add("CRITICAL  $tag : NVMe critical warning flags = $($vals['critwarn'])") }
    }
    elseif ($j.ata_smart_attributes -and $j.ata_smart_attributes.table) {
        foreach ($a in $j.ata_smart_attributes.table) {
            $r = 0
            if ($a.raw -and $null -ne $a.raw.value) { $r = [int64]$a.raw.value }
            switch ([int]$a.id) {
                5   { $vals['realloc'] = $r; if ($r -gt 0) { $issues.Add("WARN      $tag : $r reallocated sectors") } }
                197 { $vals['pending'] = $r; if ($r -gt 0) { $issues.Add("CRITICAL  $tag : $r sectors pending reallocation - failing now") } }
                198 { $vals['uncorr']  = $r; if ($r -gt 0) { $issues.Add("CRITICAL  $tag : $r offline uncorrectable sectors") } }
                # lifetime counter: a second-hand drive carries the previous owner's count
                # forever, so an absolute threshold would nag every day. Only a RISE since
                # the last check matters, and the compare step below reports that.
                199 { $vals['crc']     = $r }
                default { }
            }
        }
    }

    # compare with yesterday: a NEW bad sector matters far more than an old stable count
    $key = if ($serial) { $serial } else { $d.Dev }
    if ($prev -and $prev.PSObject.Properties.Name -contains $key) {
        $p = $prev.$key
        foreach ($f in 'realloc','pending','uncorr','crc','media') {
            if ($vals.ContainsKey($f) -and ($p.PSObject.Properties.Name -contains $f)) {
                $old = [int64]$p.$f; $new = [int64]$vals[$f]
                if ($new -gt $old) {
                    $hint = if ($f -eq 'crc') { '  (rising CRC = SATA cable or port going bad)' } else { '' }
                    $issues.Add("CHANGED   $tag : $f went $old -> $new since last check$hint")
                }
            }
        }
    }
    $state[$key] = $vals

    $parts = foreach ($k in 'health','temp','hours','realloc','pending','uncorr','crc','spare','used','media') {
        if ($vals.ContainsKey($k)) { "$k=$($vals[$k])" }
    }
    $report.Add(("{0,-42} {1}" -f $tag, ($parts -join '  ')))
}

$state | ConvertTo-Json -Depth 5 | Out-File $statePath -Encoding utf8

$body = @()
$body += "SMART check on $hostName at $(Get-Date -f 'yyyy-MM-dd HH:mm')"
$body += ''
if ($issues.Count) {
    $body += '!!! PROBLEMS FOUND !!!'
    $body += ''
    $issues | ForEach-Object { $body += "  $_" }
    $body += ''
}
$body += 'All drives:'
$report | ForEach-Object { $body += "  $_" }
$body += ''
$body += 'Attributes only -- no self-test was run.'
$text = $body -join "`r`n"

Log ("check done: {0} device(s), {1} issue(s)" -f $devices.Count, $issues.Count)
if ($issues.Count) { $issues | ForEach-Object { Log "  $_" } }

if ($TestOnly) {
    $text | Out-File (Join-Path $here 'test-report.txt') -Encoding utf8
    $text
    exit 0
}
if (-not $issues.Count) { exit 0 }   # quiet mailbox == healthy drives

# --- mail -------------------------------------------------------------------
if (-not (Test-Path $cfgPath)) { Log "issues found but $cfgPath is missing - no mail sent"; $text; exit 1 }
try {
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sec = ConvertTo-SecureString $cfg.smtp_pass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($cfg.smtp_user, $sec)
    $crit = ($issues | Where-Object { $_ -like 'CRITICAL*' }).Count
    $subj = if ($crit) { "[CRITICAL] disk SMART alert on $hostName" } else { "[warning] disk SMART alert on $hostName" }
    # -WarningAction: PowerShell 7 prints an "SMTP is not recommended" notice for Send-MailMessage on every call.
    Send-MailMessage -To $cfg.to -From $cfg.smtp_user -Subject $subj -Body $text `
        -SmtpServer $cfg.smtp_server -Port $cfg.smtp_port -UseSsl -Credential $cred -ErrorAction Stop -WarningAction SilentlyContinue
    Log "mail sent to $($cfg.to)"
} catch {
    Log "MAIL FAILED: $($_.Exception.Message)"
    exit 1
}

