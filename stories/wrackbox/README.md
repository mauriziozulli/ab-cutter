# WRACKBOX MK1 — Instagram Story Serie

Sechs Stories plus Endkarte, 1080 × 1920, im Sound-Matters-Look des Apps.

```
python3 stories/wrackbox/build.py
```

schreibt `out/wrackbox-story-01.png` … `out/wrackbox-story-07-endcard.png`.

## Woher der Look kommt

Nichts davon ist hier erfunden. `build.py` schreibt nur die Werte fest, mit
denen die App selbst zeichnet:

| Element | Quelle im Code |
| --- | --- |
| Knochen, Ocker, Tinte, Linienstärke | `Core/Brand/Brand.swift` |
| Archivo Black / Bodoni Moda / Space Mono, Laufweiten | `Core/Brand/Typography.swift` |
| Weichzeichnung, Abdunklung des Grundes | `StillExporter.soften` / `.dim` |
| Balken mit Kontur, Fußzeile über harter Linie | `CardRenderer.drawBar` / `.drawFoot` |
| Mono-Streifen mit Linie, Rand- und Seitenmaße | `FrameRenderer` |
| Korn und Vignette | `FrameRenderer.grain` / `.veil` |
| Safe Area 10 % oben, 6 % unten | `ExportSettings.chromeSafeTop/Bottom` |

Gerendert wird über Headless-Chromium statt über AppKit, damit das Ganze auch
ohne Mac läuft. Die App bleibt der einzige Renderer, der ausgeliefert wird.

## Abweichungen von den App-Voreinstellungen

- **Weichzeichnung 6 statt 45.** Bei 45 (Radius 78 px) ist das Rack nicht mehr
  zu erkennen; eine Story lebt aber davon, dass man die Kiste sieht.
- **Abdunklung 0.38 – 0.48** statt 0.30, weil hier mehr Text auf dem Bild steht
  als auf einer Titelkarte.

## Dateien

- `source/` — die Originalfotos, unverändert.
- `photos/` — daraus auf 9:16 beschnitten, erzeugt von `build.py`.
- `out/` — die fertigen Stories.
- `.build/` — die erzeugten HTML-Seiten, nur ein Zwischenschritt.

## Reihenfolge und Bildzuordnung

| # | Inhalt | Foto |
| --- | --- | --- |
| 1 | Hook | Rack von vorn, Bühne |
| 2 | Das Problem | Werkbank im Bau |
| 3 | Die Idee | Rack zu, von hinten |
| 4 | Timetable | Rack offen, Werkstatt |
| 5 | Robustheit | Front, enger Ausschnitt |
| 6 | Integration + Close | Rückseite mit XLR, Bühne |
| 7 | Endkarte | Tinte, ohne Bild |

Story 2 ist der wichtigste Slide — Problem vor Produkt. Textmenge pro Story
nicht erhöhen.
