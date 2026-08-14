# Changelog

## 0.5.0 — cover images

- A Cover image section: park the playhead, grab that frame at the film's
  native resolution, and save it as PNG or JPEG. The grab is frame-accurate,
  not a nearby keyframe.
- The same frame becomes a title card, cropped to every selected output format
  so a post's cover matches the cut it leads.
- A headline that wraps over up to three lines, plus a quieter second line for
  direction or credits, positioned top, centre or bottom.
- Blur and darken sliders soften the picture so the type has somewhere to sit.
  The label tint is read off the *finished* backdrop rather than the raw frame,
  so it contrasts with what the type actually lands on.
- The preview renders at a proxy size and the delivery at full size, which is
  what lets the sliders be judged against the picture in real time.

## 0.4.0 — framed before, second line, draggable clips

- The before half can now sit inset in a bordered frame and snap out to full
  bleed at the switch. On an audio A/B both halves show the identical picture,
  so a scale change is the only treatment that carries real motion — and it
  reads faster on a phone than a colour change does. The canvas around the
  inset picture is a blurred, darkened copy of the frame, or a near-black card.
- Because the frame now carries the switch, the before half defaults to muted
  colour rather than black and white. Monochrome is still one click away.
- A hairline border around the inset picture, drawn in the same tint as the
  label.
- A quieter second line under the before/after label for a film title,
  direction or credits. It is centred with the label and carries its tint.
- Clips are directly manipulable on the timeline: drag the body to move,
  an edge to trim, the dashed mark to move the A/B switch. With the house
  length locked, an edge drag slides the window instead of trimming, matching
  Mark in and Mark out. The player is rebuilt once on release rather than once
  per pixel.
- The frame furniture — border, label, second line — is drawn once per half as
  a full-canvas overlay instead of a small label image, which is what makes
  laying type against the frame edge tractable.

## 0.3.0 — labels tinted from the picture

- Burnt-in labels can now be bold plain type with no plate, coloured with the
  dominant hue of the cropped frame, which gives every clip its own palette.
  The old white-on-a-pill look is still selectable.
- The hue is sampled from the *ungraded* frame, so the black-and-white before
  half still carries a coloured label — that is the point of tinting.
- Only the hue is borrowed. Lightness is forced away from the strip of picture
  behind the text, and the result is checked as a WCAG contrast ratio, because
  a colour taken from an image is by definition close to that image.
- A soft shadow keeps plain type readable where no tint can win, over mid-tone
  footage. It defaults to Auto: applied only when the measured contrast falls
  short, and it can be forced off or on.
- The framing preview now renders the labels too, so the colours can be judged
  before exporting rather than after.

## 0.2.0 — house clip length

- A house clip length that new clips are cut to, with 10 / 15 / 20 / 30 / 60 s
  presets and a free numeric field. Social platforms publish upper limits
  rather than fixed durations, and move them regularly, so the app keeps a
  length you choose instead of hard-coding anyone's ceiling.
- "Keep every clip this length" turns the in and out points into a sliding
  fixed-length window: marking in starts the window at the playhead, marking
  out ends it there, and the opposite edge follows.
- "Apply to all clips" snaps existing clips to the house length, anchored on
  their in points. The A/B switch keeps its position proportionally, so
  re-lengthing never moves the reveal.
- A clip near the end of the film slides back to keep its length instead of
  being truncated.
- ⌘N drops a clip at the playhead.
- Per-clip length readout with a "House" button to snap a single clip.

## 0.1.0 — first working build

Initial version of AB Cutter.

- Load a finished film and lay any number of audio layers under it: the
  original production sound, a final mix, or stems.
- Automatic sync from Broadcast Wave `bext` time references and QuickTime
  `tmcd` timecode tracks; manual sync by frame nudge, typed offset, or by
  dragging a lane against its peak envelope.
- Preview player with per-layer solo, A/B monitoring that follows the split,
  live 4:5 / 9:16 / 1:1 / 16:9 framing preview, and the before-grade applied
  while scrubbing.
- Clips with in/out points and an A/B split that defaults to the exact middle
  and can be moved anywhere inside the clip.
- Per-clip framing offset for the crop, and per-source gain.
- Batch export of every enabled clip into every selected format, H.264 or
  HEVC, with a stereo downmix, an audio crossfade at the split, and optional
  burnt-in VORHER / NACHHER labels.
- `.abcut` project files holding paths and sync decisions — no media is
  copied.
