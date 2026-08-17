# Changelog

## 0.11.1 — the cards are one pair, and the type sits in its box

- The title card now has the end card's arrangement: the headline set large in
  the lead face, wrapping over up to three lines and fitted to whatever room is
  left, with the second line at the foot over a hard rule. No bar — that stays
  the end card's, because it is the wordmark's own arrangement. Seen one after
  the other the two cards are recognisably the same object.
- **Fixed:** the wordmark sat visibly high in its bar and the bar's padding was
  not even left to right. Two separate measuring faults, both of the kind that
  read as sloppiness rather than as a bug:
  - `size()` counts the tracking after the final glyph as well, which is space
    no letter uses. With the lead face's negative tracking that makes the
    measurement *shorter* than the ink, so the field cropped the last letter
    and the centred line sat off centre.
  - A line box reserves room for descenders whether the text has any or not,
    and set in capitals it never does. Building the field on the line height
    left a quarter of an em empty under the letters and nothing above.
  Both now go through `Typography.advance` and `Typography.capBox`, so the
  field is built on the capitals and the baseline, and the clip label's bar
  is fixed by the same change.
- A headline too long for its room shrinks and wraps rather than running off
  the card, and it is fitted against the space the foot leaves rather than
  against the whole canvas.

## 0.11.0 — the cards can ride in the video

- Title card and end card can now be built into the exported file, held at
  each end of the cut. A reel is a single video with no slides, so an end card
  either sits in the file or the address is never seen at all.
- Attached to 9:16 only by default. A feed post is a carousel, where both
  cards are pages of their own — putting them in the video as well spends the
  viewer's time on the same thing twice.
- 0.8 s at the head and 2.5 s at the tail, both adjustable, either one down to
  zero. The head is deliberately short: the first second of a reel decides
  whether it is watched, and the reel's cover image is already doing the
  title's job. Setting it to zero is a defensible choice and the panel says so.
- Each card is built from that clip's own first frame, so a batch of a dozen
  excerpts gets a dozen matching title cards without parking a playhead twelve
  times. In a batch the headline falls back to the film's name.
- The sound belongs to the film, not to the card in front of it: the audio and
  every A/B switch are shifted past the head hold, so the mix still starts on
  the first frame of picture.
- A card that cannot be built is simply given no hold, so a failed grab
  shortens the file instead of leaving a blank stretch in it.
- The holds are real time on the video track — a short seed of the clip slowed
  to fill them — because a Core Image handler is only asked for frames where
  the composition has some. What is underneath never shows: the cards are
  opaque and the source is dropped rather than composited over.

## 0.10.1 — the picture holds still

- The frame no longer snaps to full bleed at the switch. "Durchgehend
  gerahmt" is the default, so the picture stays exactly where it is and the
  A/B is carried by the type: the label goes from plain bone to the bar, and
  the strip names the layer being heard.
- The reasoning is the other way round from 0.4.0, and it is the better way
  round for this app. A scale change does carry more motion than a colour
  change — but both halves of an audio A/B show the identical picture, so
  every bit of movement is something the eye has to account for while the ear
  is meant to be doing the work. The snap is still one click away.
- The muted before-half stays, as the one remaining hint in the picture.
  Setting it to colour as well leaves nothing in the picture moving at all.
- Each framing choice says under the picker what it does to the picture,
  which is the thing being decided.

## 0.10.0 — the playouts run in the Sound Matters style

The look no longer belongs to this app. Colours, faces and the arrangement of
the furniture are taken from the website's `FARBEN.md` and `tokens.css`, and
`Core/Brand/` restates those values so nothing else has to hard-code one.

- **The palette.** Ink `#101014` as the ground, bone `#EFE6D2` as the type,
  and one of the five family colours per project — verdigris and ochre lead,
  because they are the printed versions of the sticker. Ochre by default: the
  website's film section runs in ochre and an A/B out of a finished film
  belongs to that section. The rules come with it — contrast through
  lightness, never tone on tone, ink on any coloured field.
- **The faces.** Archivo Black, Bodoni Moda and Space Mono are bundled and
  registered into the process at launch. They are the same files the site
  serves, converted from woff2, so a playout and a page cannot drift apart.
  If registration ever fails the app says so and falls back to Arial Black,
  Didot and Courier — the same stack the CSS names.
- **The bar.** The before/after label is now the sticker's own arrangement:
  the first half in plain bone, the second in a field of the accent with ink
  type and a hard contour, exactly as `matters.` sits in the wordmark. The A/B
  gets a typographic snap to go with the frame's. "Knochen" is the quieter
  version, and the two older styles are still there.
- **Two mono strips**, one at each end, over a hard rule — the frame of the
  sticker, unfolded. Top left is the film, top right is the layer you are
  hearing, so it changes at every switch. Bottom left is free, bottom right
  carries the address.
- **Grain and veil**, the site's `::before` and `::after`. The grain is
  regenerated per frame on purpose: still grain over moving picture reads as
  dirt on the lens, grain that moves reads as film.
- **An end card**, the last image of a post: the wordmark over ink or over a
  softened frame, with `soundmatters.audio` under a rule at the foot. It is
  the one card that needs no grab, so it can be made before a film is even
  loaded.
