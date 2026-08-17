# AB Cutter

A small native macOS app for one job: lay every available audio version under
a finished film, then cut social-media excerpts that switch from **before** to
**after** halfway through — the original track first, your mix second, with the
picture holding still so the ear has nothing to compete with.

No NLE round-trip, no manual re-crop for every aspect ratio.

## What it does

**Lay the audio under the picture.** Load the finished film, then add as many
audio layers as you like: the original production sound, your final mix,
stems such as SFX-only or music-only. Every layer sits on its own lane, and
every clip picks its own pair of them to compare.

**One fixed design, two free colours.** Every playout is the same object:
the picture in colour, framed with a thin border over a blurred copy of
itself, a small type line per side, two mono strips. What each clip chooses
is its **A colour and B colour** — border and type carry them together, so
the switch reads as one event. White before, blue after, or any pair the
film wants; six brand swatches and a free picker per side.

**Two kinds of clip.** An **A/B** flips between the two sources at each
switch point while the picture runs on; a **Loop** plays the selection once
with the A source, then the identical selection again with the B source —
the ear hears the same moment twice, which is the honest comparison. The
kinds carry their own colours on the timeline, and the player's clip preview
(⇧⌘P) plays a clip exactly as it will be exported, loop passes included.

**Sync by timecode, by waveform, or by hand.** WAV files stamped with a
Broadcast Wave `bext` time reference and QuickTime files with a `tmcd`
timecode track are lined up against the picture automatically. Everything
else can be synced **by the sound itself**: the film's embedded track and a
mix contain the same dialogue, so cross-correlating the two finds the offset
a two-pop would have marked — within ±5 ms, and with a confidence readout
that refuses a doubtful match rather than placing it.

Manual sync is built for the eye: the lanes draw a peak envelope fine enough
to show single transients when zoomed in (5 ms per bucket — eight per frame
at 25 fps), and every external lane carries a faint ghost of the film's own
embedded track behind its waveform. Drag the lane until the two shapes cover
each other; hold **⇧** to gear the drag down twenty to one for the last
frame. The lane label reads out the live offset while it moves, and typed
offsets and frame nudges remain.

**Mark the switch without moving the picture.** Both halves of an audio A/B
show the identical frame, so anything that moves is something the eye has to
account for while the ear is meant to be working. The picture holds still,
always in colour, and the switch is carried entirely by the colours: border
and label change together, and the strip names the layer being heard.

**Everything comes out in the Sound Matters faces.** Archivo Black, Bodoni
Moda and Space Mono are bundled — the same files the website serves — so a
playout and a page are set in the same type. A mono strip runs over a hard
rule at each end, carrying the film, the layer you are hearing, and the
address. Grain and a veil sit over the picture the way they do over every
section of the site, and the two still cards keep the full brand arrangement,
wordmark bar included.

**Stay clear of the story chrome.** A 9:16 clip plays full screen with the
account name over the top of it and the reply field over the bottom, so a
frame drawn towards the canvas edge disappears underneath them. The app
reserves a strip at each end of a 9:16 canvas — 10 % and 6 % by default,
adjustable — and lays the frame, its border and the burnt-in type out inside
what is left. A full-bleed picture still fills the canvas: the chrome may sit
over the film, it just must not sit over the furniture. Feed formats have no
chrome over the picture and are untouched. In the 9:16 preview two dashed
rules mark the strips; they never reach a file.

**Monitor the A/B.** The preview can solo any single layer, or follow the
split exactly as the export will: before-source until the switch, after-source
after it. It can also render the real 4:5 or 9:16 crop and the frame while
you scrub, so everything is decided before anything is encoded.

**See every delivery at once.** Over the full picture the player draws one
coloured outline per selected output format — 4:5 in Rost, 16:9 in Ocker,
9:16 in Staubblau, 1:1 in Verdigris — each computed through the real export
layout, so safe area, strips, frame inset and the clip's pan all count.
What is inside a line is exactly what that delivery keeps. The guides are
the «Ausschnitte» checkbox beside the format picker.

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

