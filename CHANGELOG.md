# Changelog

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
