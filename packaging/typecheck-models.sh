#!/usr/bin/env bash
#
# Checks the platform-independent model files with any Swift toolchain,
# including on Linux: they are type-checked, and then a handful of Codable
# assertions are actually run.
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
if ! swiftc -typecheck "$WORK/Shim.swift" "$WORK/Project.swift" "$WORK/Timecode.swift"; then
    echo "✗ Models do not type-check — the paths above are copies, fix the originals in Sources/."
    exit 1
fi
echo "✓ Models type-check."

# A project written by an earlier version has to keep opening. Swift's
# generated decoder treats a missing key as an error even where the property
# has a default, so every setting added to the models would otherwise
# invalidate every saved project — which is exactly the kind of regression a
# type check cannot see.
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

struct Document: Codable {
    var version: Int
    var project: ABProject
}

func check(_ condition: Bool, _ description: String) {
    if condition { return }
    FileHandle.standardError.write(Data("✗ \(description)\n".utf8))
    exit(1)
}

/// Top-level code cannot throw, so the checks live in here.
func run() throws {
    // A project holding only the keys an early version wrote.
    let legacy = Data("""
    {"version":1,"project":{"videoDurationSeconds":120,"clips":[],"audioSources":[],
    "export":{"insetScale":0.9,"beforeLabel":"VORHER"},"stills":{"headline":"Titel"}}}
    """.utf8)

    guard let old = try? JSONDecoder().decode(Document.self, from: legacy) else {
        FileHandle.standardError.write(Data("✗ A project from an earlier version no longer opens.\n".utf8))
        exit(1)
    }
    check(old.project.export.insetScale == 0.9, "A stored setting was lost while decoding.")
    check(old.project.export.beforeLabel == "VORHER", "A stored label was lost while decoding.")
    check(old.project.stills.headline == "Titel", "A stored cover headline was lost while decoding.")
    check(old.project.defaultClipLengthSeconds == ABProject().defaultClipLengthSeconds,
          "A missing key did not fall back to its default.")
    check(old.project.export.respectPlayerChrome == ExportSettings().respectPlayerChrome,
          "A setting added after the file was written did not fall back to its default.")

    // Anything that is not a project at all still has to be refused.
    check((try? JSONDecoder().decode(Document.self, from: Data(#"{"hello":"world"}"#.utf8))) == nil,
          "A file that is not a project was opened as an empty one.")

    // And a round trip has to be lossless.
    var project = ABProject()
    project.export.chromeSafeTop = 0.17
    project.export.respectPlayerChrome = false
    project.stills.headline = "Titel"
    let encoded = try JSONEncoder().encode(Document(version: 1, project: project))
    let restored = try JSONDecoder().decode(Document.self, from: encoded).project
    check(restored.export.chromeSafeTop == 0.17, "A round trip changed a setting.")
    check(restored.export.respectPlayerChrome == false, "A round trip changed a toggle.")
    check(restored.stills.headline == "Titel", "A round trip changed the cover headline.")

    // The safe area belongs to the story format alone.
    check(ExportSettings().safeArea(for: .portrait45).isEmpty, "A feed format reserved a strip.")
    check(!ExportSettings().safeArea(for: .portrait916).isEmpty, "The story format reserved nothing.")
    check(SafeArea(top: 9, bottom: -1).clamped.top == SafeArea.maximum, "The safe area was not clamped.")
    check(SafeArea(top: 9, bottom: -1).clamped.bottom == 0, "The safe area was not clamped.")

    print("✓ Project files decode as they should.")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
    exit(1)
}
SWIFT

echo "▸ Running the model checks…"
swiftc -o "$WORK/checks" \
    "$WORK/Shim.swift" "$WORK/Project.swift" "$WORK/Timecode.swift" "$WORK/main.swift"
"$WORK/checks"
