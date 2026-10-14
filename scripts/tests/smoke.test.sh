#!/usr/bin/env bash
# Test suite for scripts/smoke.sh.
#
# Hermetic: no macOS, no built Hotshot.app and no real `defaults` database are
# needed. Each test points smoke.sh at a fake .app whose "binary" is a bash
# script driven by SMOKE_APP_MODE, with a stub `defaults` on PATH that keeps
# its store in a temp file and logs every call.
#
# Usage: bash scripts/tests/smoke.test.sh
set -u

SMOKE="$(cd "$(dirname "$0")/.." && pwd)/smoke.sh"
PASS=0
FAIL=0

check() { # $1 = description, $2 = condition result ($?)
    if [ "$2" -eq 0 ]; then
        PASS=$((PASS + 1))
        echo "ok - $1"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL - $1"
    fi
}

assert_eq() { # $1 = description, $2 = expected, $3 = actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        echo "ok - $1"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL - $1"
        echo "    expected: $(printf '%q' "$2")"
        echo "    actual:   $(printf '%q' "$3")"
    fi
}

assert_contains() { # $1 = description, $2 = needle, $3 = haystack
    case "$3" in
        *"$2"*) check "$1" 0 ;;
        *)
            check "$1" 1
            echo "    expected to contain: $(printf '%q' "$2")"
            ;;
    esac
}

assert_not_contains() { # $1 = description, $2 = needle, $3 = haystack
    case "$3" in
        *"$2"*)
            check "$1" 1
            echo "    expected not to contain: $(printf '%q' "$2")"
            ;;
        *) check "$1" 0 ;;
    esac
}

TMP="$(mktemp -d /tmp/hotshot-smoke-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

STUBS="$TMP/stubs"
LOG="$TMP/calls.log"
STORE="$TMP/defaults-store"
mkdir -p "$STUBS" "$STORE"

# defaults stub: `read dom key` prints the stored value or exits 1 like the
# real tool does for a missing key; `write dom key -string val` and
# `delete dom key` update one file per key.
cat >"$STUBS/defaults" <<EOF
#!/usr/bin/env bash
echo "defaults \$*" >>"$LOG"
f="$STORE/\$2.\$3"
case "\$1" in
    read)
        [ -f "\$f" ] || exit 1
        cat "\$f"
        ;;
    write)
        printf '%s\n' "\$5" >"\$f"
        ;;
    delete)
        [ -f "\$f" ] || exit 1
        rm -f "\$f"
        ;;
    *) exit 2 ;;
esac
EOF
chmod +x "$STUBS/defaults"

# Fake app: reads the screenshot directory through the stub `defaults`,
# then behaves per SMOKE_APP_MODE:
#   ok      create the dir, log all launch events, run until signalled
#   early   exit 3 before logging anything
#   hang    log nothing and run until signalled (drives the timeout path)
#   partial log app.launched only; no dir, no watcher events
#   badexit launch normally but exit 7 on SIGTERM instead of dying from it
APP="$TMP/Fake.app"
mkdir -p "$APP/Contents/MacOS"
cat >"$APP/Contents/MacOS/hotshot" <<'EOF'
#!/usr/bin/env bash
dir="$(defaults read io.hivecommons.hotshot hotshotScreenshotDir)"
case "${SMOKE_APP_MODE:-ok}" in
    early) exit 3 ;;
    hang) exec sleep 60 ;;
    partial)
        echo "hotshot[1:1] [INFO] app.launched path=<redacted>" >&2
        exec sleep 60
        ;;
esac
mkdir -p "$dir"
echo "hotshot[1:1] [INFO] app.launched path=<redacted>" >&2
echo "hotshot[1:1] [INFO] watcher.started path=<redacted>" >&2
echo "hotshot[1:1] [INFO] clipboard.watch_started" >&2
if [ "${SMOKE_APP_MODE:-ok}" = badexit ]; then
    trap 'exit 7' TERM
    sleep 60 &
    wait $!
    exit 7
fi
exec sleep 60
EOF
chmod +x "$APP/Contents/MacOS/hotshot"

BASHENV="$TMP/bashenv"
: >"$BASHENV"
[ -n "${HOTSHOT_COVERAGE_RC:-}" ] && cat "$HOTSHOT_COVERAGE_RC" >>"$BASHENV"

run_smoke() { # env: SMOKE_APP_MODE, HOTSHOT_APP_BUNDLE override, timeout
    env -i HOME="$TMP" PATH="$STUBS:/usr/bin:/bin" BASH_ENV="$BASHENV" \
        SMOKE_APP_MODE="${SMOKE_APP_MODE:-ok}" \
        HOTSHOT_APP_BUNDLE="${HOTSHOT_APP_BUNDLE:-$APP}" \
        HOTSHOT_SMOKE_TIMEOUT="${HOTSHOT_SMOKE_TIMEOUT:-5}" \
        bash "$SMOKE"
}

