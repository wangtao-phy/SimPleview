#!/bin/bash
# Requires a successful Debug build from verify-build.sh. Links the actual app
# dylib without invoking its @main startup, saved windows, or user preferences UI.
set -eu
cd "$(dirname "$0")/.."
products="${TMPDIR:-/tmp}/simpleview-fixes/DerivedData/Build/Products/Debug"
artifacts="${TMPDIR:-/tmp}/simpleview-fixes"
library="$products/SimPleview.app/Contents/MacOS/SimPleview.debug.dylib"
xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
  -target arm64-apple-macos26.6 -module-cache-path "$artifacts/test-modules" \
  -I "$products" Tests/Regression/PDFViewHarness.swift "$library" \
  -Xlinker -rpath -Xlinker "$products/SimPleview.app/Contents/MacOS" \
  -o "$artifacts/pdfview-regression"
"$artifacts/pdfview-regression"
