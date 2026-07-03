#!/bin/bash
#
# OpenWatchman — sort newly added files into Year/Month folders on macOS.
#
# Watches one or more folders (default: ~/Downloads) and files every NEW
# arrival into a subfolder like 2026/6/ based on the moment it arrived.
#
# Two phases run for each watched folder on every invocation:
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
#     that was already present at install stays untouched, forever. Each
#     watched folder carries its own baseline marker; a folder configured
#     later gets its marker written on the first pass and is only sorted
#     from the NEXT pass on — nothing already inside it ever moves.
#   * "Added" means when the file arrived (Spotlight kMDItemDateAdded). If
#     Spotlight hasn't indexed it, modification time is used. A file with no
#     readable date is SKIPPED — a missing date is never treated as "new".
#   * Phase 2 only touches folders matching the active date_format's shape
#     (4-digit year with numeric month folders, or top-level YYYY-MM), so any
#     folder you name yourself (e.g. 2026/June-Archive) is never disturbed.
#     Month equality is NUMERIC — 7 and 07 are the same month, and a month is
#     never split across the two padding styles.
#   * Skips dotfiles and in-progress downloads
#     (.crdownload / .download / .part / .partial / .tmp).
#   * Skips dataless iCloud placeholder files (SF_DATALESS), so a move can
#     never force a download.
#   * Waits for a file's size to hold steady before moving it.
#   * Optional settle delay: with min_age set, a file moves only once its
#     date-added — the same clock that picks the month — is at least that old.
#   * Never overwrites. A name collision gets a timestamp suffix — unless
#     on_duplicate is `skip` or `trash` AND the two files are byte-identical
#     (same size and same SHA-256): then the newcomer is left in place or
#     moved to the Trash. Different content always falls back to the rename.
#   * Every move is appended to ~/Library/Logs/openwatchman.log, and to a
#     tab-separated journal in the state folder that powers 'openwatch undo'.
#   * A pause flag file ('openwatch pause' / 'openwatch resume') suspends
#     sorting: the engine exits at once until the pause expires.
#   * Notifications are OPT-IN (notify=on): at most ONE per pass, and only
#     counts and folder names are ever interpolated — never file names.
#   * Zero network access. Nothing leaves this Mac.
#
# Usage:
#   openwatchman.sh              normal run (this is what launchd calls)
#   openwatchman.sh --dry-run    print what WOULD move; move nothing
#   openwatchman.sh --version    print version
#   openwatchman.sh --help       show help
#
# Environment overrides:
#   OPENWATCHMAN_DIR        watch ONLY this single folder, ignoring the
#                           config's watch list (default: ~/Downloads)
#   OPENWATCHMAN_BASELINE   epoch-seconds override for the baseline (applies
#                           to every watched folder), for testing and
#                           one-time sweeps. Example — preview
#                           sorting/relocating EVERY eligible file:
#                             OPENWATCHMAN_BASELINE=1 openwatchman.sh --dry-run
#   OPENWATCHMAN_MIN_AGE    settle delay — bare seconds or <n>s/m/h/d
#                           (beats the config file; default 0)
#   OPENWATCHMAN_ON_DUPLICATE
#                           rename | skip | trash for identical-content name
#                           collisions (beats the config file; default rename)
#   OPENWATCHMAN_NOTIFY     on | off — one notification per pass that moved
#                           anything (beats the config file; default off)
#   OPENWATCHMAN_DATE_FORMAT
#                           yyyy/m | yyyy/mm | yyyy-mm — destination folder
#                           shape (beats the config file; default yyyy/m)
#
# Optional config file (plain key=value lines, whitelisted keys only, NEVER
# sourced):  ${XDG_DATA_HOME:-~/.local/share}/openwatchman/config
#   recognized keys:  min_age=<n[s|m|h|d]>   on_duplicate=<rename|skip|trash>
#                     notify=<on|off>        date_format=<yyyy/m|yyyy/mm|yyyy-mm>
#                     watch=<abs dir[:abs dir...]>  (REPLACES the default list)

set -u

VERSION="1.6.1"

LOG="$HOME/Library/Logs/openwatchman.log"

STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/openwatchman"
JOURNAL="$STATE_DIR/journal.tsv"   # TSV move journal behind 'openwatch undo'
CONFIG="$STATE_DIR/config"         # optional key=value settings (never sourced)
PAUSE="$STATE_DIR/paused"          # expiry epoch; 0 = paused until resumed

NOW="$(date +%s)"                  # one clock per run: run id + settle delay
RUN_ID="$NOW.$$"
TAB=$'\t'
NL=$'\n'

usage() {
  cat <<'EOF'
OpenWatchman — sort newly added files into Year/Month folders.

  openwatchman.sh              normal run (used by launchd)
  openwatchman.sh --dry-run    show what would move; move nothing
  openwatchman.sh --version    print version
  openwatchman.sh --help       this help

Environment:
  OPENWATCHMAN_DIR        watch ONLY this single folder, ignoring the config's
                          watch list (default: ~/Downloads)
  OPENWATCHMAN_BASELINE   epoch seconds; only files added after this moment
                          are eligible (overrides the marker in every folder)
  OPENWATCHMAN_MIN_AGE    settle delay before a file may move — bare seconds
                          or <n>s/m/h/d, e.g. 45m (default: 0, move at once)
  OPENWATCHMAN_ON_DUPLICATE
                          rename (default) | skip | trash — what to do when
                          an identical file already sits at the destination
  OPENWATCHMAN_NOTIFY     on | off (default) — one notification per pass
                          that moved at least one file
  OPENWATCHMAN_DATE_FORMAT
                          yyyy/m (default) | yyyy/mm | yyyy-mm — the shape
                          of destination folders when they must be created
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

# --- pause flag: suspend everything before any baseline/marker logic ---------
# The file holds one expiry epoch (0 = paused until 'openwatch resume').
# Headless runs exit silently — the agent fires every 5 minutes and must not
# spam the log. An expired pause is cleared and the run continues normally.
if [ -f "$PAUSE" ]; then
  pause_until="$(cat "$PAUSE" 2>/dev/null)"
  case "$pause_until" in ''|*[!0-9]*) pause_until=0 ;; esac   # unreadable = stay paused
  if [ "$pause_until" -eq 0 ] || [ "$pause_until" -gt "$NOW" ]; then
    say "DRY RUN: paused ($PAUSE) — nothing to do."
    exit 0
  fi
  if [ "$DRYRUN" != "1" ]; then
    rm -f "$PAUSE"                   # pause expired — clear it and carry on
  fi
fi

# --- stale Phase 2 reference files: a crashed past run may have stranded some
# in the state dir (only the happy path removes its own). Real runs only —
# dry runs stay side-effect-free, and this sits after the pause gate so a
# paused run touches nothing at all.
if [ "$DRYRUN" != "1" ] && [ -n "$STATE_DIR" ]; then
  rm -f "$STATE_DIR"/phase2ref.* 2>/dev/null
fi

# --- journal housekeeping: keep the undo journal from growing unbounded ------
if [ "$DRYRUN" != "1" ] && [ -f "$JOURNAL" ]; then
  jl="$(wc -l < "$JOURNAL" 2>/dev/null)" || jl=0
  case "$jl" in *[0-9]*) ;; *) jl=0 ;; esac
  if [ "$jl" -gt 2000 ]; then
    # temp file next to the journal so the final mv is an atomic rename
    jt="$(mktemp "$JOURNAL.XXXXXX" 2>/dev/null)" || jt=""
    if [ -n "$jt" ]; then
      if tail -n 1000 "$JOURNAL" > "$jt" 2>/dev/null; then
        mv "$jt" "$JOURNAL"
      else
        rm -f "$jt"
      fi
    fi
  fi
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

# parse a duration — bare seconds or <n>s/m/h/d — into seconds on stdout.
# Fails on anything else. (Kept byte-identical with the copy in bin/owm —
# update both together.)
parse_duration() {
  local v="$1" n mult
  case "$v" in ''|*[!0-9smhd]*) return 1 ;; esac
  case "$v" in
    *s) n="${v%s}"; mult=1 ;;
    *m) n="${v%m}"; mult=60 ;;
    *h) n="${v%h}"; mult=3600 ;;
    *d) n="${v%d}"; mult=86400 ;;
    *)  n="$v";     mult=1 ;;
  esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( 10#$n * mult ))
}