- Title cards follow the same palette and faces.
- The layout is worked out once now, in `FrameRenderer.layout`, instead of
  being recomputed from two loose functions in four places. Strips, picture,
  label band and safe area could disagree before; now they cannot.

## 0.9.0 — a safe area for the story chrome

- The frame no longer runs under Instagram's own controls. A 9:16 clip plays
  full screen with the account name over the top of it and the reply field
  over the bottom; the app now reserves a strip at each end of that canvas and
  lays the frame, its border and the burnt-in type out inside what is left.
  With the defaults the frame's top edge drops from 75 px to 255 px below the
  canvas top, which clears the header.
- 10 % top and 6 % bottom by default, both adjustable up to 25 %. Instagram
  publishes 250 px at each end of a 1080×1920 story as a blanket figure; the
  defaults are measured against where the controls actually land, and the
  sliders are there because the platforms move them.
- Only 9:16. A feed post draws its chrome outside the picture, so 4:5, 1:1 and
  16:9 are laid out exactly as before — pixel for pixel.
- A full-bleed picture still fills the canvas. The reserved strips hold the
  app's own furniture, not the film: the header may sit over the picture, it
  just must not sit over the frame or the label.
- Two dashed rules mark the strips in the 9:16 preview so the sliders can be
  judged against the picture. The exporter never asks for them, so they cannot
  reach a delivered file.
- Cover images honour the same strips, so a story title card no longer sets
  its headline behind the account name.
- **Fixed:** a project saved by an older version failed to open as soon as a
  release added a setting. Swift's generated decoder treats a missing key as
  an error even where the property has a default, so every new setting
  invalidated every saved project. The project, export and cover settings are
  now decoded key by key and fall back to today's defaults. A file that is not
  a project at all is still rejected.

## 0.8.1 — the fold is audible, and a clip click parks the playhead

- **Fixed:** a folded source stayed silent. `AVAudioFile` has no `close()` —
  its header is finalised only when the object is released — and the caller
  opened the file straight after writing, so the composition could read a
  container whose frame count was still zero. The writer is now dropped
  explicitly before the file is handed on, and the result is read back and
  rejected if it decodes to nothing, so a failure is visible instead of quiet.
- A source reports "Mono (gefaltet)" only once its companion exists, making
  the row an honest indication of what is heard.
- Clicking a clip in the timeline now moves the playhead to its start, so the
  cut point is visible at once. A drag still moves the clip; three points of
  slop separate the two.

## 0.8.0 — channel folding per source

- A channel mode on every audio layer: stereo as-is, sum L+R, left only, or
  right only. Production sound frequently carries the dialogue on one channel,
  and "left only" centres it without the 6 dB loss that summing against a
  silent side would cost.
- The fold is rendered into a mono companion file rather than mixed live. An
  `AVAudioMix` can set a track's volume but cannot re-route its channels, and
  an audio tap is not honoured on every rendering path — a tap could sound
  right in the preview and be wrong in the file. Rendering once means the
  preview and the export read the same audio by construction.
- The companion is genuinely one channel, so AVFoundation centres it and the
  file is half the size. It is cached in the temporary directory and re-made
  automatically when a project is opened and the cache has been cleared.
- The peak envelope is redrawn after a fold, so the lane shows what is heard.

## 0.7.0 — live A/B fixed, German interface, several switches per clip

- **Fixed:** the default monitor mode fell silent whenever no clip was
  selected, because the A and B sides resolved to nothing and every track was
  muted. Both sides now fall back to the project defaults.
- **Fixed:** the preview switched with a hard volume step while the export
  crossfaded, and the seek that flushes a swapped audio mix stopped playback.
  The preview now uses the exporter's own ramp code and resumes the transport.
- Manual A/B: "Nur A" and "Nur B" solo one side outright, ⇧⌘1 and ⇧⌘2. This
  is the comparison an ear actually wants, and the quickest way to tell
  whether both sources are audible at all.
- A clip can hold any number of A/B switches, not just one. They simply
  alternate — A, B, A, B — so a rhythm of comparisons is a plain list of times
  with no per-segment state. ⌘\ adds one at the playhead; the timeline paints
  the bands and every mark can be dragged. Old projects with a single split
  still open.
- The interface is in German throughout.

## 0.6.0 — a proper menu bar and a tabbed inspector

- A real macOS menu bar: File, Clip, Playback and View, with every action the
  app can perform and a keyboard shortcut on each. A toolbar teaches nothing
  about shortcuts and a panel buries anything below the fold; a menu does both
  jobs. Transport follows the J / K / L convention, bound with Command so a
  bare keystroke is never stolen from a text field.
- The right-hand column is now four tabs — Clips, Look, Cover, Export —
  instead of one scroll holding seven stacked cards. The tabs match the four
  moments of the job rather than the shape of the code.
- Without a film loaded that column explains the run of play in four steps
  instead of showing controls that cannot do anything yet.
- The status bar carries the project at a glance: clip count, how many are
  enabled, audio layers, output folder, and batch progress while it runs.
- The toolbar is shorter and gained Cover and Export, the two actions that
  finish a session.
- Grabbing a cover switches to the Cover tab and prefills the headline with
  the film's name.
- Look settings now survive loading a new film; the cover text does not,
  because it belonged to the film that was replaced.

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
