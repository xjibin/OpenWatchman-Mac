# OpenWatchman for macOS

[![ShellCheck](https://github.com/xjibin/OpenWatchman-Mac/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/xjibin/OpenWatchman-Mac/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A tiny, fully auditable macOS agent that files every **new** download and
screenshot into `~/Downloads/YEAR/MONTH/` — and never touches anything that
was already there.

```
~/Downloads/
├── 2026/
│   ├── 5/
│   └── 6/          <- new arrivals land here automatically
├── 2025/
└── (everything that existed before install stays exactly where it was)
```

When July starts, the first file that arrives simply creates `2026/7/` on the
spot. No scheduled jobs, no maintenance, no app running in the background —
macOS's own `launchd` wakes a ~190-line bash script only when the folder
changes or when you log in.

## Why you can trust it

This project is designed to be **verified, not believed**:

- **One small script is the entire engine.** [`bin/openwatchman.sh`](bin/openwatchman.sh)
  is plain bash you can read top to bottom in five minutes. The installer and
  uninstaller are equally short.
- **No binaries in this repo — nothing pre-built to take on faith.** The app
  wrapper that holds the Full Disk Access permission is generated **on your
  Mac, at install time**, by Apple's own `osacompile`. You can read the
  one-line command it wraps in [`install.sh`](install.sh).
- **Zero network access. Zero telemetry. Zero dependencies** beyond tools
  that ship with macOS (`bash`, `mdls`, `date`, `stat`, `launchctl`,
  `osacompile`).
- **Nothing runs on `curl | bash`.** You clone it, read it, then run it.
- **ShellCheck-linted in CI** on every push.

### Hard safety rules (enforced in code, not in promises)

1. **Files only.** Folders are never moved, and the script never recurses
   into subfolders.
2. **Pre-existing files are permanently safe.** At install time a baseline
   marker (a hidden file holding an epoch timestamp) is written. A file is
   eligible to move **only if it arrived after that moment** — so everything
   already in the folder is excluded forever, even though the script scans
   the whole folder on every run.
3. **"Arrived" means arrived.** Eligibility and destination both use
   Spotlight's `kMDItemDateAdded` — the moment the file landed in the folder —
   not the file's internal creation date. A PDF created in 2023 that you
   download today goes to *today's* folder. If Spotlight hasn't indexed a
   file yet, its modification time is used instead, and a file with **no
   readable date is skipped — a missing date is never treated as "new"**.
4. **In-progress downloads are skipped** (`.crdownload`, `.download`,
   `.part`, `.partial`, `.tmp`), and a file's size must hold steady for a
   second before it is moved, so half-written files are never grabbed.
5. **Nothing is ever overwritten.** A name collision gets a timestamp suffix.
6. **Every move is logged** to `~/Library/Logs/openwatchman.log`.
7. **Dry-run everything.** `--dry-run` prints exactly what would move,
   moves nothing, and always ends with a summary line — it is never silent.

### Audit it yourself in five minutes

```bash
# the whole engine, ~190 lines:
less bin/openwatchman.sh

# no network code anywhere:
grep -RInE 'curl|wget|nc |/dev/tcp|http' bin/*.sh install.sh uninstall.sh
# (no output = no matches)

# the only deletions in the project are install/uninstall removing their own files:
grep -nE '\brm -' install.sh uninstall.sh
```

## Install

```bash
git clone https://github.com/xjibin/OpenWatchman-Mac.git
cd OpenWatchman-Mac

# read the three scripts first — that is the point of this repo
./install.sh
```

The installer prints its full plan and asks before doing anything. It
installs, per-user and without sudo:

| Piece | Path |
|---|---|
| Sorter script | `~/.local/bin/openwatchman.sh` |
| App wrapper (built locally) | `~/Applications/OpenWatchman.app` |
| Baseline marker | `~/Downloads/.openwatchman-baseline` |
| LaunchAgent | `~/Library/LaunchAgents/com.openwatchman.agent.plist` |
| Logs | `~/Library/Logs/openwatchman.log` (+ `.out.log` / `.err.log`) |

### The one manual step: Full Disk Access

`~/Downloads` is privacy-protected by macOS (TCC). A background agent cannot
pop the "allow access?" dialog the way a terminal app can, so you grant the
permission once by hand:

1. **System Settings → Privacy & Security → Full Disk Access**
2. Click **+**, press **Cmd+Shift+G**, type `~/Applications`, select
   **OpenWatchman**, click Open, and make sure its toggle is **on**.
3. Reload the agent (the installer prints these two lines for you):

```bash
launchctl bootout gui/$(id -u)/com.openwatchman.agent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openwatchman.agent.plist
```

**Why an app wrapper instead of granting access to `/bin/bash`?** Full Disk
Access given to bash extends to *every* bash script on your Mac. The
generated `OpenWatchman.app` scopes the permission to this one tool — and
because it is built locally by `osacompile` at install time, there is no
downloaded binary to trust and no Gatekeeper warning.

### Verify it works

Download any small file (or take a screenshot, if you chose the redirect),
wait ~15 seconds, then:

```bash
tail -3 ~/Library/Logs/openwatchman.log
```

You should see a fresh `moved  <file>  ->  2026/6/` line.

## Usage

```bash
# preview what would move right now (moves nothing, never silent):
~/.local/bin/openwatchman.sh --dry-run

# optionally sort the files that existed BEFORE you installed —
# preview first, then run for real:
OPENWATCHMAN_BASELINE=1 ~/.local/bin/openwatchman.sh --dry-run
OPENWATCHMAN_BASELINE=1 ~/.local/bin/openwatchman.sh
```

Watching a different folder: set it at install time —
`OPENWATCHMAN_DIR="$HOME/Desktop" ./install.sh`. The chosen folder is baked
into the agent and the app wrapper. (v1 watches one folder per install.)

## How it works

- A `launchd` LaunchAgent with `WatchPaths` on the folder fires the script
  the instant anything in the folder changes, plus once at every login
  (`RunAtLoad`) — which covers "first unlock of a new month" and anything
  that arrived while you were logged out. Eligibility is baseline-based, so
  a file that is somehow missed in the moment is simply picked up on the
  next trigger; nothing is ever missed permanently.
- For each top-level file, the script reads `kMDItemDateAdded`, checks it
  against the baseline marker, computes `YEAR/MONTH` from the arrival date
  (`2026/6`, no leading zero), creates the folder if needed, and moves the
  file with a no-clobber rename on collision.
- Browser partial files are skipped by extension; when Chrome/Safari/Firefox
  finish and rename the download, that rename re-triggers the watcher and
  the completed file is sorted.

## Troubleshooting

**Files sit in the folder and nothing happens, no errors anywhere.**
That is the Full Disk Access signature: without the permission, the agent
runs fine but literally sees an empty folder, so it exits cleanly having
done nothing. Check:

```bash
launchctl print gui/$(id -u)/com.openwatchman.agent | grep -E 'runs|last exit'
```

`runs` climbing with `last exit code = 0` while nothing moves = grant Full
Disk Access to `~/Applications/OpenWatchman.app` (step above) and reload.

**`Operation not permitted` in `~/Library/Logs/openwatchman.err.log`.**
Same fix — Full Disk Access.

**It stopped working after a macOS upgrade.** Major upgrades occasionally
reset privacy permissions. Re-check the OpenWatchman toggle in Full Disk
Access, then reload the agent.

**Do not move or rename `~/Applications/OpenWatchman.app`** — the agent
points at its absolute path. Rerun `./install.sh` if you need to rebuild it.

## Uninstall

```bash
./uninstall.sh            # removes agent, app, script; keeps marker + logs
./uninstall.sh --purge    # also removes the marker and logs
```

Your sorted `Year/Month` folders and every file in them are left untouched.
macOS does not let scripts edit the Full Disk Access list, so remove the
OpenWatchman entry there by hand afterwards.

## FAQ

**Why `2026/6` and not `2026/06` or `2026/June`?**
Design choice — no leading zeros. To change the format, edit the two lines
in `bin/openwatchman.sh` that compute `month=` and `dest=`.

**Will it reorganize my existing mess?**
Not unless you explicitly ask: the documented `OPENWATCHMAN_BASELINE=1`
sweep is the only way pre-existing files ever move, and you can dry-run it
first.

**Does it phone home, update itself, or collect anything?**
No, no, and no. There is no network code; see the audit section.

**What about files added while the Mac was asleep or off?**
They are swept at the next trigger or next login — eligibility is based on
the baseline, not on catching the event live.

**Performance?**
The script sleeps 1 second per *candidate* file (the size-stability check)
in real runs only; dry runs skip the wait. Normal operation handles one or
a few new files at a time, so this is invisible in practice.

## Requirements

macOS 12 or later (likely fine on older versions — it only uses tools that
ship with macOS). Spotlight indexing enabled for the watched folder is
recommended; without it, the modification-time fallback applies.

## License

[MIT](LICENSE)
