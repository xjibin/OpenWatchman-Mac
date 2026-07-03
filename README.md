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
spot. No scheduled jobs to manage, no maintenance — macOS's own `launchd`
wakes a small bash script when the folder changes, at login, and every few
minutes.

## Why you can trust it

This project is designed to be **verified, not believed**:

- **One small script is the entire engine.** [`bin/openwatchman.sh`](bin/openwatchman.sh)
  is plain bash you can read top to bottom. The installer and uninstaller are
  equally short.
- **No pre-built executables in this repo — nothing runnable to take on faith.** The app
  wrapper that holds the Full Disk Access permission is generated **on your
  Mac, at install time**, by Apple's own `osacompile`. You can read the
  one-line command it wraps in [`install.sh`](install.sh). The only binary
  file in the repo is a static app icon (`assets/applet.icns`) — image data,
  not code.
- **Zero network access. Zero telemetry. Zero dependencies** beyond tools
  that ship with macOS (`bash`, `mdls`, `date`, `stat`, `launchctl`,
  `osacompile`).
- **Nothing runs on `curl | bash`.** You clone it, read it, then run it.
- **ShellCheck-linted in CI** on every push.

### Hard safety rules (enforced in code, not in promises)

1. **Files only.** Folders are never moved, and the script never recurses
   below the month folders.
2. **Pre-existing files are permanently safe.** At install time a baseline
   marker (a hidden file holding an epoch timestamp) is written. A file is
   eligible to move **only if it arrived after that moment** — so everything
   already present is excluded forever.
3. **"Arrived" means arrived.** Eligibility and destination use Spotlight's
   `kMDItemDateAdded` — the moment the file landed in the folder — not the
   file's internal creation date. If Spotlight hasn't indexed a file yet, its
   modification time is used instead, and a file with **no readable date is
   skipped — a missing date is never treated as "new".**
4. **In-progress downloads are skipped** (`.crdownload`, `.download`,
   `.part`, `.partial`, `.tmp`), dataless iCloud placeholder files are never
   touched (so a move can never force a download), and a file's size must
   hold steady for a second before it is moved.
5. **Nothing is ever overwritten.** A name collision gets a timestamp suffix.
6. **Every move is logged** to `~/Library/Logs/openwatchman.log`.
7. **Dry-run everything.** `--dry-run` prints exactly what would move, moves
   nothing, and always ends with a summary line — it is never silent.
8. **Undo.** Every move is also journaled, so `openwatch undo` shows what the
   last run did and `openwatch undo --apply` puts it back.
9. **Pause.** `openwatch pause 2h` (or plain `pause`) suspends all sorting;
   `openwatch resume` re-enables it.

### Audit it yourself in a few minutes

```bash
less bin/openwatchman.sh          # the whole engine

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

## Apps with a fixed download path

Some apps let you pin a download folder, and people often point them straight
at a month folder like `~/Downloads/2026/6`. When the month rolls over, those
apps keep saving into the old folder — and because the file never passes
through the top level of `~/Downloads`, a plain folder-watcher never sees it.

OpenWatchman handles this without you touching any app's settings. Alongside
sorting the top level, every run **reconciles** files that were saved directly
into a `YEAR/MONTH` folder: if a file's real download month differs from the
folder it is sitting in, it is moved to the correct month folder. The periodic
run (every 5 minutes) means this happens even when nothing new hits the top
level at all.

**This is deliberately conservative.** A file is relocated only when **two
independent clocks agree** on the month:

- Spotlight's `kMDItemDateAdded` — when the file entered the folder, and
- the file's on-disk **birth time** (`stat -f %B`) — which survives moves.

A fresh download an app dropped into the wrong month has both clocks reading
the current month, so it moves. A file whose two clocks *disagree* is left
exactly where it is. That covers, and protects:

- an **old file you dragged into a month folder by hand** (birth time old,
  date-added recent → not touched), and
- your **already-sorted history** (birth time is move-stable, so a past bulk
  sort can never cause files to be re-piled).

**Escape hatch — pinning a file to a month yourself.** Reconciliation only
looks at strictly numeric `YEAR/MONTH` folders. If you want a file to stay in
a particular month regardless of its date, keep it in a folder whose name
isn't a bare number — e.g. `2026/6-keep/` or `2026/June-archive/`. Those are
never touched.

**Scope.** Reconciliation only operates inside `~/Downloads/<year>/<month>/`.
If an app saves somewhere else entirely (say `~/Desktop` or a custom folder
outside `~/Downloads`), point it back at `~/Downloads` or watch that folder
instead — see below.

## Usage

```bash
# preview what would move right now (moves nothing, never silent):
~/.local/bin/openwatchman.sh --dry-run

