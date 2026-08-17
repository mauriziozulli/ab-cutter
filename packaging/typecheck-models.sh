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
cp "$ROOT/Sources/ABCutter/Core/Models/BrandAccent.swift" "$WORK/BrandAccent.swift"

echo "▸ Type-checking the model layer…"
if ! swiftc -typecheck "$WORK/Shim.swift" "$WORK/Project.swift" "$WORK/Timecode.swift" \
    "$WORK/BrandAccent.swift"; then
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
    // A project written while the look was still global: the look keys live
    // inside `export`, and the clip has none of its own. Opening it must move
    // that look onto the clip — that is the whole migration.
    let legacy = Data("""
    {"version":1,"project":{"videoDurationSeconds":120,"audioSources":[],
    "clips":[{"name":"Clip 1","start":10,"end":30}],
    "export":{"insetScale":0.9,"accent":"verdigris","beforeLabel":"VORHER","codec":"hevc"},
    "stills":{"headline":"Titel"}}}
    """.utf8)

    guard let old = try? JSONDecoder().decode(Document.self, from: legacy) else {
        FileHandle.standardError.write(Data("✗ A project from an earlier version no longer opens.\n".utf8))
        exit(1)
    }
    check(old.project.clips.count == 1, "The legacy clip was lost.")
    check(old.project.clips[0].look.insetScale == 0.9,
          "The global look was not moved onto the clip.")
    check(old.project.clips[0].look.afterColor == RGBColor.verdigris,
          "The legacy accent did not become the B colour.")
    check(old.project.clips[0].look.beforeLabel == "VORHER",
          "A stored label was lost in the migration.")
    check(old.project.clips[0].kind == .ab, "A legacy clip did not default to A/B.")
    check(old.project.export.codec == .hevc, "A delivery setting was lost while decoding.")
    check(old.project.stills.headline == "Titel", "A stored cover headline was lost while decoding.")
    check(old.project.defaultClipLengthSeconds == ABProject().defaultClipLengthSeconds,
          "A missing key did not fall back to its default.")

    // Anything that is not a project at all still has to be refused.
    check((try? JSONDecoder().decode(Document.self, from: Data(#"{"hello":"world"}"#.utf8))) == nil,
          "A file that is not a project was opened as an empty one.")

    // A round trip of today's shape has to be lossless — kind, passes and the
    // per-clip look included — and must not re-trigger the migration.
    var project = ABProject()
    var loop = Clip(name: "Loop 1", start: 5, end: 15, kind: .loop)
    loop.loopPasses = 2
    loop.look.afterColor = RGBColor(red: 0.1, green: 0.2, blue: 0.9)
    loop.look.beforeColor = .white
    var ab = Clip(name: "Clip 1", start: 20, end: 40)
    ab.look.afterColor = .ocker
    project.clips = [loop, ab]
    project.export.chromeSafeTop = 0.17
    let encoded = try JSONEncoder().encode(Document(version: 1, project: project))
    let restored = try JSONDecoder().decode(Document.self, from: encoded).project
    check(restored.clips[0].kind == .loop, "A round trip lost the clip kind.")
    check(restored.clips[0].loopPasses == 2, "A round trip lost the loop passes.")
    check(restored.clips[0].look.afterColor == RGBColor(red: 0.1, green: 0.2, blue: 0.9),
          "A round trip lost a free colour.")
    check(restored.clips[1].look.afterColor == RGBColor.ocker,
          "The clips' looks bled into each other.")
    check(restored.export.chromeSafeTop == 0.17, "A round trip changed a delivery setting.")

    // Loop semantics: no switches inside the selection — the boundary lies
    // between the exported passes.
    check(restored.clips[0].switches.isEmpty, "A loop clip reported switches in project time.")
    check(!restored.clips[1].switches.isEmpty, "An A/B clip lost its midpoint switch.")

    // Cards in the video: attached to the reel format, not to the feed one.
    check(ExportSettings().cardHold(for: .portrait916).tail > 0,
          "The reel format got no end card.")
    check(ExportSettings().cardHold(for: .portrait45).tail == 0,
          "A feed format was given a card hold.")
    var noCards = ExportSettings()
    noCards.cardAttachment = .off
    check(noCards.cardHold(for: .portrait916) == (0, 0), "Off still produced a hold.")

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
    "$WORK/Shim.swift" "$WORK/Project.swift" "$WORK/Timecode.swift" \
    "$WORK/BrandAccent.swift" "$WORK/main.swift"
"$WORK/checks"
