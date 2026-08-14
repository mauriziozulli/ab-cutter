# AB Cutter

A small native macOS app for one job: lay every available audio version under
a finished film, then cut social-media excerpts that switch from **before** to
**after** halfway through — black & white with the original track on the first
half, colour with your mix on the second.

No NLE round-trip, no manual re-crop for every aspect ratio.

## What it does

**Lay the audio under the picture.** Load the finished film, then add as many
audio layers as you like: the original production sound, your final mix,
stems such as SFX-only or music-only. Every layer sits on its own lane.

**Sync by timecode, or by hand.** WAV files stamped with a Broadcast Wave
`bext` time reference and QuickTime files with a `tmcd` timecode track are
lined up against the picture automatically — the offset is simply
`audio start − picture start`. Anything unstamped starts at the head of the
film and can be nudged frame by frame, typed in as a number, or dragged
directly on its lane against the peak envelope.

**Monitor the A/B.** The preview can solo any single layer, or follow the
split exactly as the export will: before-source until the switch, after-source
after it. It can also render the real 4:5 or 9:16 crop and the black & white
grade while you scrub, so the framing is decided before anything is encoded.

**Cut to a house length.** Set the length once — 10, 15, 20, 30, 60 seconds
or anything you type — and every new clip is that long. With the length locked,
marking in and out slides a fixed window rather than trimming an edge, so
clipping a film down to a dozen excerpts is scrub, ⌘N, scrub, ⌘N. Existing
clips can be snapped to the house length in one go, and the A/B switch keeps
its relative position so a re-length never moves the reveal.

Social platforms publish upper limits rather than fixed durations, and those
limits move: Stories cards are cut into segments past their ceiling, Reels run
into the minutes. The app therefore holds *your* length rather than
hard-coding anyone's, which is also what keeps a set of before/after cuts
looking like a series.

**Batch-export.** The A/B switch defaults to the exact middle of each clip and
can be moved anywhere. Export every enabled clip into every selected format in
one run — 4:5, 9:16, 1:1 and 16:9 are all available, and the clip × format
matrix is encoded sequentially with per-file progress.

## Requirements

- macOS 13 or later
- Xcode 15 or later (only to build it)

## Build and run

```bash
git clone https://github.com/mauriziozulli/ab-cutter.git
cd ab-cutter
swift run
```

Or open `Package.swift` in Xcode, pick the **ABCutter** scheme, and run on
**My Mac**.

To produce a distributable `.app` and `.dmg`:

```bash
packaging/build-app.sh
```

The output lands in `build/`. The app is ad-hoc signed rather than notarised,
so the first launch needs **right-click → Open**.

## How the pieces fit

| Area | Files |
| --- | --- |
| Project model, clips, formats | `Core/Models/Project.swift` |
| SMPTE timecode, drop-frame | `Core/Models/Timecode.swift` |
| `bext` and `tmcd` readers | `Core/Services/TimecodeReader.swift` |
| Duration, size, channels | `Core/Services/MediaProbe.swift` |
| Peak envelopes | `Core/Services/WaveformExtractor.swift` |
| Track layout and A/B mix | `Core/Services/CompositionBuilder.swift` |
| Crop, pan, grade, labels | `Core/Services/FrameRenderer.swift` |
| Label tint sampling | `Core/Services/PaletteSampler.swift` |
| Label assembly | `Core/Services/LabelFactory.swift` |
| Reader → writer encode | `Core/Services/ClipExporter.swift` |
| Batch run | `Core/Services/ExportQueue.swift` |

### The timeline model

`t = 0` is the first frame of the picture. Every audio source carries an
`offsetSeconds` describing where its own first sample lands on that timeline;
a negative offset means the audio starts before the picture does and is
trimmed at the head. Clips are stored in the same project time, and the export
rebuilds a fresh composition per clip so the clip always starts at zero.

### The export path

Each output file is one `AVAssetReader` → `AVAssetWriter` pass:

- an `AVMutableVideoComposition` with a Core Image handler crops and scales the
  frame into the target size, applies the before or after grade depending on
  where the frame sits relative to the split, and composites the burnt-in
  label;
- an `AVAudioMix` crossfades from the before-source to the after-source at the
  split;
- the burnt-in label is drawn ahead of the pass, tinted with the dominant hue
  of the cropped frame. The hue comes from the ungraded picture so the
  black-and-white half keeps a coloured label, and only the hue is borrowed:
  lightness is pushed away from the strip behind the text until the WCAG
  contrast ratio clears a legible threshold, with a soft shadow as the
  fallback where no tint can win;
- audio is decoded to LPCM and folded to stereo, so a 5.1 stem still delivers a
  usable social bed;
- video is encoded as H.264 High (or HEVC) at a bitrate derived from the frame
  size and rate, with Rec. 709 tagging.

## What it deliberately does not do

- It does not modify the source video or audio. Everything is read-only and
  every output is a new file.
- It does not detect sync by listening to the audio. Sync comes from embedded
  timecode or from you.
- It does not notarise or sign for distribution.

## Licence

Not yet chosen.
