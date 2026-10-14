#!/usr/bin/env bash
# Launch smoke test for the bundled macOS app.
#
# `swift test` covers HotshotCore and HotshotApp, but Sources/hotshot/main.swift
# (the app delegate) lives in the executable target, which the test bundle
# cannot link, and scripts/bundle.sh only builds Hotshot.app. This script is
# the one check that the delegate actually comes up: it launches the bundle
# with an isolated screenshot directory, waits for applicationDidFinishLaunching
# to log `app.launched`, confirms the directory was created and both watchers
# started, then stops the app and restores the user's screenshot-directory
# preference.
#
# Needs a built bundle (bash scripts/bundle.sh) and a GUI session, so it runs
# on macOS only; scripts/tests/smoke.test.sh exercises the harness itself with
# a stub app and stub `defaults` on any platform.
#
# Environment:
#   HOTSHOT_APP_BUNDLE     path to the .app (default: <repo>/Hotshot.app)
#   HOTSHOT_SMOKE_TIMEOUT  seconds to wait for app.launched (default: 30)
#
# Usage: bash scripts/smoke.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="${HOTSHOT_APP_BUNDLE:-$PROJECT_DIR/Hotshot.app}"
BINARY="$APP_BUNDLE/Contents/MacOS/hotshot"
TIMEOUT="${HOTSHOT_SMOKE_TIMEOUT:-30}"

# Must match CFBundleIdentifier in scripts/bundle.sh and PREF_SCREENSHOT_DIR
# in Sources/HotshotCore/Preferences.swift.
DEFAULTS_DOMAIN="io.hivecommons.hotshot"
PREF_SCREENSHOT_DIR="hotshotScreenshotDir"

# Diagnostic events applicationDidFinishLaunching must emit with default
# preferences (autoWatch and clipboardWatch both default to true).
EXPECTED_EVENTS=(app.launched watcher.started clipboard.watch_started)

FAIL=0
ok() { echo "ok - $1"; }
fail() {
    echo "FAIL - $1"
    FAIL=1
}

if [ ! -x "$BINARY" ]; then
    echo "FAIL - no executable at $BINARY; run scripts/bundle.sh first" >&2
    exit 1
fi

WORK="$(mktemp -d /tmp/hotshot-smoke.XXXXXX)"
SHOT_DIR="$WORK/shots"
APP_LOG="$WORK/app.log"
APP_PID=""

# The app reads UserDefaults.standard, which `defaults` addresses by the
# bundle identifier. Point it at a directory under $WORK that does not exist
# yet, so its creation proves applicationDidFinishLaunching ran, and put the
# previous value back when we are done.
PREV_SHOT_DIR="$(defaults read "$DEFAULTS_DOMAIN" "$PREF_SCREENSHOT_DIR" 2>/dev/null || true)"

# Stops the app if it is still running and records its exit status in
# STOP_STATUS; a no-op once the app is gone, so the EXIT trap can share it.
STOP_STATUS=""
stop_app() {
    if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID" 2>/dev/null || true
        if wait "$APP_PID" 2>/dev/null; then STOP_STATUS=0; else STOP_STATUS=$?; fi
    fi
    APP_PID=""
}

cleanup() {
    stop_app
    if [ -n "$PREV_SHOT_DIR" ]; then
        defaults write "$DEFAULTS_DOMAIN" "$PREF_SCREENSHOT_DIR" -string "$PREV_SHOT_DIR"
    else
        defaults delete "$DEFAULTS_DOMAIN" "$PREF_SCREENSHOT_DIR" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

defaults write "$DEFAULTS_DOMAIN" "$PREF_SCREENSHOT_DIR" -string "$SHOT_DIR"

# NSLog writes to stderr as well as the unified log, so capturing the
# process's stderr is enough to see the diagnostics (HOTSHOT_VERBOSE_LOGGING
# unset: paths stay redacted, which is the production default).
"$BINARY" >"$WORK/app.out" 2>"$APP_LOG" &
APP_PID=$!

deadline=$((SECONDS + TIMEOUT))
launched=0
while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        break
    fi
    if grep -q 'app.launched' "$APP_LOG" 2>/dev/null; then
        launched=1
        break
    fi
    sleep 0.5
done

if [ "$launched" -eq 1 ]; then
    ok "app logged app.launched within ${TIMEOUT}s"
elif kill -0 "$APP_PID" 2>/dev/null; then
    fail "app did not log app.launched within ${TIMEOUT}s"
else
    wait "$APP_PID" && status=0 || status=$?
    fail "app exited early with status $status before app.launched"
    APP_PID=""
fi

# Let the watcher start-up lines land; they are logged right after app.launched.
sleep 1

for event in "${EXPECTED_EVENTS[@]}"; do
    if grep -q -- "$event" "$APP_LOG" 2>/dev/null; then
        ok "diagnostic $event logged"
    else
        fail "diagnostic $event missing from app log"
    fi
done

if [ -d "$SHOT_DIR" ]; then
    ok "screenshot directory created from the preference"
else
    fail "screenshot directory $SHOT_DIR was not created"
fi

if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    ok "app still running after launch"
    stop_app
    # SIGTERM shows up as 128+15; AppKit may also exit cleanly.
    if [ "$STOP_STATUS" -eq 0 ] || [ "$STOP_STATUS" -eq 143 ]; then
        ok "app stopped on SIGTERM (status $STOP_STATUS)"
    else
        fail "app exited with unexpected status $STOP_STATUS on SIGTERM"
    fi
else
    fail "app is not running after launch"
fi

if [ "$FAIL" -ne 0 ]; then
    echo "--- app log ($APP_LOG) ---"
    cat "$APP_LOG" 2>/dev/null || true
    echo "--- end app log ---"
    exit 1
fi
echo "smoke: Hotshot.app launched and stopped cleanly"