# one-time: sort/relocate files that predate install, or fix files already
# sitting in the wrong month folder. PREVIEW FIRST, then run for real:
OPENWATCHMAN_BASELINE=1 ~/.local/bin/openwatchman.sh --dry-run
OPENWATCHMAN_BASELINE=1 ~/.local/bin/openwatchman.sh
```

Watching a different folder: set it at install time —
`OPENWATCHMAN_DIR="$HOME/Desktop" ./install.sh`. The chosen folder is baked
into the agent and the app wrapper. To watch **several** folders, use the
`watch` config key (see Configuration below).

## Command-line interface

Alongside the background agent, the installer adds a small CLI — `openwatch`
(with `owm` kept as a short alias) — for
checking on OpenWatchman and running things by hand:

```text
openwatch status     installed? loaded? paused? baseline date, recent activity
openwatch preview    dry-run — what would move right now (moves nothing)
openwatch sweep      dry-run a full one-time reconcile; 'openwatch sweep --apply' runs it
openwatch run        trigger the agent to do a pass now
openwatch undo       show what the last run moved; 'openwatch undo --apply' puts it back
openwatch pause      suspend sorting — 'openwatch pause 2h' for a while, bare for until-resumed
openwatch resume     re-enable sorting after a pause
openwatch config     show settings; 'openwatch config min_age 1h' sets one
openwatch logs       recent log lines ('openwatch logs -f' to follow)
openwatch doctor     diagnostics, including a Full Disk Access hint
openwatch update     git pull your clone and install the refreshed scripts here
openwatch help       all commands
```

If `openwatch` isn't on your `PATH` after install, add `~/.local/bin` to it
(or invoke `~/.local/bin/openwatch`). From a clone you can also run
`./bin/owm`. `owm` is a short alias for the same command.

### Configuration

Everything works with zero configuration; two optional settings live in a
plain key=value file at `~/.local/share/openwatchman/config` (honoring
`$XDG_DATA_HOME`). The file is read line by line against a whitelist — it is
never executed — and unknown keys or values are simply ignored.

| Key | Default | Meaning |
|---|---|---|
| `min_age` | `0` | settle delay: a file moves only once it has been in the folder this long — bare seconds or `<n>s/m/h/d` (e.g. `90`, `45m`, `1h`) |
| `on_duplicate` | `rename` | name collision where the file is **byte-identical** to the one already at the destination: `rename` keeps today's timestamp-suffix behavior, `skip` leaves the newcomer where it is, `trash` moves it to the Trash. Different content always falls back to `rename`. |
| `notify` | `off` | `on` sends **one** macOS notification per pass that filed at least one file (never one per file). Only counts and folder names appear in it — never file names. |
| `date_format` | `yyyy/m` | shape of destination folders: `yyyy/m` (today's `2026/7`), `yyyy/mm` (`2026/07`), or `yyyy-mm` (a single top-level `2026-07` folder, no nesting). |
| `watch` | `~/Downloads` | colon-separated list of up to 4 absolute folder paths to watch. The list **replaces** the default. Each folder gets its own baseline marker; a newly added folder is never sorted on sight — its first pass only writes the marker. |

Set them with the CLI rather than by hand:

```bash
openwatch config min_age 1h   # move files only after they've settled for an hour
openwatch config              # show effective settings and where each comes from
```

The environment variables `OPENWATCHMAN_MIN_AGE`, `OPENWATCHMAN_ON_DUPLICATE`,
`OPENWATCHMAN_NOTIFY`, and `OPENWATCHMAN_DATE_FORMAT` override the file (handy
for one-off runs); `OPENWATCHMAN_DIR` watches a single folder and ignores the
`watch` list entirely.

A few caveats, stated plainly:

- **Notifications**: on modern macOS the first notification may require
  allowing notifications for "Script Editor"/osascript in System Settings →
  Notifications; nothing appears until it's allowed.
- **`date_format` never migrates anything.** Switching formats only changes
  where *new* folders are created. Old-format folders the new format doesn't
  recognize simply stop being managed — files in them are left alone forever.
  Within the nested formats, months are compared numerically, so `2026/7` and
  `2026/07` are the same month: an existing folder of either padding is reused
  and a correctly-placed file is never moved over zero-padding.
- **`watch` and instant reaction**: the agent reacts instantly only to folders
  baked into its LaunchAgent (WatchPaths) at install time. A folder configured
  afterwards is still sorted — by the periodic run every 5 minutes. Run
  `./install.sh --keep-baseline` to refresh WatchPaths for instant reaction.

## How it works

- A `launchd` LaunchAgent runs the script on three triggers: `WatchPaths`
  fires the instant the folder's **top level** changes; `RunAtLoad` fires at
  every login (covering "first unlock of a new month" and anything that
  arrived while logged out); and `StartInterval` fires every 5 minutes so
  files saved **directly into a month subfolder** — which `WatchPaths` cannot
  see — are still reconciled. Eligibility is baseline-based, so a file missed
  in the moment is simply picked up on the next trigger.
- **Phase 1** sorts top-level files into `YEAR/MONTH` by date-added.
- **Phase 2** reconciles files inside `YEAR/MONTH` folders using the
  two-clocks-agree rule described above.
- Browser partial files are skipped by extension; when the download completes
  and is renamed, that change re-triggers the watcher and the finished file is
  sorted.

## Troubleshooting

**Files sit in the folder and nothing happens, no errors anywhere.**
That is the Full Disk Access signature: without the permission, the agent
runs fine but literally sees an empty folder, so it exits cleanly having done
nothing. Check:

```bash
launchctl print gui/$(id -u)/com.openwatchman.agent | grep -E 'runs|last exit'
```

`runs` climbing with `last exit code = 0` while nothing moves = grant Full
Disk Access to `~/Applications/OpenWatchman.app` (step above) and reload.

**`Operation not permitted` in `~/Library/Logs/openwatchman.err.log`.**
Same fix — Full Disk Access.

**A file an app saved into the wrong month didn't move.** The periodic run is
every 5 minutes, so give it a few minutes. If it still doesn't move, its two
clocks probably disagree (by design it won't move then) — run
`~/.local/bin/openwatchman.sh --dry-run` to see the reasoning, or move it by
hand.

**It stopped working after a macOS upgrade.** Major upgrades occasionally
reset privacy permissions. Re-check the OpenWatchman toggle in Full Disk
Access, then reload the agent.

**Do not move or rename `~/Applications/OpenWatchman.app`** — the agent points
at its absolute path. Rerun `./install.sh` if you need to rebuild it.

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
Design choice — no leading zeros. To change the format, edit the lines in
`bin/openwatchman.sh` that compute the month and destination.

**Will it reorganize my existing mess?**
Not unless you explicitly ask: the documented `OPENWATCHMAN_BASELINE=1` run is
the only way pre-existing files ever move, and you can dry-run it first.

**Does it phone home, update itself, or collect anything?**
No, no, and no. There is no network code; see the audit section.

**What about files added while the Mac was asleep or off?**
They are swept at the next trigger or next login — eligibility is based on the
baseline, not on catching the event live.

**Performance?**
Real runs sleep 1 second per *candidate* file (the size-stability check);
dry runs skip it. Phase 2 uses `find` to look only at recently changed files
under the month folders, so it does not re-scan your whole library each cycle.

## Requirements

macOS 12 or later (likely fine on older versions — it only uses tools that
ship with macOS). Spotlight indexing enabled for the watched folder is
recommended; without it, the modification-time fallback applies.

## License

[MIT](LICENSE)
