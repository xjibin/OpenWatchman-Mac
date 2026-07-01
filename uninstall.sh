#!/bin/bash
#
# OpenWatchman uninstaller.
#
# Removes the agent, the app wrapper, and the sorter script.
# Your sorted Year/Month folders and every file in them are NOT touched.

set -euo pipefail

LABEL="com.openwatchman.agent"
WATCH_DIR="${OPENWATCHMAN_DIR:-$HOME/Downloads}"

SCRIPT_DEST="$HOME/.local/bin/openwatchman.sh"
APP="$HOME/Applications/OpenWatchman.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MARKER="$WATCH_DIR/.openwatchman-baseline"
LOG="$HOME/Library/Logs/openwatchman.log"
LOG_OUT="$HOME/Library/Logs/openwatchman.out.log"
LOG_ERR="$HOME/Library/Logs/openwatchman.err.log"

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [options]

  -y, --yes              don't ask for confirmation
  --purge                also delete the baseline marker and the logs
  --reset-screenshots    point macOS screenshots back to the system default
  --keep-screenshots     leave the screenshot location alone (and don't ask)
  -h, --help             show this help

Environment:
  OPENWATCHMAN_DIR    folder that was watched (default: ~/Downloads)
EOF
}

ASSUME_YES=0
PURGE=0
RESET_SHOTS="ask"   # ask | yes | no
for arg in "$@"; do
  case "$arg" in
    -y|--yes)            ASSUME_YES=1 ;;
    --purge)             PURGE=1 ;;
    --reset-screenshots) RESET_SHOTS="yes" ;;
    --keep-screenshots)  RESET_SHOTS="no" ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "uninstall.sh: unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "uninstall.sh: OpenWatchman is macOS-only." >&2
  exit 1
fi

echo "This removes the OpenWatchman agent, app wrapper, and script."
echo "Sorted Year/Month folders and the files inside them are not touched."
if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed? [y/N] " answer
  case "$answer" in
    y|Y) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

UID_NUM="$(id -u)"
echo "[1/4] Unloading agent"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true

echo "[2/4] Removing installed files"
rm -f "$PLIST" "$SCRIPT_DEST"
rm -rf "$APP"

echo "[3/4] Marker and logs"
if [ "$PURGE" -eq 1 ]; then
  rm -f "$MARKER" "$LOG" "$LOG_OUT" "$LOG_ERR"
  echo "      purged"
else
  echo "      kept (rerun with --purge to delete: $MARKER and the logs)"
fi

if [ "$RESET_SHOTS" = "ask" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    RESET_SHOTS="no"
  else
    read -r -p "Reset macOS screenshots to the system default location? [y/N] " answer
    case "$answer" in
      y|Y) RESET_SHOTS="yes" ;;
      *)   RESET_SHOTS="no" ;;
    esac
  fi
fi
if [ "$RESET_SHOTS" = "yes" ]; then
  echo "[4/4] Resetting screenshot location"
  defaults delete com.apple.screencapture location 2>/dev/null || true
  killall SystemUIServer 2>/dev/null || true
else
  echo "[4/4] Screenshot location left unchanged"
fi

cat <<'EOF'

Done. One manual leftover macOS does not let scripts clean up:

  System Settings -> Privacy & Security -> Full Disk Access
  -> remove the (now deleted) "OpenWatchman" entry from the list.

EOF
