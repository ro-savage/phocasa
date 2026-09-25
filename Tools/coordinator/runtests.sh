#!/bin/zsh
# usage: runtests.sh <checkout-dir> <label> [extra xcodebuild args...]
set -u
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
XB=/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
DIR=$1; LABEL=$2; shift 2
DD="$TMPDIR/phocasa-dd-coord-$LABEL"
LOG="$TMPDIR/phocasa-coord-$LABEL.test.log"
cd "$DIR"
# Hosted-window tests (GridKeepAliveTests) need the display awake: with it asleep a hosted window never lays out its
# scroll view. caffeinate -u wakes the display, -d keeps it awake until xcodebuild exits (the screen may stay locked).
caffeinate -d -u $XB -project Phocasa/Phocasa.xcodeproj -scheme Phocasa -destination 'platform=macOS' -derivedDataPath "$DD" test "$@" > "$LOG" 2>&1
grep -E "\*\* TEST (SUCCEEDED|FAILED)" "$LOG" | tail -1
grep -oE "Executed [0-9]+ tests?, with [0-9]+ tests? skipped and [0-9]+ failures|Executed [0-9]+ tests?, with [0-9]+ failures" "$LOG" | sort -t' ' -k2 -n | tail -1
grep -E "error:|: error|failed \(" "$LOG" | grep -v "Simulator\|linkd\|Connection" | sort -u | head -15
echo "warnings: $(grep -c 'warning:' "$LOG")"
grep 'warning:' "$LOG" | grep -v appintents | sed 's/.*Phocasa\///' | sort -u | head -20
echo "LOG=$LOG"
