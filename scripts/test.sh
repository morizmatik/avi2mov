#!/bin/zsh
# End-to-end check on macOS: builds the converter, generates test AVI files, converts each one
# and verifies the result frame by frame.
#   scripts/test.sh
set -e
cd "${0:A:h}/.."
swift build -c release 2>&1 | tail -1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swift scripts/make-source.swift "$work" >/dev/null
swift scripts/make-avi.swift "$work"
bad=0
for avi in "$work"/*.avi; do
  name=${avi:t:r}
  echo "-- $name"
  .build/release/avi2mov "$avi" --out "$work/$name.mov" >/dev/null
  swift scripts/verify.swift "$work/$name.mov" "$work/$name.expect.json" || bad=$((bad + 1))
done
[ $bad -eq 0 ] && echo "all conversions verified" || { echo "$bad conversions failed"; exit 1; }
