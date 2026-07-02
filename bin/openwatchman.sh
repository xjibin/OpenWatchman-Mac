#!/bin/bash
#
# OpenWatchman — sort newly added files into Year/Month folders on macOS.
#
# Watches a folder (default: ~/Downloads) and files every NEW arrival into
# a subfolder like 2026/6/ based on the moment it arrived.
#
# Two phases run on every invocation:
#
#   Phase 1 — sort files that land at the TOP LEVEL of the folder into
#             YEAR/MONTH by their date-added.
#
#   Phase 2 — reconcile files that some app saved DIRECTLY into a month
#             subfolder (e.g. a browser whose download path is pinned to
#             .../2026/6). If such a file's real download month differs
#             from the folder it sits in, it is relocated to the correct
#             month folder. To stay safe, Phase 2 relocates a file ONLY
#             when two independent clocks AGREE on the month:
#               * Spotlight's kMDItemDateAdded (when it entered the folder)
#               * the file's on-disk birth time (stat -f %B; move-stable)
#             A file whose two clocks disagree — an old file you dragged
#             into a month folder by hand, or anything whose date-added was
#             rewritten by a past move — is left exactly where it is.
#
# Safety rules, enforced in code — the contract of this project:
#
#   * Files only. Never moves folders. Never recurses below month folders.
#   * Only files added AFTER the install baseline are eligible. Everything
#     that was already present at install stays untouched, forever.
#   * "Added" means when the file arrived (Spotlight kMDItemDateAdded). If
#     Spotlight hasn't indexed it, modification time is used. A file with no
#     readable date is SKIPPED — a missing date is never treated as "new".
#   * Phase 2 only touches strictly numeric  <year>/<month>  paths, so any
#     folder you name yourself (e.g. 2026/June-Archive) is never disturbed.
#   * Skips dotfiles and in-progress downloads
#     (.crdownload / .download / .part / .partial / .tmp).
#   * Waits for a file's size to hold steady before moving it.
#   * Never overwrites. A name collision gets a timestamp suffix.
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
#                           testing and one-time sweeps. Example — preview
#                           sorting/relocating EVERY eligible file:
#                             OPENWATCHMAN_BASELINE=1 openwatchman.sh --dry-run

set -u

VERSION="1.4.0"

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

# echo the epoch a file was ADDED to its folder (kMDItemDateAdded, mtime
# fallback). Echoes nothing if no usable date can be read.
added_epoch_of() {
  local file="$1" raw ep
  raw="$(mdls -name kMDItemDateAdded -raw "$file" 2>/dev/null)"
  if [ -z "$raw" ] || [ "$raw" = "(null)" ]; then
    ep="$(stat -f %m "$file" 2>/dev/null)"
  else
    ep="$(mdls_date_to_epoch "$raw")"
    [ -n "$ep" ] || ep="$(stat -f %m "$file" 2>/dev/null)"
  fi
  case "$ep" in ''|*[!0-9]*) return 1 ;; esac
  echo "$ep"
}

# move $1 into directory $2 without ever clobbering; log the action verb $3
safe_move() {
  local src="$1" destdir="$2" verb="$3" b t stamp
  b="${src##*/}"
  mkdir -p "$destdir"
  t="$destdir/$b"
  if [ -e "$t" ]; then
    stamp="$(date +%s)-$$"
    if [ "$b" = "${b##*.}" ]; then
      t="$destdir/${b}-$stamp"
    else
      t="$destdir/${b%.*}-$stamp.${b##*.}"
    fi
  fi
  if mv -n "$src" "$t"; then
    echo "$(date '+%F %T')  $verb  $b  ->  ${destdir#"$WATCH_DIR"/}/" >> "$LOG" 2>/dev/null
    return 0
  fi
  return 1
}

# size must hold steady for a second (skip half-written files)
size_is_stable() {
  local s1 s2
  s1="$(stat -f %z "$1" 2>/dev/null)"
  sleep 1
  s2="$(stat -f %z "$1" 2>/dev/null)"
  [ "$s1" = "$s2" ]
}

# ============================================================================
# Phase 1 — sort files that land at the TOP LEVEL of the watched folder
# ============================================================================
scanned=0
sorted=0

