#!/bin/sh
# Diff every captured state against its MAME snapshot with the Python model.
# The reference renderer is the executable spec; this proves it still holds.
set -e
cd "$(dirname "$0")/.."
OUT=${OUT:-artifacts}
fail=0
for s in "$OUT"/state_*.txt; do
    tag=$(basename "$s" .txt); tag=${tag#state_}
    python3 tools/render_model.py "$s" "$OUT/mame_$tag.png" || fail=1
done
[ $fail -eq 0 ] && echo "all states match" || echo "FAILURES"
exit $fail