# ==============================================================================
# happy path: app launches, logs every event, creates the dir, stops on TERM
# ==============================================================================
: >"$LOG"
rm -f "$STORE"/*
out="$(run_smoke 2>&1)"
rc=$?
assert_eq "ok: exit 0" "0" "$rc"
assert_contains "ok: app.launched seen" "ok - app logged app.launched" "$out"
assert_contains "ok: watcher.started seen" "ok - diagnostic watcher.started logged" "$out"
assert_contains "ok: clipboard.watch_started seen" "ok - diagnostic clipboard.watch_started logged" "$out"
assert_contains "ok: screenshot dir created" "ok - screenshot directory created" "$out"
assert_contains "ok: app still running before stop" "ok - app still running after launch" "$out"
assert_contains "ok: SIGTERM stop accepted" "ok - app stopped on SIGTERM" "$out"
assert_contains "ok: summary line" "smoke: Hotshot.app launched and stopped cleanly" "$out"
assert_not_contains "ok: no FAIL lines" "FAIL -" "$out"
grep -q '^defaults write io.hivecommons.hotshot hotshotScreenshotDir -string /' "$LOG"
check "ok: screenshot pref pointed at a temp dir" $?
grep -q '^defaults delete io.hivecommons.hotshot hotshotScreenshotDir' "$LOG"
check "ok: pref deleted afterwards when it was unset before" $?
if [ -f "$STORE/io.hivecommons.hotshot.hotshotScreenshotDir" ]; then
    check "ok: no pref left behind" 1
else
    check "ok: no pref left behind" 0
fi
if pgrep -f "$APP/Contents/MacOS/hotshot" >/dev/null 2>&1; then
    check "ok: fake app process stopped" 1
else
    check "ok: fake app process stopped" 0
fi

# ==============================================================================
# previous preference is restored, not deleted
# ==============================================================================
: >"$LOG"
printf '%s\n' "/Users/someone/Shots" >"$STORE/io.hivecommons.hotshot.hotshotScreenshotDir"
out="$(run_smoke 2>&1)"
rc=$?
assert_eq "restore: exit 0" "0" "$rc"
assert_eq "restore: previous screenshot dir written back" "/Users/someone/Shots" \
    "$(cat "$STORE/io.hivecommons.hotshot.hotshotScreenshotDir")"
grep -q '^defaults write io.hivecommons.hotshot hotshotScreenshotDir -string /Users/someone/Shots$' "$LOG"
check "restore: restore went through defaults write" $?
if grep -q '^defaults delete' "$LOG"; then
    check "restore: no delete when a value existed" 1
else
    check "restore: no delete when a value existed" 0
fi
rm -f "$STORE"/*

# ==============================================================================
# missing bundle
# ==============================================================================
: >"$LOG"
out="$(HOTSHOT_APP_BUNDLE="$TMP/Missing.app" run_smoke 2>&1)"
rc=$?
assert_eq "missing: exit 1" "1" "$rc"
assert_contains "missing: names the binary path" "no executable at $TMP/Missing.app/Contents/MacOS/hotshot" "$out"
assert_contains "missing: points at bundle.sh" "run scripts/bundle.sh first" "$out"
if [ -s "$LOG" ]; then check "missing: defaults untouched" 1; else check "missing: defaults untouched" 0; fi

# ==============================================================================
# app exits before logging app.launched
# ==============================================================================
: >"$LOG"
out="$(SMOKE_APP_MODE=early run_smoke 2>&1)"
rc=$?
assert_eq "early: exit 1" "1" "$rc"
assert_contains "early: reports early exit with status" "FAIL - app exited early with status 3 before app.launched" "$out"
assert_contains "early: reports app not running" "FAIL - app is not running after launch" "$out"
assert_contains "early: dumps the app log" "--- app log" "$out"
grep -q '^defaults delete io.hivecommons.hotshot hotshotScreenshotDir' "$LOG"
check "early: pref cleaned up on failure" $?

# ==============================================================================
# app never logs app.launched (timeout)
# ==============================================================================
: >"$LOG"
start=$SECONDS
out="$(SMOKE_APP_MODE=hang HOTSHOT_SMOKE_TIMEOUT=1 run_smoke 2>&1)"
rc=$?
elapsed=$((SECONDS - start))
assert_eq "hang: exit 1" "1" "$rc"
assert_contains "hang: reports the timeout" "FAIL - app did not log app.launched within 1s" "$out"
assert_contains "hang: still stops the app" "ok - app stopped on SIGTERM" "$out"
if [ "$elapsed" -le 10 ]; then check "hang: gives up within the timeout" 0; else check "hang: gives up within the timeout" 1; fi
if pgrep -f "$APP/Contents/MacOS/hotshot" >/dev/null 2>&1; then
    check "hang: fake app process stopped" 1
else
    check "hang: fake app process stopped" 0
fi

# ==============================================================================
# app launches but watchers never start and the dir is missing
# ==============================================================================
: >"$LOG"
out="$(SMOKE_APP_MODE=partial run_smoke 2>&1)"
rc=$?
assert_eq "partial: exit 1" "1" "$rc"
assert_contains "partial: app.launched seen" "ok - app logged app.launched" "$out"
assert_contains "partial: watcher.started missing" "FAIL - diagnostic watcher.started missing" "$out"
assert_contains "partial: clipboard.watch_started missing" "FAIL - diagnostic clipboard.watch_started missing" "$out"
assert_contains "partial: screenshot dir missing" "FAIL - screenshot directory" "$out"
assert_contains "partial: still stops the app" "ok - app stopped on SIGTERM" "$out"

# ==============================================================================
# app launches but exits with an unexpected status when stopped
# ==============================================================================
: >"$LOG"
out="$(SMOKE_APP_MODE=badexit run_smoke 2>&1)"
rc=$?
assert_eq "badexit: exit 1" "1" "$rc"
assert_contains "badexit: launch checks pass" "ok - screenshot directory created" "$out"
assert_contains "badexit: reports the status" "FAIL - app exited with unexpected status 7 on SIGTERM" "$out"
assert_not_contains "badexit: not reported as a clean stop" "ok - app stopped on SIGTERM" "$out"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
