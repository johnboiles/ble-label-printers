---
name: ble-label-printers
description: Control reverse-engineered Bluetooth LE label printers from macOS, including Brother PT-N25BT and SUPVAN E10 1bpp label generation, preview review, status checks, and printing.
---

# BLE Label Printers

Use this skill when the user wants to print labels, inspect status, generate
artwork, or continue reverse engineering a supported BLE label printer from
macOS.

Supported printers:

- Brother PT-N25BT
- SUPVAN E10

## Shared Workflow

1. Work from the repository root.
2. Generate a true 1bpp preview and printer job.
3. Review the preview before printing. Preview images intentionally omit
   printer-specific trailing padding.
4. For custom artwork, inspect a nearest-neighbor 4x preview and reject any
   glyph/icon contact, clipping, or crowding before printing.
5. Build the relevant signed CoreBluetooth app bundle.
6. Print through `open -Wn .build/<App>.app`, not the raw executable, so macOS
   Bluetooth permissions attach to the signed app.
7. Read stdout and stderr after every print.

## Visual QA For Custom Labels

- Treat requested text as primary. Omit decorative icons unless they fit with
  clear whitespace around the text.
- Track bounding boxes for all text and decorative elements while generating
  custom artwork. On PT-N25BT bitmap labels, use
  `pixel_text_box(...)` and `assert_boxes_clear(...)` from
  `tools/ptn25bt/generate_prn.py` when placing icons near text.
- Require at least 4 px of clearance between text and non-text decorations.
  Use 8-12 px when there is available room, especially on the left/right ends.
- Never let icons, dividers, waveforms, arrows, bolts, dots, frames, or borders
  touch or cross a glyph unless the user explicitly asks for that effect.
- Review the 4x nearest-neighbor preview at original detail. If any element
  looks like it might collide with text, regenerate a simpler text-first layout.

## Brother PT-N25BT

Build:

```sh
./scripts/build-ptn25bt.sh
```

Generate a label:

```sh
python tools/ptn25bt/generate_prn.py work/brother-label.prn \
  --text "HELLO" \
  --length-px 320 \
  --preview-png work/brother-label.png
```

Print:

```sh
open -Wn .build/PTN25BT.app \
  --stdout work/brother-print.out \
  --stderr work/brother-print.err \
  --args --name PT-N25BT --scan-seconds 60 send-file "$PWD/work/brother-label.prn"
```

Known-good defaults for 12 mm tape:

- Brother feed margin `0`.
- `13.4 mm` blank trailing raster columns appended at PRN generation time.
- Successful BLE transfers ACK with `06f001`.

Useful patterns:

```sh
python tools/ptn25bt/generate_prn.py work/brother-border.prn --calibration border --length-px 220 --border-px 2 --preview-png work/brother-border.png
python tools/ptn25bt/generate_prn.py work/brother-margin.prn --calibration margin-test --text "TEST" --length-px 220 --border-px 2 --preview-png work/brother-margin.png
python tools/ptn25bt/generate_prn.py work/brother-showoff.prn --calibration showoff --length-px 560 --preview-png work/brother-showoff.png
```

For raw feed/margin testing, set `--trailing-pad-mm 0`. Avoid using Brother
`--margin-mm` for visual centering unless deliberately testing feed/cutter
behavior.

Status:

```sh
open -Wn .build/PTN25BT.app \
  --stdout work/brother-status.out \
  --stderr work/brother-status.err \
  --args --name PT-N25BT --scan-seconds 60 status
```

Expected idle 12 mm media status includes model series `0x41`, model `0x30`,
errors `0x0000`, and width `12mm`.

## SUPVAN E10

Build:

```sh
./scripts/build-supvan-e10.sh
```

Generate a label:

```sh
python tools/supvan-e10/generate_job.py work/e10-label.spv \
  --text "HELLO" \
  --length-mm 40 \
  --preview-png work/e10-label.png
```

Print:

```sh
open -Wn .build/SupvanE10.app \
  --stdout work/e10-print.out \
  --stderr work/e10-print.err \
  --args --name T0011 --scan-seconds 25 send-file "$PWD/work/e10-label.spv"
```

Known-good defaults for 12 mm tape:

- `8 dots/mm`, or `203.2 dpi`.
- `96` printable/transfer dots vertically.
- `12` bytes per vertical column.
- `6.0 mm` blank trailing columns appended at job generation time.
- Default density/deepness `4`; try `--deepness 5`, `6`, or `7` if output is
  weak.

Useful pattern:

```sh
python tools/supvan-e10/generate_job.py work/e10-border.spv --calibration border --length-px 240 --preview-png work/e10-border.png
```

Status:

```sh
open -Wn .build/SupvanE10.app \
  --stdout work/e10-status.out \
  --stderr work/e10-status.err \
  --args --name T0011 --scan-seconds 25 status
```

## Constraints

- Printer artwork must be true 1bpp. Do not print grayscale/antialiased
  previews without thresholding.
- Review generated previews for alignment, overlaps, and readability before
  printing.
- Keep printer-specific trailing padding out of previews; append it only to the
  transmitted job stream.
- Prefer bitmap fonts or carefully thresholded text for tiny labels.
- If scanning times out, ask the user to wake or power on the target printer.