# are $1 and $2 byte-identical? Sizes first; hash ONLY when sizes match.
same_content() {
  local a="$1" b="$2" sa sb ha hb
  sa="$(stat -f %z "$a" 2>/dev/null)"
  sb="$(stat -f %z "$b" 2>/dev/null)"
  if [ -z "$sa" ] || [ "$sa" != "$sb" ]; then return 1; fi
  ha="$(shasum -a 256 "$a" 2>/dev/null | cut -d' ' -f1)"
  hb="$(shasum -a 256 "$b" 2>/dev/null | cut -d' ' -f1)"
  if [ -z "$ha" ] || [ "$ha" != "$hb" ]; then return 1; fi
  return 0
}

# is $1 a dataless (iCloud placeholder) file? Moving one would force macOS
# to download it, so such files are skipped silently — they can be numerous.
# SF_DATALESS = 0x40000000 in the BSD file flags (stat -f %f, decimal).
is_dataless() {
  local flags
  flags="$(stat -f %f -- "$1" 2>/dev/null)"
  case "$flags" in ''|*[!0-9]*) return 1 ;; esac
  if (( flags & 0x40000000 )); then
    return 0
  fi
  return 1
}

# append one TSV line to the journal that powers 'openwatch undo'.
# Best-effort: a move is never rolled back because journaling failed.
# A path containing a tab or newline cannot live in a TSV line — such a move
# is recorded as 'unjournalable' (epoch + run id only) and undo skips it.
journal_line() {
  local verb="$1" src="$2" dst="$3"
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  case "$src$dst" in
    *"$TAB"*|*"$NL"*)
      printf '%s\t%s\tunjournalable\t\t\n' "$(date +%s)" "$RUN_ID" >> "$JOURNAL" 2>/dev/null ;;
    *)
      printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$RUN_ID" "$verb" "$src" "$dst" >> "$JOURNAL" 2>/dev/null ;;
  esac
  return 0
}

# echo the destination folder for a file added at epoch $1, honoring the
# active date_format. Nested formats REUSE a numerically-equal month folder
# of either padding style, so a month is never split across '7' and '07'.
dest_for_epoch() {
  local ep="$1" y mm m
  y="$(date -r "$ep" +%Y)"
  mm="$(date -r "$ep" +%m)"          # zero-padded: 07
  m=$(( 10#$mm ))                    # unpadded: 7
  case "$DATE_FORMAT" in
    yyyy-mm)
      echo "$WATCH_DIR/$y-$mm"
      ;;
    yyyy/mm)
      if [ -d "$WATCH_DIR/$y/$mm" ]; then
        echo "$WATCH_DIR/$y/$mm"
      elif [ -d "$WATCH_DIR/$y/$m" ]; then
        echo "$WATCH_DIR/$y/$m"
      else
        echo "$WATCH_DIR/$y/$mm"
      fi
      ;;
    *)
      if [ -d "$WATCH_DIR/$y/$m" ]; then
        echo "$WATCH_DIR/$y/$m"
      elif [ -d "$WATCH_DIR/$y/$mm" ]; then
        echo "$WATCH_DIR/$y/$mm"
      else
        echo "$WATCH_DIR/$y/$m"
      fi
      ;;
  esac
}

