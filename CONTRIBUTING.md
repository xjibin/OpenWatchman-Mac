# Contributing

Thanks for taking a look. OpenWatchman's whole value is that it stays small
and auditable, so contributions are judged first on whether they keep it that
way.

## Principles (please don't regress these)

- **No dependencies** beyond tools that ship with macOS.
- **No network access, ever.** No telemetry, no update checks, no analytics.
- **No pre-built binaries in the repo.** Anything compiled is generated on the
  user's machine at install time.
- **Readable over clever.** Someone should be able to read the whole engine in
  one sitting and trust it.
- **Fail safe.** When a date can't be read or state is ambiguous, skip the
  file — never guess and move it.

## Before opening a PR

1. Run ShellCheck locally — CI runs it on every push and must stay green:
   ```bash
   shellcheck bin/openwatchman.sh install.sh uninstall.sh
   ```
2. Syntax-check:
   ```bash
   bash -n bin/openwatchman.sh install.sh uninstall.sh
   ```
3. Exercise `--dry-run` for any change to the sorting or reconciliation logic
   and paste the before/after output in the PR. Because the core logic is
   macOS-specific (`mdls`, `stat -f`, BSD `date`), a dry-run on a real Mac is
   the meaningful test.
4. If you change safety-relevant behavior (what is eligible, what gets moved,
   what gets skipped), say so explicitly and update `SECURITY.md` and the
   README to match.

## Good first contributions

- Configurable folder-name format (e.g. `2026/06` or `2026/June`).
- Optional support for watching more than one folder from a single install.
- A demo GIF for the README.
- A Homebrew tap.

## Scope

Bug fixes, safety hardening, docs, and small ergonomic options are very
welcome. Large features that add dependencies, background network behavior, or
significant complexity are likely out of scope — open an issue to discuss
before building.
