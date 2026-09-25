#!/bin/zsh
# ab.sh <git-ref> <label> [extra xcodebuild args, e.g. -only-testing:PhocasaTests/ThumbnailDiskCacheBenchmarks]
#
# Checks <git-ref> out in a detached bench worktree ($TMPDIR/phocasa-bench, created on first use), copies the
# coordinator harness in, runs DataPathBenchmarks + CoordinatorBenchmarks + CoordinatorEditBenchmarks (plus any extra
# -only-testing), and writes the BENCH|/COORD| lines to $COORD_OUT/<label>.txt (default: $TMPDIR/phocasa-coord-results).
# Uses the checkout's own PerformanceBenchmarks.swift. Edit variant: the EditSession one, unless the checkout predates
# task 22 (no Editing/EditSession.swift), then the view-model one. Run only on a quiet machine.
set -u
REPO=${0:A:h:h:h}
B="$TMPDIR/phocasa-bench"
OUT=${COORD_OUT:-$TMPDIR/phocasa-coord-results}
REF=$1; LABEL=$2; shift 2
mkdir -p "$OUT"
[[ -d "$B" ]] || git -C "$REPO" worktree add --detach "$B" "$REF" -q
cd "$B" || exit 1
git checkout -q -- . && git clean -qfd Phocasa/PhocasaTests
git checkout -q --detach "$REF" || exit 1
cp "$REPO/Tools/coordinator/CoordinatorBenchmarks.swift" Phocasa/PhocasaTests/
if [[ -f Phocasa/Phocasa/Editing/EditSession.swift ]]; then
  cp "$REPO/Tools/coordinator/CoordinatorEditBenchmarks-Session.swift" Phocasa/PhocasaTests/
else
  cp "$REPO/Tools/coordinator/CoordinatorEditBenchmarks.swift" Phocasa/PhocasaTests/
fi
rm -rf "$TMPDIR/phocasa-coord-thumbcache"; mkdir -p "$TMPDIR/phocasa-coord-thumbcache"
export TEST_RUNNER_PHOCASA_BENCH=1 \
       TEST_RUNNER_COORD_BENCH_DATA="${COORD_BENCH_DATA:-$TMPDIR/phocasa-imagebench-coord/data}" \
       TEST_RUNNER_COORD_REAL_DIR="$HOME/PhocasaBenchRAW" \
       TEST_RUNNER_PHOCASA_THUMBNAIL_CACHE_DIR="$TMPDIR/phocasa-coord-thumbcache"
echo "== $LABEL $REF $(git rev-parse --short HEAD) start $(date +%T) load: $(uptime | sed 's/.*averages: //')"
"$REPO/Tools/coordinator/runtests.sh" "$B" "$LABEL" -only-testing:PhocasaTests/DataPathBenchmarks \
  -only-testing:PhocasaTests/CoordinatorBenchmarks -only-testing:PhocasaTests/CoordinatorEditBenchmarks "$@" | grep -v '^LOG'
grep -hE '^(BENCH|COORD)\|' "$TMPDIR/phocasa-coord-$LABEL.test.log" > "$OUT/$LABEL.txt"
echo "== $LABEL end $(date +%T) load: $(uptime | sed 's/.*averages: //') lines=$(wc -l < $OUT/$LABEL.txt | tr -d ' ') -> $OUT/$LABEL.txt"
ls ~/Library/Caches/com.phocasa.app >/dev/null 2>&1 && echo "WARNING: ~/Library/Caches/com.phocasa.app exists"
git checkout -q -- . && git clean -qfd Phocasa/PhocasaTests
