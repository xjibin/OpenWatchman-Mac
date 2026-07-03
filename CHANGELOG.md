# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/); this project uses
simple `MAJOR.MINOR.PATCH` tags.

## [1.6.1] — 2026-07-03

### Fixed
- `OPENWATCHMAN_DIR` no longer passes through the watch-list colon splitter.
  It is defined as exactly one directory, and colons are legal in macOS
  pathnames — a path containing one would have silently become two bogus
  watch folders.
- Stale Phase 2 reference files (stranded in the state dir by a crashed or
  killed pass) are now cleaned up at the start of every real run. Dry runs
  and paused runs remain completely side-effect-free.

### Changed
- The engine refuses to watch the filesystem root or `$HOME` itself even if
  a hand-edited config lists them (one `refused unsafe watch folder` log
  line per pass; the entry is skipped, the rest of the list still runs).
  The CLI setter already rejected both; this closes the hand-edit path.

## [1.6.0] — 2026-07-03

### Added
- **Opt-in notifications (`notify`, default `off`).** With `notify=on` (or
  `OPENWATCHMAN_NOTIFY=on`), the engine sends exactly **one** macOS
  notification per pass that filed at least one file — never one per file.
  Only counts and watch-folder names are interpolated into the AppleScript
  string (never file names), with quotes and backslashes stripped, so no name
  can break out of it. A failing `osascript` never fails the run; dry runs and
  `undo` never notify.
- **Date format (`date_format`, default `yyyy/m`).** Destination folder shape:
  `yyyy/m` (today's `2026/7`), `yyyy/mm` (`2026/07`), or `yyyy-mm` (single
  top-level `2026-07` folder). Nested formats reuse a numerically-equal month
  folder of either padding style, so a month is never split across `7` and
  `07`, and reconciliation compares months numerically so a file is never
  relocated over zero-padding. Switching formats migrates nothing: folders the
  new format doesn't recognize simply stop being managed.
- **Multiple watch folders (`watch`).** A colon-separated list of up to 4
  absolute paths that replaces the default `~/Downloads`. Each folder keeps
  its own baseline marker; a configured folder without one is **never sorted
  on sight** — the first pass only initializes its marker. With several
  folders, log lines carry a `[folder]` prefix and `openwatch status` /
  `doctor` report each folder and baseline. `install.sh` renders one
  WatchPaths entry per folder; a folder added after install is picked up by
  the periodic 5-minute run (the `config` setter says so and points at
  `./install.sh --keep-baseline`). `OPENWATCHMAN_DIR` still forces a single
  folder and ignores the list.
- **Dataless-file guard.** Files whose BSD flags include `SF_DATALESS`
  (iCloud placeholders) are skipped silently, so a move can never force a
  download.

### Changed
- Phase 2 now recognizes managed year folders only when the name is
  exactly four digits (e.g. `2026`); previously any all-numeric folder
  name qualified. Folders you name yourself are unaffected either way.

### Notes
- **Defaults preserve existing behavior.** With nothing configured — no
  notify, no date_format, no watch list — sorting, folder shapes, log format,
  and baseline handling are exactly as in 1.5.0.

## [1.5.0] — 2026-07-03

### Added
- **Move journal + `openwatch undo`.** Every real move the engine makes is
  appended to a tab-separated journal in `~/.local/share/openwatchman/`
  (honoring `$XDG_DATA_HOME`). `openwatch undo` prints a dry-run restore plan
  for the last sorting run — classifying each file as restorable, moved since,
  or blocked by an occupied slot — and `openwatch undo --apply` puts the
  restorable ones back (never overwriting anything). Restores are journaled
  too, so a further `undo` targets the run before. The journal is trimmed
  automatically (to its last 1000 lines once it passes 2000).
- **Settle delay (`min_age`).** Optional: a file becomes eligible only once
  its date-added — the same clock that picks the month — is at least this old.
  Bare seconds or `<n>s/m/h/d` (e.g. `45m`, `1h`), set via
  `openwatch config min_age 1h` or the `OPENWATCHMAN_MIN_AGE` environment
  variable. Default `0` (off).
- **Duplicate handling (`on_duplicate`).** Optional: when a name collision is
  **byte-identical** (same size and same SHA-256) to the file already at the
  destination, `skip` leaves the newcomer in place and `trash` moves it to the
  Trash (journaled, so `undo` can restore it). Different content — and the
  default, `rename` — keep today's timestamp-suffix behavior. Hashing only
  runs on size-equal collisions.
- **Pause / resume.** `openwatch pause` (indefinite) or `openwatch pause 30m|2h|1d`
  suspends all sorting via a flag file the engine checks before doing anything;
  an expired pause clears itself. `openwatch resume` re-enables sorting, and
  `openwatch status` / `openwatch doctor` surface the paused state prominently.
- **`openwatch config`** — show effective settings with provenance
  (env / config / default), get one value, or set one. The config file is a
  strict key=value whitelist and is never sourced.
