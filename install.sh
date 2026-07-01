#!/bin/bash
#
# OpenWatchman installer.
#
# Please read this file before running it — that's the point of this repo.
# It only touches the paths printed in the plan below, asks before doing
# anything (use --yes to skip the prompt), and makes no network requests.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

LABEL="com.openwatchman.agent"
WATCH_DIR="${OPENWATCHMAN_DIR:-$HOME/Downloads}"

SCRIPT_SRC="$REPO_DIR/bin/openwatchman.sh"
SCRIPT_DEST="$HOME/.local/bin/openwatchman.sh"
APP="$HOME/Applications/OpenWatchman.app"
PLIST_TEMPLATE="$REPO_DIR/launchd/com.openwatchman.agent.plist.template"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MARKER="$WATCH_DIR/.openwatchman-baseline"
LOG_DIR="$HOME/Library/Logs"

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

  -y, --yes           don't ask for confirmation
  --screenshots       also redirect macOS screenshots into the watched folder
  --no-screenshots    leave the screenshot location alone (and don't ask)
  --keep-baseline     keep an existing baseline marker instead of resetting it
                      to "now" (files added since the old baseline will then
                      be sorted on the first run)
  -h, --help          show this help

Environment:
  OPENWATCHMAN_DIR    folder to watch (default: ~/Downloads)
EOF
}

ASSUME_YES=0
SCREENSHOTS="ask"   # ask | yes | no
KEEP_BASELINE=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)         ASSUME_YES=1 ;;
    --screenshots)    SCREENSHOTS="yes" ;;
    --no-screenshots) SCREENSHOTS="no" ;;
    --keep-baseline)  KEEP_BASELINE=1 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "install.sh: unknown option: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

# --- sanity checks -----------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "install.sh: OpenWatchman is macOS-only." >&2
  exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "install.sh: do not run as root/sudo — it installs per-user." >&2
  exit 1
fi
if [ ! -f "$SCRIPT_SRC" ] || [ ! -f "$PLIST_TEMPLATE" ]; then
  echo "install.sh: run this from the root of the OpenWatchman-Mac repo." >&2
  exit 1
fi
if ! command -v osacompile >/dev/null 2>&1; then
  echo "install.sh: osacompile not found (it ships with macOS)." >&2
  exit 1
fi

# --- the plan ----------------------------------------------------------------
cat <<EOF

OpenWatchman will install exactly these pieces (per-user, no sudo):

  1. Sorter script   -> $SCRIPT_DEST
  2. App wrapper     -> $APP
        Built locally on this Mac with osacompile, so there is no
        pre-built binary to trust. Full Disk Access is granted to this
        one app instead of to /bin/bash.
  3. Baseline marker -> $MARKER
        Epoch timestamp = now. Files already in the folder are never
        moved; only files added after this moment are eligible.
  4. LaunchAgent     -> $PLIST
        Label $LABEL, watching: $WATCH_DIR
        Runs on folder change, at login, and every 5 minutes (the periodic
        run reconciles files apps save straight into a month subfolder).
  5. Load the agent with launchctl.

Logs go to ~/Library/Logs/openwatchman.log (and .out.log / .err.log).
Nothing else is touched. No network access. Remove with ./uninstall.sh.

EOF

if [ "$ASSUME_YES" -ne 1 ]; then
  read -r -p "Proceed? [y/N] " answer
  case "$answer" in
    y|Y) ;;
    *) echo "Aborted. Nothing was installed."; exit 1 ;;
  esac
fi

# --- 1. sorter script --------------------------------------------------------
echo "[1/6] Installing sorter script"
mkdir -p "$(dirname "$SCRIPT_DEST")" "$LOG_DIR"
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod 755 "$SCRIPT_DEST"

# install the CLI front-end (owm)
CLI_SRC="$REPO_DIR/bin/owm"
CLI_DEST="$HOME/.local/bin/owm"
if [ -f "$CLI_SRC" ]; then
  cp "$CLI_SRC" "$CLI_DEST"
  chmod 755 "$CLI_DEST"
  echo "      installed CLI: $CLI_DEST (run 'owm help')"
fi

# --- 2. app wrapper ----------------------------------------------------------
echo "[2/6] Building local app wrapper (osacompile)"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
osacompile -o "$APP" \
  -e "do shell script \"OPENWATCHMAN_DIR='$WATCH_DIR' /bin/bash '$SCRIPT_DEST'\""

