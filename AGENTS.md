# AB Cutter — Repository Instructions

AB Cutter is a native macOS app that lays alternative audio versions under a
finished film and exports before/after social-media excerpts from it.

## Working rules

- The app is read-only with respect to source media. Never rewrite, re-encode
  in place, or move a file the user pointed at. Every deliverable is a new
  file.
- Timecode is only ever a display and entry format. Everything stored and
  computed internally is real seconds; conversions live in
  `Core/Models/Timecode.swift` and nowhere else.
- Sync offsets are always "seconds from the first frame of the picture".
  A negative offset means the audio starts earlier than the picture.
- Keep decoding, composition building, rendering and encoding separate. The
  export path must stay usable without any view being alive.
- AppKit drawing (labels, icons) happens on the main actor and is handed to
  the exporter as finished images. The exporter itself must not touch AppKit.
- Preserve native macOS behaviour: real menus, keyboard transport, Finder
  reveal, and no modal progress that blocks the window.
- The look is not this app's to invent. Colours, faces and the arrangement of
  the furniture come from the Sound Matters website
  (`github.com/mauriziozulli/soundmatters`), whose `FARBEN.md` and
  `src/styles/tokens.css` are the source. `Core/Brand/` restates those values
  and nothing else may hard-code one. If the sticker changes, that repo
  changes first and this one follows it.

## Change discipline

For each completed step:

1. Build the target when the environment allows it (`swift build`).
2. List changed files.
3. Summarise user-visible and architectural effects.
4. Keep commits focused; do not commit unrelated changes.

## Versioning

`Sources/ABCutter/App/AppVersion.swift` holds the version string that
`packaging/build-app.sh` reads. Bump it together with an entry in
`CHANGELOG.md`.
