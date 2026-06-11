# Contributing

Thanks for considering it. Two ground rules keep this project trustable:

1. **The safety rules in the README are the contract.** Files only, baseline
   marker respected, missing dates never treated as "new", no clobbering, no
   recursion, no network access, no dependencies beyond stock macOS. PRs
   that weaken any of these will be declined regardless of the feature.
2. **Everything stays human-readable.** No binaries, no minified code, no
   `curl | bash`. The app wrapper must remain generated at install time.

Practical bits:

- `shellcheck bin/openwatchman.sh install.sh uninstall.sh` must pass clean
  (CI enforces this).
- Keep the sorter compatible with the bash 3.2 that ships with macOS — no
  associative arrays, no `${var,,}`, no `readarray`.
- Test on a throwaway folder first:
  `OPENWATCHMAN_DIR=/tmp/watchtest ./install.sh` style flows, plus
  `--dry-run` before/after.
- Useful contributions: additional partial-download extensions, a
  multi-folder story, localized month-name formats behind an opt-in flag.

Open an issue before large changes so the design can be discussed first.
