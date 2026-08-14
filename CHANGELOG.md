# Changelog

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
