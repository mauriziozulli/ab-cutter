#!/usr/bin/env bash
#
# Type-checks the platform-independent model files with any Swift toolchain,
# including on Linux.
#
# `swift build` needs AVFoundation and AppKit and therefore a Mac. Most of the
# app genuinely does, but the model layer is close to pure Foundation, and it
# is where the errors a syntax check cannot see tend to live — Codable
# synthesis, optional bindings, protocol conformance. Running this before a
# push catches those in a second instead of a CI round trip.
#
#   packaging/typecheck-models.sh
#
# On a Mac, prefer `swift build`: it checks everything, not just these files.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stand-ins for the handful of CoreGraphics types the models touch, so the
# files compile away from Apple's SDKs.
cat > "$WORK/Shim.swift" <<'SWIFT'
public struct CGSize {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
SWIFT

# CoreGraphics is supplied by the shim above; everything else imports cleanly.
sed 's/^import CoreGraphics$//' \
    "$ROOT/Sources/ABCutter/Core/Models/Project.swift" > "$WORK/Project.swift"
cp "$ROOT/Sources/ABCutter/Core/Models/Timecode.swift" "$WORK/Timecode.swift"

echo "▸ Type-checking the model layer…"
if swiftc -typecheck "$WORK/Shim.swift" "$WORK/Project.swift" "$WORK/Timecode.swift"; then
    echo "✓ Models type-check."
else
    echo "✗ Models do not type-check — the paths above are copies, fix the originals in Sources/."
    exit 1
fi
