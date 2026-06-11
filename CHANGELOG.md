# Changelog

## 1.0.0 — 2026-06-11

First public release. The sorting engine is the author's personal
"Mac Watchman" prototype, hardened in daily use, with these changes for
public release:

- All paths generalized (`$HOME`-relative); watched folder configurable via
  `OPENWATCHMAN_DIR` at install time.
- Strict argument handling: any unknown argument exits with an error instead
  of silently running in real mode.
- `--dry-run` is never silent: it always ends with a
  `scanned N / M would move` summary, and early exits state their reason.
- Dry runs skip the per-file 1-second stability wait (real runs keep it),
  so previews of large folders are instant.
- App wrapper is generated at install time by `osacompile` (no committed
  binaries), ad-hoc signed, and marked `LSUIElement` so it never bounces in
  the Dock when it fires.
- Baseline marker renamed to `.openwatchman-baseline`; installer resets it
  to "now" by default (`--keep-baseline` to resume an older one).
- Added installer/uninstaller with printed plans and confirmation prompts,
  ShellCheck CI, MIT license, SECURITY and CONTRIBUTING docs.
