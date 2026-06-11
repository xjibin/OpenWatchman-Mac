#!/bin/bash
#
# OpenWatchman — sort newly added files into Year/Month folders on macOS.
#
# Watches a folder (default: ~/Downloads) and files every NEW arrival into
# a subfolder like 2026/6/ based on the moment it arrived.
#
# Safety rules, enforced in code — these are the contract of this project:
#
#   * Files only. Never moves folders. Never recurses into subfolders.
#   * Only files added AFTER the install baseline are eligible. Everything
#     that was already in the folder when you installed stays untouched,
#     forever, even though the script scans the whole folder every run.
#   * "Added" means the moment the file arrived in the folder (Spotlight's
#     kMDItemDateAdded). If Spotlight hasn't indexed the file yet, the
#     file's modification time is used instead. A file with no readable
#     date is SKIPPED — a missing date is never treated as "new".
#   * Skips dotfiles and in-progress downloads
#     (.crdownload / .download / .part / .partial / .tmp).
#   * Waits for a file's size to hold steady before moving it, so a
#     slowly-written file is never grabbed mid-write.
#   * Never overwrites. A name collision gets a timestamp suffix instead.
#   * Every move is appended to ~/Library/Logs/openwatchman.log.
#   * Zero network access. Nothing leaves this Mac.
#
# Usage:
#   openwatchman.sh              normal run (this is what launchd calls)
#   openwatchman.sh --dry-run    print what WOULD move; move nothing
#   openwatchman.sh --version    print version
#   openwatchman.sh --help       show help
#
# Environment overrides:
#   OPENWATCHMAN_DIR        folder to watch (default: ~/Downloads)
#   OPENWATCHMAN_BASELINE   epoch-seconds override for the baseline, for
#                           testing and sweeps. Example — preview sorting
#                           EVERY loose file, then do it:
#                             OPENWATCHMAN_BASELINE=1 openwatchman.sh --dry-run
#                             OPENWATCHMAN_BASELINE=1 openwatchman.sh

set -u

VERSION="1.0.0"

WATCH_DIR="${OPENWATCHMAN_DIR:-$HOME/Downloads}"
MARKER="$WATCH_DIR/.openwatchman-baseline"
LOG="$HOME/Library/Logs/openwatchman.log"

usage() {
  cat <<'EOF'
OpenWatchman — sort newly added files into Year/Month folders.

  openwatchman.sh              normal run (used by launchd)
  openwatchman.sh --dry-run    show what would move; move nothing
  openwatchman.sh --version    print version
  openwatchman.sh --help       this help

Environment:
  OPENWATCHMAN_DIR        folder to watch (default: ~/Downloads)
  OPENWATCHMAN_BASELINE   epoch seconds; only files added after this moment
                          are eligible (overrides the marker file)
EOF
}

# --- arguments: anything unexpected is an error, never a silent real run ---
DRYRUN=0
case "${1:-}" in
  "")        : ;;
  --dry-run) DRYRUN=1 ;;
  --version) echo "OpenWatchman $VERSION"; exit 0 ;;
  --help|-h) usage; exit 0 ;;
  *)
    echo "openwatchman: unknown argument: ${1}" >&2
    usage >&2
    exit 1
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "openwatchman: too many arguments" >&2
  exit 1
fi

# say: print only in dry-run mode (normal launchd runs stay quiet)
say() {
  if [ "$DRYRUN" = "1" ]; then
    echo "$@"
  fi
  return 0
}

# --- platform guard ---------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "openwatchman: macOS only (uses BSD date/stat and Spotlight's mdls)" >&2
  exit 1
fi

# --- baseline: only files added strictly after this epoch are eligible ------
if [ -n "${OPENWATCHMAN_BASELINE:-}" ]; then
  BASELINE="$OPENWATCHMAN_BASELINE"
else
  if [ ! -f "$MARKER" ]; then
    say "DRY RUN: no baseline marker at $MARKER — is OpenWatchman installed? Nothing to do."
    exit 0
  fi
  BASELINE="$(cat "$MARKER" 2>/dev/null)"
fi
case "$BASELINE" in
  ''|*[!0-9]*)
    say "DRY RUN: baseline '$BASELINE' is not a plain epoch number. Nothing to do."
    exit 0
    ;;
esac

if [ ! -d "$WATCH_DIR" ]; then
  say "DRY RUN: watch folder $WATCH_DIR does not exist. Nothing to do."
  exit 0
fi

# --- helpers -----------------------------------------------------------------
# in-progress / partial download extensions to ignore
is_partial() {
  case "${1##*.}" in
    crdownload|download|part|partial|tmp) return 0 ;;
    *) return 1 ;;
  esac
}

# convert an `mdls -raw` date string ("2026-06-11 14:23:01 +0000") to epoch
mdls_date_to_epoch() {
  date -j -f "%Y-%m-%d %H:%M:%S %z" "$1" +%s 2>/dev/null
}

# --- main loop ---------------------------------------------------------------
scanned=0
eligible=0

shopt -s nullglob
for f in "$WATCH_DIR"/*; do
  [ -f "$f" ] || continue                  # files only — every folder is skipped
  base="${f##*/}"
  case "$base" in .*) continue ;; esac     # skip dotfiles (incl. the marker)
  is_partial "$base" && continue           # skip in-progress downloads
  scanned=$((scanned + 1))

  # date the file was ADDED to the folder; fall back to mtime when unindexed
  raw="$(mdls -name kMDItemDateAdded -raw "$f" 2>/dev/null)"
  if [ -z "$raw" ] || [ "$raw" = "(null)" ]; then
    added_epoch="$(stat -f %m "$f" 2>/dev/null)"   # never treat null as "new"
  else
    added_epoch="$(mdls_date_to_epoch "$raw")"
    [ -n "$added_epoch" ] || added_epoch="$(stat -f %m "$f" 2>/dev/null)"
  fi
  case "$added_epoch" in ''|*[!0-9]*) continue ;; esac   # no usable date -> skip

  # eligible only if added AFTER the baseline
  [ "$added_epoch" -gt "$BASELINE" ] || continue
  eligible=$((eligible + 1))

  year="$(date -r "$added_epoch" +%Y)"
  month="$(( 10#$(date -r "$added_epoch" +%m) ))"   # no leading zero: 6, not 06
  dest="$WATCH_DIR/$year/$month"

  if [ "$DRYRUN" = "1" ]; then
    echo "WOULD MOVE: $base  ->  $year/$month/"
    continue
  fi

  # stability check: size must hold steady (skip half-written files)
  s1="$(stat -f %z "$f" 2>/dev/null)"
  sleep 1
  s2="$(stat -f %z "$f" 2>/dev/null)"
  [ "$s1" = "$s2" ] || continue

  mkdir -p "$dest"
  target="$dest/$base"
  if [ -e "$target" ]; then                # never clobber a same-name file
    stamp="$(date +%s)-$$"
    if [ "$base" = "${base##*.}" ]; then   # no extension
      target="$dest/${base}-$stamp"
    else
      target="$dest/${base%.*}-$stamp.${base##*.}"
    fi
  fi
  if mv -n "$f" "$target"; then
    echo "$(date '+%F %T')  moved  $base  ->  $year/$month/" >> "$LOG" 2>/dev/null
  fi
done

if [ "$DRYRUN" = "1" ]; then
  echo "DRY RUN: scanned $scanned file(s); $eligible would move (baseline=$BASELINE). Nothing was moved."
fi

exit 0
