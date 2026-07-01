# Changelog

All notable changes to this project are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/); this project uses
simple `MAJOR.MINOR.PATCH` tags.

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