# move $1 into directory $2 without ever clobbering; log the action verb $3.
# On a name collision, on_duplicate=skip/trash handles a byte-identical twin
# (leave in place / move to Trash); anything else gets the timestamp rename.
safe_move() {
  local src="$1" destdir="$2" verb="$3" b t stamp rel
  b="${src##*/}"
  rel="${destdir#"$WATCH_DIR"/}"
  mkdir -p "$destdir"
  t="$destdir/$b"
  if [ -e "$t" ]; then
    if [ "$ON_DUPLICATE" != "rename" ] && same_content "$src" "$t"; then
      if [ "$ON_DUPLICATE" = "skip" ]; then
        echo "$(date '+%F %T')  duplicate  ${LOG_PREFIX}$b  (identical in $rel/, left in place)" >> "$LOG" 2>/dev/null
        return 0
      fi
      # trash: same no-clobber rename rule inside the Trash
      t="$HOME/.Trash/$b"
      if [ -e "$t" ]; then
        stamp="$(date +%s)-$$"
        if [ "$b" = "${b##*.}" ]; then
          t="$HOME/.Trash/${b}-$stamp"
        else
          t="$HOME/.Trash/${b%.*}-$stamp.${b##*.}"
        fi
      fi
      if mv -n "$src" "$t"; then
        echo "$(date '+%F %T')  duplicate  ${LOG_PREFIX}$b  (identical in $rel/, moved to Trash)" >> "$LOG" 2>/dev/null
        journal_line "moved" "$src" "$t"
        return 0
      fi
      return 1
    fi
    stamp="$(date +%s)-$$"
    if [ "$b" = "${b##*.}" ]; then
      t="$destdir/${b}-$stamp"
    else
      t="$destdir/${b%.*}-$stamp.${b##*.}"
    fi
  fi
  if mv -n "$src" "$t"; then
    echo "$(date '+%F %T')  $verb  ${LOG_PREFIX}$b  ->  $rel/" >> "$LOG" 2>/dev/null
    journal_line "$verb" "$src" "$t"
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

# opt-in: at most ONE notification per pass, only when something moved.
# Only counts and folder names are interpolated — NEVER file names — and
# backslashes/quotes are stripped so nothing can escape the AppleScript
# string. osascript failure (e.g. denied permission) never fails the run.
notify_pass() {
  [ "$NOTIFY" = "on" ] || return 0
  [ "$NOTIFY_TOTAL" -gt 0 ] || return 0
  local body="$1"
  body="${body//\\/}"
  body="${body//\"/}"
  osascript -e "display notification \"$body\" with title \"OpenWatchman\"" >/dev/null 2>&1 || true
  return 0
}

# --- optional settings: config file (whitelist, never sourced) + environment -
CFG_MIN_AGE=""
CFG_ON_DUPLICATE=""
CFG_NOTIFY=""
CFG_DATE_FORMAT=""
CFG_WATCH=""
if [ -f "$CONFIG" ]; then
  while IFS= read -r cfg_line || [ -n "$cfg_line" ]; do
    case "$cfg_line" in
      min_age=*)      CFG_MIN_AGE="${cfg_line#min_age=}" ;;
      on_duplicate=*) CFG_ON_DUPLICATE="${cfg_line#on_duplicate=}" ;;
      notify=*)       CFG_NOTIFY="${cfg_line#notify=}" ;;
      date_format=*)  CFG_DATE_FORMAT="${cfg_line#date_format=}" ;;
      watch=*)        CFG_WATCH="${cfg_line#watch=}" ;;
    esac
  done < "$CONFIG"
fi

# settle delay in seconds; an unparseable value falls back to 0 (off)
MIN_AGE=0
if [ -n "${OPENWATCHMAN_MIN_AGE:-}" ]; then
  if min_age_v="$(parse_duration "$OPENWATCHMAN_MIN_AGE")"; then MIN_AGE="$min_age_v"; fi
elif [ -n "$CFG_MIN_AGE" ]; then
  if min_age_v="$(parse_duration "$CFG_MIN_AGE")"; then MIN_AGE="$min_age_v"; fi
fi

# collision policy; anything but skip/trash means today's rename behavior
ON_DUPLICATE="rename"
case "${OPENWATCHMAN_ON_DUPLICATE:-$CFG_ON_DUPLICATE}" in
  skip)  ON_DUPLICATE="skip" ;;
  trash) ON_DUPLICATE="trash" ;;
esac

# notifications; anything but 'on' means off
NOTIFY="off"
case "${OPENWATCHMAN_NOTIFY:-$CFG_NOTIFY}" in
  on) NOTIFY="on" ;;
esac

# destination folder shape; anything unrecognized means today's yyyy/m
DATE_FORMAT="yyyy/m"
case "${OPENWATCHMAN_DATE_FORMAT:-$CFG_DATE_FORMAT}" in
  yyyy/mm) DATE_FORMAT="yyyy/mm" ;;
  yyyy-mm) DATE_FORMAT="yyyy-mm" ;;
