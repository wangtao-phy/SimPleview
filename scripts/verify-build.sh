#!/bin/bash
# 每个修复单独编译。构建产物留在临时目录，日志保留具体修复编号。
set -eu
cd "$(dirname "$0")/.."
checkpoint="${1:?需要修复编号}"
configuration="${2:-Debug}"
logdir="${TMPDIR:-/tmp}/simpleview-fixes"
mkdir -p "$logdir"
log="$logdir/$checkpoint.log"
if xcodebuild -project SimPleview.xcodeproj -scheme SimPleview -configuration "$configuration" -destination 'platform=macOS' -derivedDataPath "$logdir/DerivedData" CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1; then
    printf '%s BUILD SUCCEEDED — %s\n' "$checkpoint" "$log"
    printf '%s\t%s\tBUILD SUCCEEDED\n' "$(date -u +%FT%TZ)" "$checkpoint" >> "$logdir/checkpoints.tsv"
else
    tail -100 "$log"
    exit 1
fi