# keep it out of the Dock when it fires
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" \
  2>/dev/null || \
/usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$APP/Contents/Info.plist"

# ad-hoc signature keeps the TCC grant stable across reboots
# apply the repo's app icon (if present) before signing
ICON_SRC="$REPO_DIR/assets/applet.icns"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/applet.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile applet" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string applet" "$APP/Contents/Info.plist"
  echo "      applied custom icon from assets/applet.icns"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

APPLET="$APP/Contents/MacOS/applet"
if [ ! -x "$APPLET" ]; then
  APPLET="$(find "$APP/Contents/MacOS" -maxdepth 1 -type f -perm +111 2>/dev/null | head -n 1)"
fi
if [ -z "$APPLET" ] || [ ! -x "$APPLET" ]; then
  echo "install.sh: could not locate the app wrapper's executable." >&2
  exit 1
fi

# --- 3. baseline marker ------------------------------------------------------
echo "[3/6] Writing baseline marker"
if [ -f "$MARKER" ] && [ "$KEEP_BASELINE" -eq 1 ]; then
  echo "      keeping existing baseline ($(cat "$MARKER"))"
else
  date +%s > "$MARKER"
  echo "      baseline = now; everything currently in $WATCH_DIR stays put"
fi

# --- 4. LaunchAgent ----------------------------------------------------------
echo "[4/6] Installing LaunchAgent"
mkdir -p "$(dirname "$PLIST")"
sed -e "s|@APPLET@|$APPLET|g" \
    -e "s|@WATCH_DIR@|$WATCH_DIR|g" \
    -e "s|@HOME@|$HOME|g" \
    "$PLIST_TEMPLATE" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

# --- 5. load -----------------------------------------------------------------
echo "[5/6] Loading agent"
UID_NUM="$(id -u)"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/$LABEL"

# --- 6. screenshots (optional) -----------------------------------------------
if [ "$SCREENSHOTS" = "ask" ]; then
  if [ "$ASSUME_YES" -eq 1 ]; then
    SCREENSHOTS="no"
  else
    read -r -p "Also save macOS screenshots into $WATCH_DIR so they get sorted too? [y/N] " answer
    case "$answer" in
      y|Y) SCREENSHOTS="yes" ;;
      *)   SCREENSHOTS="no" ;;
    esac
  fi
fi
if [ "$SCREENSHOTS" = "yes" ]; then
  echo "[6/6] Redirecting screenshots into $WATCH_DIR"
  defaults write com.apple.screencapture location "$WATCH_DIR"
  killall SystemUIServer 2>/dev/null || true
else
  echo "[6/6] Screenshot location left unchanged"
fi

# --- the one manual step -----------------------------------------------------
cat <<EOF

Installed. ONE manual step remains — macOS requires it:

  ~/Downloads is privacy-protected (TCC). Background agents cannot show the
  permission dialog, so grant access once by hand:

    1. System Settings -> Privacy & Security -> Full Disk Access
    2. Click "+", press Cmd+Shift+G, type:  ~/Applications
       select "OpenWatchman", click Open, and make sure its toggle is ON.
    3. Reload the agent:
         launchctl bootout gui/$UID_NUM/$LABEL
         launchctl bootstrap gui/$UID_NUM "$PLIST"

  Why an app and not /bin/bash? Granting Full Disk Access to bash would
  extend it to every bash script on your Mac. The locally generated
  OpenWatchman.app scopes that permission to this one tool.

Then test it: download any file into $WATCH_DIR and run

    tail -3 ~/Library/Logs/openwatchman.log

You should see:  moved  <your file>  ->  $(date +%Y)/$(( 10#$(date +%m) ))/

Useful afterwards:

  Command-line interface ('owm help' for all commands):
    owm status    # running? baseline, recent activity
    owm preview   # dry-run: what would move now
    owm doctor    # diagnostics + Full Disk Access hint
  If 'owm' is not found, add ~/.local/bin to your PATH, or run ~/.local/bin/owm.


  Preview anytime (moves nothing):
    $SCRIPT_DEST --dry-run

  Optionally sort/relocate the files that existed BEFORE install, or fix
  files already sitting in the wrong month folder — review first, then run:
    OPENWATCHMAN_BASELINE=1 $SCRIPT_DEST --dry-run
    OPENWATCHMAN_BASELINE=1 $SCRIPT_DEST

EOF