esac

# --- effective watch folders --------------------------------------------------
# OPENWATCHMAN_DIR (a single folder) beats the config's watch= list (which
# REPLACES the default), which beats the default ~/Downloads. Auto-creating a
# missing baseline applies ONLY to config-listed folders, so an unconfigured
# upgrade behaves exactly as before.
WATCH_SOURCE="default"
WATCH_COUNT=0

# accept one resolved watch folder — from ANY source, including a hand-edited
# config file — refusing the two entries that must never be watched: the
# filesystem root and $HOME itself. A single trailing slash is normalized off.
add_watch_dir() {
  local entry="$1"
  if [ "$entry" != "/" ]; then
    entry="${entry%/}"
  fi
  if [ "$entry" = "/" ] || [ "$entry" = "${HOME%/}" ] || [ -z "$entry" ]; then
    if [ "$DRYRUN" = "1" ]; then
      say "DRY RUN: refused unsafe watch folder $1 — skipped."
    else
      echo "$(date '+%F %T')  refused unsafe watch folder $1" >> "$LOG" 2>/dev/null
    fi
    return 0
  fi
  WATCH_COUNT=$((WATCH_COUNT + 1))
  WATCH_DIRS[WATCH_COUNT]="$entry"
  return 0
}

if [ -n "${OPENWATCHMAN_DIR:-}" ]; then
  # the env override is EXACTLY ONE directory — it never passes through the
  # colon splitter (colons are legal in macOS pathnames)
  WATCH_SOURCE="env"
  add_watch_dir "$OPENWATCHMAN_DIR"
else
  watch_list="$HOME/Downloads"
  if [ -n "$CFG_WATCH" ]; then
    watch_list="$CFG_WATCH"
    WATCH_SOURCE="config"
  fi
  watch_rest="$watch_list"
  while [ -n "$watch_rest" ]; do
    watch_entry="${watch_rest%%:*}"
    if [ "$watch_rest" = "$watch_entry" ]; then watch_rest=""; else watch_rest="${watch_rest#*:}"; fi
    [ -n "$watch_entry" ] || continue
    add_watch_dir "$watch_entry"
  done
fi
if [ "$WATCH_COUNT" -eq 0 ]; then
  say "DRY RUN: no watch folders configured. Nothing to do."
  exit 0
fi