- `uninstall.sh` now also removes the state folder (journal, config, pause
  flag, repo record).

### Notes
- **Defaults preserve existing behavior.** With nothing configured, the only
  change on upgrade is that moves are journaled; sorting, collisions, and
  timing behave exactly as in 1.4.0.

## [1.4.0] — 2026-07-01

### Added
- `openwatch update` — updates this Mac in place. It locates your clone (a path
  recorded at install time, the clone you run it from, or a short search of
  common locations), runs `git pull --ff-only`, and copies the refreshed engine
  and CLI into `~/.local/bin`. It never touches your baseline or Full Disk
  Access; if a release also changed the app or LaunchAgent it says so and points
  you at `./install.sh --keep-baseline`. If no clone is found it offers to clone
  one (opt-in) or prints how.

## [1.3.0] — 2026-07-01

### Added
- `openwatch` command. The CLI installs under the friendly name `openwatch`
  (with `owm` kept as a short alias) and refers to itself by whatever name it
  is invoked as, so its help and tips match the command you typed.
  `install.sh` creates the `openwatch` command in `~/.local/bin`.

## [1.2.1] — 2026-07-01

### Fixed
- `owm doctor` Spotlight check. It ran `mdutil -s` on the watched folder, but
  `mdutil` reports indexing state per *volume*, not per folder, so a subfolder
  returns "unknown indexing state" and the check false-warned. It now probes
  the attribute the tool actually needs — `kMDItemDateAdded` via `mdls` on a
  sample file — and warns only if that genuinely comes back null.

## [1.2.0] — 2026-07-01

### Added
- `owm` — a command-line interface, headed by an ASCII banner, with
  subcommands: `status`, `preview`, `sweep`, `run`, `logs`, `doctor`,
  `version`, `help`. `install.sh` installs it to `~/.local/bin/owm`; it drives
  the same engine the agent uses. The headless agent runs stay silent — the
  banner and CLI output are for interactive use only.

## [1.1.1] — 2026-07-01

### Added
- App icon. `assets/applet.icns` (a Liquid Glass rendering of the shield
  emblem) is committed to the repo, and `install.sh` applies it to the
  generated `OpenWatchman.app` before code-signing, so every install carries
  the icon.

### Changed
- Documentation wording: the repo contains one binary *asset* (the app icon,
  which is image data — not executable code). The trust guarantee is
  unchanged: no pre-built *executables* ship in the repo; the only runnable
  artifact, the app wrapper, is still generated locally at install time.

## [1.1.0] — 2026-07-01

### Added
- **Handling for apps with a fixed/stale download path.** Some apps are
  configured to save into a specific month folder (e.g. `~/Downloads/2026/6`)
  and keep doing so after the month changes. OpenWatchman now relocates such
  files to the folder matching their real download month, without any per-app
  reconfiguration.
- **Periodic run** via `StartInterval` (every 5 minutes) in the LaunchAgent,
  so files that bypass the watched folder's top level — which `WatchPaths`
  cannot observe — are still reconciled. `WatchPaths` and `RunAtLoad` behavior
  is unchanged.
- **Phase 2 reconciliation** in `bin/openwatchman.sh`: within strictly numeric
  `YEAR/MONTH` folders, a file is relocated only when two independent clocks
  agree on its month — Spotlight's `kMDItemDateAdded` and the file's
  move-stable on-disk birth time (`stat -f %B`). Files whose clocks disagree
  (an old file dragged in by hand, or already-sorted history) are left in
  place. Non-numeric folders (e.g. `2026/6-keep`) are never touched, giving a
  manual pinning escape hatch.

### Changed
- Dry-run output now labels actions as `WOULD SORT` (top level) and
  `WOULD RELOCATE` (month folders), and the summary reports both counts.
- Installer plan text and README document the periodic reconciliation and the
  two-clock rule; `OPENWATCHMAN_BASELINE=1` can now also fix files already
  sitting in the wrong month folder.

### Notes
- Phase 2 only ever operates inside `~/Downloads/<year>/<month>/`. Apps that
  save outside the watched folder are out of scope — point them back at the
  watched folder instead.
- Existing installs get the fix by re-running `./install.sh` (this reinstalls
  the LaunchAgent with `StartInterval`).

## [1.0.0] — 2026-07-01

### Added
- Initial public release.
- `bin/openwatchman.sh`: sorts newly added top-level files into `YEAR/MONTH`
  by Spotlight date-added, with a modification-time fallback and a
  skip-if-no-date rule.
- Baseline marker so pre-existing files are permanently excluded.
- Safety: files-only, skip in-progress downloads, size-stability check,
  no-clobber renames, per-move logging, never-silent `--dry-run`, strict
  argument handling.
- Local app-wrapper install (`osacompile`) so Full Disk Access is scoped to
  the app rather than to `/bin/bash`; ad-hoc codesigned; `LSUIElement`.
- `install.sh`, `uninstall.sh`, LaunchAgent template, ShellCheck CI, MIT
  license, and honest `SECURITY.md`.
