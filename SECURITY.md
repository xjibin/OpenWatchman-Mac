# Security

## What you are granting, in plain terms

OpenWatchman asks for one sensitive thing: **Full Disk Access** for the
locally generated `~/Applications/OpenWatchman.app`. That permission is
required because `~/Downloads` is TCC-protected and background `launchd`
agents cannot trigger macOS's consent dialog.

What that means concretely:

- The wrapper app (and therefore the script it launches) can read and write
  anywhere your user account can, including other protected folders.
- The shipped script only ever touches the watched folder, its `Year/Month`
  subfolders, and its log file — verify this by reading
  [`bin/openwatchman.sh`](bin/openwatchman.sh); it is short on purpose.
- The permission is scoped to this one app, **not** to `/bin/bash`, exactly
  so that other scripts on your machine gain nothing from it.

## Residual risk you should understand

The app wrapper executes `~/.local/bin/openwatchman.sh`. Anything that can
modify that file as your user could have its code run with the app's Full
Disk Access on the next trigger. This is inherent to any user-writable
automation granted TCC permissions (the same applies to Hazel rules,
Shortcuts, etc.). Mitigations:

- The file is installed `755`, owned by you; nothing in this project ever
  makes it group- or world-writable.
- The script is small enough to re-read after any update:
  `less ~/.local/bin/openwatchman.sh`.
- If you stop using OpenWatchman, run `./uninstall.sh` **and** remove the
  app from the Full Disk Access list.

## What this project will never do

- No network access of any kind (no update checks, no telemetry).
- No `sudo`, no system-wide installation, no kernel extensions.
- No pre-built binaries in the repository — the app wrapper is generated on
  your machine by Apple's `osacompile`.

## Reporting a vulnerability

Please open a private report via GitHub Security Advisories on this
repository (Security tab → "Report a vulnerability"). If you believe users
are at active risk, say so in the report and it will be prioritized.