# ============================================================================
# Both phases, for one watch folder (WATCH_DIR / MARKER / LOG_PREFIX are set
# by the main loop below; counters accumulate across folders)
# ============================================================================
process_dir() {
  local f base added_epoch dest ref depth dir mdir monthdir yeardir yeardir_path
  local folder_year folder_month birth_epoch a_year a_month b_year b_month dirrel

  if [ ! -d "$WATCH_DIR" ]; then
    if [ "$WATCH_SOURCE" = "config" ]; then
      if [ "$DRYRUN" = "1" ]; then
        say "DRY RUN: watch folder $WATCH_DIR does not exist — skipped."
      else
        echo "$(date '+%F %T')  skipped missing watch folder $WATCH_DIR" >> "$LOG" 2>/dev/null
      fi
      return 0
    fi
    say "DRY RUN: watch folder $WATCH_DIR does not exist. Nothing to do."
    exit 0
  fi

  # baseline: only files added strictly after this epoch are eligible
  if [ -n "${OPENWATCHMAN_BASELINE:-}" ]; then
    BASELINE="$OPENWATCHMAN_BASELINE"
  elif [ -f "$MARKER" ]; then
    BASELINE="$(cat "$MARKER" 2>/dev/null)"
  elif [ "$WATCH_SOURCE" = "config" ]; then
    # a configured folder without a marker is NEVER sorted on sight: write
    # the baseline now; only files added from here on become eligible.
    if [ "$DRYRUN" = "1" ]; then
      say "DRY RUN: no baseline in $WATCH_DIR yet — the first real run initializes it; existing files stay put."
    else
      if date +%s > "$MARKER" 2>/dev/null; then
        echo "$(date '+%F %T')  initialized baseline for $WATCH_DIR" >> "$LOG" 2>/dev/null
      fi
    fi
    return 0
  else
    say "DRY RUN: no baseline marker at $MARKER — is OpenWatchman installed? Nothing to do."
    exit 0
  fi
  case "$BASELINE" in
    ''|*[!0-9]*)
      say "DRY RUN: baseline '$BASELINE' is not a plain epoch number. Nothing to do."
      if [ "$WATCH_SOURCE" = "config" ]; then return 0; else exit 0; fi
      ;;
  esac

  # --------------------------------------------------------------------------
  # Phase 1 — sort files that land at the TOP LEVEL of this folder
  # --------------------------------------------------------------------------
  for f in "$WATCH_DIR"/*; do
    [ -f "$f" ] || continue                  # files only — every folder is skipped
    base="${f##*/}"
    case "$base" in .*) continue ;; esac     # skip dotfiles (incl. the marker)
    is_partial "$base" && continue           # skip in-progress downloads
    is_dataless "$f" && continue             # skip iCloud placeholders
    scanned=$((scanned + 1))

    added_epoch="$(added_epoch_of "$f")" || continue
    [ "$added_epoch" -gt "$BASELINE" ] || continue    # only files added after install
    if [ "$MIN_AGE" -gt 0 ] && [ "$added_epoch" -gt "$((NOW - MIN_AGE))" ]; then
      continue                        # settle delay: too fresh — a later run gets it
    fi

    dest="$(dest_for_epoch "$added_epoch")"

    if [ "$DRYRUN" = "1" ]; then
      echo "WOULD SORT: ${LOG_PREFIX}$base  ->  ${dest#"$WATCH_DIR"/}/"
      sorted=$((sorted + 1))
      continue
    fi

    size_is_stable "$f" || continue
    safe_move "$f" "$dest" "moved" && sorted=$((sorted + 1))
  done

  # --------------------------------------------------------------------------
  # Phase 2 — reconcile files apps saved directly into a managed month folder
  # --------------------------------------------------------------------------
  # Only files newer than the baseline are considered (a fresh download always
  # has a fresh mtime). We build a reference file at the baseline time and let
  # find do the cheap filtering, so we don't stat/mdls the whole library.
  if [ "$DATE_FORMAT" = "yyyy-mm" ]; then depth=2; else depth=3; fi
  mkdir -p "$STATE_DIR" 2>/dev/null
  ref="$(mktemp "$STATE_DIR/phase2ref.XXXXXX" 2>/dev/null)" || ref=""
  if [ -n "$ref" ] && touch -t "$(date -r "$BASELINE" +%Y%m%d%H%M.%S)" "$ref" 2>/dev/null; then
    while IFS= read -r -d '' f; do
      [ -n "$f" ] || continue
      base="${f##*/}"
      case "$base" in .*) continue ;; esac
      is_partial "$base" && continue
      is_dataless "$f" && continue

      # containing folder must match the ACTIVE date_format's managed shape
      dir="${f%/*}"
      if [ "$DATE_FORMAT" = "yyyy-mm" ]; then
        mdir="${dir##*/}"                   # 2026-07
        [ "$dir" = "$WATCH_DIR/$mdir" ] || continue
        case "$mdir" in [0-9][0-9][0-9][0-9]-[0-9][0-9]) ;; *) continue ;; esac
        folder_year="${mdir%%-*}"
        folder_month=$(( 10#${mdir#*-} ))
      else
        monthdir="${dir##*/}"               # 6 or 06
        yeardir_path="${dir%/*}"            # .../2026
        yeardir="${yeardir_path##*/}"       # 2026
        [ "$yeardir_path" = "$WATCH_DIR/$yeardir" ] || continue
        case "$yeardir"  in [0-9][0-9][0-9][0-9]) ;; *) continue ;; esac
        case "$monthdir" in ''|*[!0-9]*) continue ;; esac
        folder_year="$yeardir"
        folder_month=$(( 10#$monthdir ))
      fi
      { [ "$folder_month" -ge 1 ] && [ "$folder_month" -le 12 ]; } || continue

      # signal 1: date added (mtime fallback) — also the eligibility gate
      added_epoch="$(added_epoch_of "$f")" || continue
      [ "$added_epoch" -gt "$BASELINE" ] || continue
      if [ "$MIN_AGE" -gt 0 ] && [ "$added_epoch" -gt "$((NOW - MIN_AGE))" ]; then
        continue                      # settle delay: too fresh — a later run gets it
      fi

      # signal 2: on-disk birth time (survives moves). No birth time -> skip.
      birth_epoch="$(stat -f %B "$f" 2>/dev/null)"
      case "$birth_epoch" in ''|*[!0-9]*) continue ;; esac

      a_year="$(date -r "$added_epoch" +%Y)"
      a_month="$(( 10#$(date -r "$added_epoch" +%m) ))"
      b_year="$(date -r "$birth_epoch" +%Y)"
      b_month="$(( 10#$(date -r "$birth_epoch" +%m) ))"

      # the two clocks must AGREE, and disagree with the current folder.
      # Month equality is NUMERIC, so 7 vs 07 never causes a relocation.
      [ "$a_year" = "$b_year" ] || continue
      [ "$a_month" = "$b_month" ] || continue
      if [ "$a_year" = "$folder_year" ] && [ "$a_month" = "$folder_month" ]; then
        continue                          # already in the right place
      fi

      dest="$(dest_for_epoch "$added_epoch")"
      dirrel="${dir#"$WATCH_DIR"/}"

      if [ "$DRYRUN" = "1" ]; then
        echo "WOULD RELOCATE: ${LOG_PREFIX}$dirrel/$base  ->  ${dest#"$WATCH_DIR"/}/"
        relocated=$((relocated + 1))
        continue
      fi

      size_is_stable "$f" || continue
      safe_move "$f" "$dest" "relocated" && relocated=$((relocated + 1))
    done < <(find "$WATCH_DIR" -mindepth "$depth" -maxdepth "$depth" -type f -newer "$ref" -print0 2>/dev/null)
  fi
  [ -n "$ref" ] && rm -f "$ref"
  return 0
}