**Make the cover image.** Park the playhead and grab that frame at the film's
native resolution. The same grab doubles as a title card: cropped to every
selected format, softened and darkened so type can sit on it, with a wrapping
headline and a quieter second line.

**And the end card.** The last image of a post: the wordmark over ink — or
over the same frame, softened further — with `soundmatters.audio` under a rule
at the foot. It is the one card made of nothing but type, so it needs no grab
and can be written before a film is even loaded.

**Put both cards in the video, for a reel.** A reel is a single video with no
slides, so an end card either sits in the file or the address is never seen.
Both cards can therefore be held at the ends of the exported cut — 9:16 only
by default, because a feed post is a carousel where they are pages of their
own. The head hold is short on purpose, and worth setting to zero: the first
second of a reel decides whether it is watched at all, and the reel's cover
image already does the title's work. Each card is built from that clip's own
first frame, so a batch of a dozen excerpts gets a dozen matching cards. The
sound still starts on the first frame of picture, not under the card.

**Batch-export.** The A/B switch defaults to the exact middle of each clip and
can be moved anywhere. Export every enabled clip into every selected format in
one run — 4:5, 9:16, 1:1 and 16:9 are all available, and the clip × format
matrix is encoded sequentially with per-file progress.

## Getting around

The window is three columns: audio layers on the left, the picture and
timeline in the middle, and a three-tab inspector on the right — **Clips**,
**Cover**, **Export**. The look sits under each clip, because it belongs to
the clip; the Export tab holds only what is decided once per delivery.

Everything is also in the menu bar with a shortcut. Transport is ⌘J / ⌘K / ⌘L
for back a frame, play, forward a frame, with Shift for ten. ⌘N drops an A/B
clip at the playhead and ⇧⌘N a loop, ⇧⌘P plays the selected clip exactly as
it will be exported, ⌘[ and ⌘] mark in and out, ⌘\\ moves the A/B switch, and
⌘0–⌘4 flip the framing preview between full frame and each social format.
Bare **T** and **R** zoom the timeline in and out, the Pro Tools way — they
stay quiet while a text field is being typed into.
Shortcuts all carry a modifier on purpose: a bare key equivalent would be
swallowed before it reached a text field.

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
| Palette and the three faces | `Core/Brand/Brand.swift`, `Core/Brand/Typography.swift` |
| Crop, pan, grade, framing, texture | `Core/Services/FrameRenderer.swift` |
| Strips, border, label, second line | `Core/Services/OverlayRenderer.swift` |
| Title and end cards | `Core/Services/CardRenderer.swift` |
| Label tint sampling (non-house styles) | `Core/Services/PaletteSampler.swift` |
| Overlay assembly | `Core/Services/LabelFactory.swift` |
| Reader → writer encode | `Core/Services/ClipExporter.swift` |
| Batch run | `Core/Services/ExportQueue.swift` |
| Menu bar and shortcuts | `App/AppCommands.swift` |
| Framegrabs and card composition | `Core/Services/StillExporter.swift` |

### The timeline model

`t = 0` is the first frame of the picture. Every audio source carries an
`offsetSeconds` describing where its own first sample lands on that timeline;
a negative offset means the audio starts before the picture does and is
trimmed at the head. Clips are stored in the same project time, and the export
rebuilds a fresh composition per clip so the clip always starts at zero.

### The export path

Each output file is one `AVAssetReader` → `AVAssetWriter` pass:

- an `AVMutableVideoComposition` with a Core Image handler places the picture
  into its rect for that half — the full canvas, or an inset frame over a
  blurred backdrop — applies the grade, and composites the overlay;
- an `AVAudioMix` crossfades from the before-source to the after-source at the
  split;
- the overlay — frame border, label and second line — is one full-canvas image
  per half, drawn with AppKit ahead of the pass. It is tinted with the dominant
  hue of the cropped frame, read from the ungraded picture so a monochrome half
  still gets a coloured label. Only the hue is borrowed: lightness is pushed
  away from the strip behind the text until the WCAG contrast ratio clears a
  legible threshold, with a soft shadow as the fallback where no tint can win;
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
