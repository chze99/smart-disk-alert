# smart-disk-alert

A daily disk-health check for **Windows, macOS and Linux** that **emails you only when something is wrong or has changed**. A quiet mailbox means healthy drives.

It uses [smartmontools](https://www.smartmontools.org/) (`smartctl`) to read every drive's SMART attributes, and **never runs a self-test**, so it costs the drives nothing. One PowerShell script, no other dependencies.

## What it alerts on

| Level | Condition |
|---|---|
| CRITICAL | SMART overall-health = FAILED |
| CRITICAL | SATA: sectors pending reallocation, or offline-uncorrectable sectors (any > 0) |
| CRITICAL | NVMe: media/data-integrity errors, or any critical-warning flag |
| WARN | SATA: reallocated sectors > 0 |
| WARN | Temperature above 55 C |
| WARN | NVMe: available spare under 90 %, or wear (percentage used) over 80 % |
| CHANGED | reallocated / pending / uncorrectable / CRC / media-error counters **went up since the last check** |

The CRC error counter (SMART attribute 199) is deliberately only reported when it **rises**. It is a lifetime counter, so a second-hand drive carries its previous owner's count forever and an absolute threshold would nag every day. A rising CRC count usually means a bad SATA cable or port.

The thresholds are three variables at the top of `check-smart.ps1` (`$TEMP_WARN`, `$SPARE_MIN`, `$USED_MAX`).

> **Platform status: Windows is tested; macOS and Linux are untested.** The macOS and Linux support (PowerShell 7, `smartctl` lookup, launchd/cron setup) was written carefully but has **never been run on a real Mac or Linux machine**. This matters more here than in the other tools, because how `smartctl` labels and reads drives differs between systems. It may need small fixes on yours. If something breaks, please open an issue and include your OS, version, drive type and the output of `sudo smartctl --scan` and `sudo smartctl -a /dev/<your drive>`.

## Limitations (please read)

- Runs on **Windows, macOS and Linux**: Windows PowerShell 5.1 or 7 on Windows, **PowerShell 7 (`pwsh`)** on macOS/Linux, plus `smartctl` from smartmontools everywhere. The Windows setup is the most tested; see "Platform notes".
- **Needs administrator / root rights** (raw disk access). Run it as SYSTEM (Windows) or root (macOS/Linux) from a scheduler, or from an elevated shell / `sudo`.
- **Drives behind some USB enclosures or RAID controllers do not expose SMART** to `smartctl`; those drives are simply not listed. If no device is found at all the script logs `no devices found (not running as admin?)`.
- **macOS:** smartctl often cannot read SMART from Apple's built-in SSD (especially on Apple Silicon Macs); external drives depend on the enclosure. On such a Mac the script may find no devices or only the external ones.
- **Email goes through plain SMTP** with a username and password, via `Send-MailMessage` (marked obsolete by Microsoft but still present in Windows PowerShell 5.1). For Gmail you need 2-step verification and an **app password**; your normal password will not work. The mail path was written for Gmail (`smtp.gmail.com:587`, STARTTLS) and not tested with other providers.
- SMART is an early-warning aid, not a guarantee: drives can fail with all attributes "PASSED". Keep backups.
- Warnings such as "reallocated sectors > 0" repeat every day while true; only the counter-rise alerts are one-off.
- Not Malaysia specific: no region limits.

## Setup

1. Install smartmontools, and on macOS/Linux also PowerShell 7:
   - **Windows:** the installer from smartmontools.org. The default path `C:\Program Files\smartmontools\bin\smartctl.exe` is used; otherwise `smartctl` is looked up on your `PATH`.
   - **macOS:** `brew install smartmontools` and `brew install --cask powershell`.
   - **Debian/Ubuntu:** `sudo apt install smartmontools`; **Fedora/RHEL:** `sudo dnf install smartmontools`. PowerShell 7: <https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux>.
   - On macOS/Linux `smartctl` is found in `/usr/sbin`, `/usr/local/sbin`, `/opt/homebrew/sbin` or on `PATH`. Check with `pwsh -Version` and `sudo smartctl --scan`.
2. Download or clone this repo, e.g. to `C:\smart-disk-alert` (Windows) or `/opt/smart-disk-alert` (macOS/Linux, so root can read it).
3. Copy `config.example.json` to `config.json` and fill in your SMTP details (`smtp_pass` = Gmail app password, `to` = where alerts go). `config.json` is git-ignored: **never commit it**. On macOS/Linux: `chmod 600 config.json`.
4. Try it without sending any mail. It prints the report and writes `test-report.txt`:

   ```powershell
   # Windows, administrator PowerShell
   powershell -ExecutionPolicy Bypass -File .\check-smart.ps1 -TestOnly
   ```

   ```bash
   # macOS / Linux
   sudo pwsh -NoProfile -File ./check-smart.ps1 -TestOnly
   ```

5. Run it daily at 08:00. Pick your system:

   **Windows**, as SYSTEM (administrator PowerShell):

   ```powershell
   $a   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\smart-disk-alert\check-smart.ps1'
   $t   = New-ScheduledTaskTrigger -Daily -At 8:00am
   $sys = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
   $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
   Register-ScheduledTask -TaskName "SMART Daily Check" -Action $a -Trigger $t -Principal $sys -Settings $set
   ```

   The settings matter: by default Windows refuses to start a task on battery power and never catches up a run missed while the PC was off.

   **Linux (cron, as root).** Create `/etc/cron.d/smart-disk-alert` (cron.d files name the user):

   ```cron
   0 8 * * * root pwsh -NoProfile -File /opt/smart-disk-alert/check-smart.ps1
   ```

   If `pwsh` is not on cron's `PATH`, use its full path (`which pwsh`). A systemd timer works equally well. Cron skips a run if the machine was off at 08:00; if that matters, use `anacron` or a systemd timer with `Persistent=true`.

   **macOS (launchd, as root).** Create `/Library/LaunchDaemons/com.example.smart-disk-alert.plist` (fix the pwsh path; `which pwsh`):

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0"><dict>
     <key>Label</key><string>com.example.smart-disk-alert</string>
     <key>ProgramArguments</key><array>
       <string>/opt/homebrew/bin/pwsh</string><string>-NoProfile</string>
       <string>-File</string><string>/opt/smart-disk-alert/check-smart.ps1</string>
     </array>
     <key>StartCalendarInterval</key><dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
   </dict></plist>
   ```

   ```bash
   sudo chown root:wheel /Library/LaunchDaemons/com.example.smart-disk-alert.plist
   sudo launchctl load /Library/LaunchDaemons/com.example.smart-disk-alert.plist
   ```

   launchd runs a calendar job that was missed during sleep when the Mac wakes up.

## Platform notes

- **Tested:** Windows 11 with Windows PowerShell 5.1, against four real drives (SATA and NVMe). **Not yet tested on real macOS or Linux machines**, and the email path is untested everywhere in this public copy (it needs your SMTP login).
- **Linux/macOS device types:** `smartctl --scan` labels ordinary SATA disks `-d scsi` there, and forcing that type hides their ATA attributes, so on those systems the script lets smartctl auto-detect instead. NVMe drives are read with `-d nvme` as before. If a drive shows up with no attributes on your machine, run `sudo smartctl -a /dev/sdX` by hand and report what it prints.
- The script stops with a clear message if `smartctl` is missing, or (macOS/Linux) if it is not run as root.

## How it works

1. `smartctl --scan` lists the drives; for each one the script reads health, temperature, power-on hours and the relevant attributes as JSON.
2. It compares the counters with `last-state.json` (keyed by drive serial number, or device name if there is none) from the previous run.
3. If there is at least one issue it sends one email listing the problems and a one-line status for every drive. No issues: no email, only a line in `smart.log`.

The email subject starts with `[CRITICAL]` or `[warning]`. If the mail cannot be sent the reason is written to `smart.log`.

## Files

| File | Purpose | In git? |
|---|---|---|
| `check-smart.ps1` | the script | yes |
| `config.example.json` | SMTP settings template | yes |
| `config.json` | **your** SMTP login | no (git-ignored) |
| `last-state.json`, `smart.log`, `test-report.txt` | state and logs; they contain drive serial numbers and your PC name | no (git-ignored) |

## Support

This tool is free and maintained in spare time. If it saved you time, you can star the repo, report problems or send a fix, or [buy me a coffee](https://buymeacoffee.com/raizer99). Thank you!

## License

MIT, see [LICENSE](LICENSE).
