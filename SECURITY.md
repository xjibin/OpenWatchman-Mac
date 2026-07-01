# Security

OpenWatchman is deliberately small so its security properties can be checked
by reading it. This document is an honest account of what it does, what it
cannot do, and where the residual risk lives.

## What it does with your files

- Moves **files** (never folders) that arrive **after install** from the top
  level of the watched folder into `YEAR/MONTH` subfolders, and relocates
  files that were saved directly into a `YEAR/MONTH` subfolder to the folder
  matching their true download month.
- Uses `mv` on the same volume — a rename, not a copy — so file contents are
  never read, duplicated, or transmitted.
- Never overwrites: a name collision produces a timestamped copy name.
- Logs every move to `~/Library/Logs/openwatchman.log`.

## What it cannot do

- **No network access.** There is no code that opens a socket, resolves a
  host, or runs `curl`/`wget`. You can confirm this:
  ```bash
  grep -RInE 'curl|wget|nc |/dev/tcp|http' bin/*.sh install.sh uninstall.sh
  ```
- **No privilege escalation.** Everything installs per-user. The installer
  refuses to run as root.
- **No self-update, no telemetry, no analytics.** The script is exactly what
  you cloned until you change it yourself.
- **No pre-built binaries.** The only compiled artifact — the app wrapper
  that carries Full Disk Access — is produced on your Mac at install time by
  Apple's `osacompile`. This repository ships no binaries.

## Trust boundaries and residual risk

Being honest about the parts that are not zero-risk:

1. **The installed script is user-writable.** `~/.local/bin/openwatchman.sh`
   is owned by you and runs with Full Disk Access via the app wrapper. Any
   process already running as your user could modify it. This is inherent to a
   per-user launch agent; OpenWatchman does not weaken your account's
   security, but it does not add a sandbox around itself either. If you want
   defense in depth, make the installed script read-only
   (`chmod 444 ~/.local/bin/openwatchman.sh`) and re-run the installer when
   you intend to update it.

2. **Full Disk Access is a broad permission.** It is granted to the
   `OpenWatchman.app` wrapper, not to `/bin/bash`, which is the tighter of the
   available options — but Full Disk Access still means the wrapper *can*
   read your protected folders. The script only ever uses it to `stat`, read
   dates via `mdls`, and `mv` within the watched folder, and you can verify
   that by reading it. Grant it only after you have read the code.

3. **The reconciliation pass moves files between month folders by date.** It
   is intentionally conservative — a file moves only when Spotlight's
   date-added and the file's on-disk birth time agree on a month — but it does
   mean that, within numeric `YEAR/MONTH` folders, placement is driven by the
   file's download date rather than by where you last dragged it. If you want
   to pin a file to a specific month by hand, keep it in a folder whose name
   is **not** a bare number (e.g. `2026/6-keep/`); non-numeric folders are
   never touched. See the README's "Apps with a fixed download path" section.

4. **Spotlight dependency.** Date-added comes from Spotlight (`mdls`). If
   indexing is disabled for the volume, the script falls back to modification
   time and skips anything with no readable date — it fails safe (skips)
   rather than guessing.

## Reporting a vulnerability

Please report suspected vulnerabilities privately through GitHub's **Private
vulnerability reporting** on this repository (Security tab) rather than
opening a public issue. A best-effort acknowledgement will follow; this is a
small hobby project maintained without any guaranteed response time.