# ============================================================================
# Main — run both phases once per watch folder, then notify (opt-in)
# ============================================================================
scanned=0
sorted=0
relocated=0
BASELINE=""
LOG_PREFIX=""
NOTIFY_TOTAL=0
NOTIFY_DETAIL=""

shopt -s nullglob
di=1
while [ "$di" -le "$WATCH_COUNT" ]; do
  WATCH_DIR="${WATCH_DIRS[di]}"
  MARKER="$WATCH_DIR/.openwatchman-baseline"
  if [ "$WATCH_COUNT" -gt 1 ]; then
    LOG_PREFIX="[${WATCH_DIR##*/}] "     # several folders: tag log lines
  else
    LOG_PREFIX=""                        # single folder: today's format exactly
  fi
  moved_before=$((sorted + relocated))
  process_dir
  moved_here=$((sorted + relocated - moved_before))
  if [ "$moved_here" -gt 0 ]; then
    NOTIFY_TOTAL=$((NOTIFY_TOTAL + moved_here))
    if [ -z "$NOTIFY_DETAIL" ]; then
      NOTIFY_DETAIL="Filed $moved_here file(s) from ${WATCH_DIR##*/}"
    else
      NOTIFY_DETAIL="$NOTIFY_DETAIL, $moved_here from ${WATCH_DIR##*/}"
    fi
  fi
  di=$((di + 1))
done

if [ "$DRYRUN" = "1" ]; then
  if [ "$WATCH_COUNT" -gt 1 ]; then
    echo "DRY RUN: scanned $scanned top-level file(s) across $WATCH_COUNT watch folders, $sorted would sort; $relocated misplaced file(s) would be relocated. Nothing was moved."
  else
    echo "DRY RUN: scanned $scanned top-level file(s), $sorted would sort; $relocated misplaced file(s) would be relocated (baseline=$BASELINE). Nothing was moved."
  fi
else
  if [ "$WATCH_COUNT" -gt 1 ]; then
    notify_pass "$NOTIFY_DETAIL"
  else
    notify_pass "Filed $NOTIFY_TOTAL file(s)"
  fi
fi

exit 0
