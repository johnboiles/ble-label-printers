---
name: brother-ptn25bt
description: Control and print to a Brother PT-N25BT Bluetooth Low Energy label printer from macOS, including generating 1bpp Brother raster PRN files, building the CoreBluetooth sender, checking status, and printing labels.
---

# Brother PT-N25BT BLE Labels

Use this skill when the user wants to print labels, inspect status, or generate artwork for a Brother PT-N25BT label printer from macOS.

## Workflow

1. Work from the repository root.
2. Build the signed CoreBluetooth sender:

```sh
./scripts/build-ptn25bt.sh
```

3. Generate a 1bpp PRN with `tools/ptn25bt/generate_prn.py`.
4. Review any `--preview-png` before printing. Preview images intentionally omit printer-specific trailing padding.
5. Print through the signed app bundle, not the raw executable, so macOS Bluetooth permissions attach to the app:

```sh
open -Wn .build/PTN25BT.app \
  --stdout work/print.out \
  --stderr work/print.err \
  --args --name PT-N25BT --scan-seconds 60 send-file "$PWD/work/label.prn"
```

6. Read `work/print.out` and `work/print.err`. Successful BLE transfers ACK with `06f001`.

## Generate Labels

Known-good defaults for 12 mm tape:

```sh
python tools/ptn25bt/generate_prn.py work/label.prn \
  --text "HELLO" \
  --length-px 320 \
  --preview-png work/label.png
```

Defaults use Brother feed margin `0` and append `13.4 mm` of blank raster columns at PRN generation time to visually balance the PT-N25BT's mechanical leading blank.

Useful calibration patterns:

```sh
python tools/ptn25bt/generate_prn.py work/border.prn --calibration border --length-px 220 --border-px 2 --preview-png work/border.png
python tools/ptn25bt/generate_prn.py work/margin.prn --calibration margin-test --text "TEST" --length-px 220 --border-px 2 --preview-png work/margin.png
python tools/ptn25bt/generate_prn.py work/showoff.prn --calibration showoff --length-px 560 --preview-png work/showoff.png
```

For raw feed/margin testing, set `--trailing-pad-mm 0`. Avoid using Brother `--margin-mm` for visual centering unless deliberately testing feed/cutter behavior.

## Status

```sh
open -Wn .build/PTN25BT.app \
  --stdout work/status.out \
  --stderr work/status.err \
  --args --name PT-N25BT --scan-seconds 60 status
```

Expected idle 12 mm media status includes model series `0x41`, model `0x30`, errors `0x0000`, and width `12mm`.

## Constraints

- Printer artwork must be 1bpp. Do not trust grayscale previews for layout.
- Built-in patterns use a 5x7 bitmap font for tiny text.
- Compression is experimental; default to uncompressed PRN output.
- If scanning times out, ask the user to wake or power on the printer.