shopt -s nullglob
for f in "$WATCH_DIR"/*; do
  [ -f "$f" ] || continue                  # files only — every folder is skipped
  base="${f##*/}"
  case "$base" in .*) continue ;; esac     # skip dotfiles (incl. the marker)
  is_partial "$base" && continue           # skip in-progress downloads
  scanned=$((scanned + 1))

  added_epoch="$(added_epoch_of "$f")" || continue
  [ "$added_epoch" -gt "$BASELINE" ] || continue    # only files added after install

  year="$(date -r "$added_epoch" +%Y)"
  month="$(( 10#$(date -r "$added_epoch" +%m) ))"   # no leading zero: 6, not 06
  dest="$WATCH_DIR/$year/$month"

  if [ "$DRYRUN" = "1" ]; then
    echo "WOULD SORT: $base  ->  $year/$month/"
    sorted=$((sorted + 1))
    continue
  fi

  size_is_stable "$f" || continue
  safe_move "$f" "$dest" "moved" && sorted=$((sorted + 1))
done

# ============================================================================
# Phase 2 — reconcile files apps saved directly into a month subfolder
# ============================================================================
# Only files newer than the baseline are considered (a fresh download always
# has a fresh mtime). We build a reference file at the baseline time and let
# find do the cheap filtering, so we don't stat/mdls the whole library.
relocated=0

_ref="$(mktemp -t openwatchman.XXXXXX 2>/dev/null)" || _ref=""
if [ -n "$_ref" ] && touch -t "$(date -r "$BASELINE" +%Y%m%d%H%M.%S)" "$_ref" 2>/dev/null; then
  while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    case "$base" in .*) continue ;; esac
    is_partial "$base" && continue

    # containing folder must be exactly  $WATCH_DIR/<year>/<month>
    dir="${f%/*}"                       # .../2026/6
    monthdir="${dir##*/}"               # 6
    yeardir_path="${dir%/*}"            # .../2026
    yeardir="${yeardir_path##*/}"       # 2026
    [ "$yeardir_path" = "$WATCH_DIR/$yeardir" ] || continue
    case "$yeardir"  in ''|*[!0-9]*) continue ;; esac
    case "$monthdir" in ''|*[!0-9]*) continue ;; esac
    folder_month=$(( 10#$monthdir ))
    { [ "$folder_month" -ge 1 ] && [ "$folder_month" -le 12 ]; } || continue

    # signal 1: date added (mtime fallback) — also the eligibility gate
    added_epoch="$(added_epoch_of "$f")" || continue
    [ "$added_epoch" -gt "$BASELINE" ] || continue

    # signal 2: on-disk birth time (survives moves). No birth time -> skip.
    birth_epoch="$(stat -f %B "$f" 2>/dev/null)"
    case "$birth_epoch" in ''|*[!0-9]*) continue ;; esac

    a_year="$(date -r "$added_epoch" +%Y)"
    a_month="$(( 10#$(date -r "$added_epoch" +%m) ))"
    b_year="$(date -r "$birth_epoch" +%Y)"
    b_month="$(( 10#$(date -r "$birth_epoch" +%m) ))"

    # the two clocks must AGREE, and disagree with the current folder
    [ "$a_year" = "$b_year" ] || continue
    [ "$a_month" = "$b_month" ] || continue
    if [ "$a_year" = "$yeardir" ] && [ "$a_month" = "$folder_month" ]; then
      continue                          # already in the right place
    fi

    dest="$WATCH_DIR/$a_year/$a_month"

    if [ "$DRYRUN" = "1" ]; then
      echo "WOULD RELOCATE: $yeardir/$folder_month/$base  ->  $a_year/$a_month/"
      relocated=$((relocated + 1))
      continue
    fi

    size_is_stable "$f" || continue
    safe_move "$f" "$dest" "relocated" && relocated=$((relocated + 1))
  done < <(find "$WATCH_DIR" -mindepth 3 -maxdepth 3 -type f -newer "$_ref" -print0 2>/dev/null)
fi
[ -n "$_ref" ] && rm -f "$_ref"

if [ "$DRYRUN" = "1" ]; then
  echo "DRY RUN: scanned $scanned top-level file(s), $sorted would sort; $relocated misplaced file(s) would be relocated (baseline=$BASELINE). Nothing was moved."
fi

exit 0
