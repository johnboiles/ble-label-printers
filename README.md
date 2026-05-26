# BLE Label Printers

macOS tooling and a Codex skill for reverse-engineered Bluetooth Low Energy
label printers.

This is unofficial software. It currently supports:

- Brother PT-N25BT on 12 mm tape.
- SUPVAN E10 on 12 mm tape.

## What Works

- Discover and inspect nearby BLE peripherals from macOS.
- Generate true 1bpp preview images before printing.
- Generate printer-specific job files with calibrated trailing padding.
- Print through signed CoreBluetooth app bundles so macOS Bluetooth permissions
  attach to stable app identities.

## Visual QA

Before printing custom artwork, inspect a nearest-neighbor enlarged preview and
reject layouts where icons, dividers, waveforms, arrows, bolts, dots, frames, or
borders touch or crowd the text. Text should be treated as the primary content;
decorative elements should be omitted unless they fit with clear whitespace.

For PT-N25BT bitmap labels, `tools/ptn25bt/generate_prn.py` includes helper
functions for custom scripts:

- `pixel_text_box(...)` computes the exact box for bitmap text.
- `assert_boxes_clear(...)` rejects layout boxes that collide or get closer
  than the configured padding.

Use at least 4 px of clearance between text and non-text decorations, and 8-12
px when there is enough room.

## Requirements

- macOS with Bluetooth enabled.
- Xcode command line tools for `swiftc` and `codesign`.
- Python 3 with Pillow.

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

Optional BLE scanner:

```sh
./scripts/build-ble-scan.sh
open -Wn .build/BLEScan.app \
  --stdout work/ble-scan.out \
  --stderr work/ble-scan.err \
  --args --scan-seconds 20
```

## Brother PT-N25BT

Build:

```sh
./scripts/build-ptn25bt.sh
```

Generate a 1bpp preview and PRN:

```sh
. .venv/bin/activate
python tools/ptn25bt/generate_prn.py work/brother-hello.prn \
  --text "HELLO" \
  --length-px 320 \
  --preview-png work/brother-hello.png
```

Review `work/brother-hello.png`, then print:

```sh
open -Wn .build/PTN25BT.app \
  --stdout work/brother-print.out \
  --stderr work/brother-print.err \
  --args --name PT-N25BT --scan-seconds 60 send-file "$PWD/work/brother-hello.prn"
```

Known-good defaults:

- 180 dpi raster stream.
- 64-dot printable height inside 128-dot transfer lines.
- Brother feed/margin command `ESC i d = 0`.
- `13.4 mm` of blank trailing raster columns appended after the artwork.
- Preview PNGs intentionally omit that trailing padding.

Useful calibration patterns:

```sh
python tools/ptn25bt/generate_prn.py work/brother-border.prn \
  --calibration border \
  --length-px 220 \
  --border-px 2 \
  --preview-png work/brother-border.png

python tools/ptn25bt/generate_prn.py work/brother-showoff.prn \
  --calibration showoff \
  --length-px 560 \
  --preview-png work/brother-showoff.png
```

## SUPVAN E10

Build:

```sh
./scripts/build-supvan-e10.sh
```

Generate a true 1bpp preview and compressed `.spv` job:

```sh
. .venv/bin/activate
python tools/supvan-e10/generate_job.py work/e10-hello.spv \
  --text "HELLO" \
  --length-mm 40 \
  --preview-png work/e10-hello.png
```

Review `work/e10-hello.png`, then print:

```sh
open -Wn .build/SupvanE10.app \
  --stdout work/e10-print.out \
  --stderr work/e10-print.err \
  --args --name T0011 --scan-seconds 25 send-file "$PWD/work/e10-hello.spv"
```

Known-good defaults:

- 8 dots/mm, which is 203.2 dpi.
- 96-dot transfer height for 12 mm tape.
- 12 bytes per vertical column.
- LZMA-Alone compressed 4000-byte page buffers.
- `6.0 mm` of blank trailing columns appended after the artwork.
- Preview PNGs intentionally omit that trailing padding.
- Default density/deepness is `4`; the app supports up to `7`.

Useful calibration pattern:

```sh
python tools/supvan-e10/generate_job.py work/e10-border.spv \
  --calibration border \
  --length-px 240 \
  --preview-png work/e10-border.png
```

## Codex Skill

This repository is also a Codex skill. The root [SKILL.md](SKILL.md) contains
the operational workflow for agents that need to generate, inspect, or print
labels.

Install it directly as a local Codex skill:

```sh
mkdir -p ~/.codex/skills
git clone https://github.com/johnboiles/ble-label-printers.git \
  ~/.codex/skills/ble-label-printers
```

## Reverse-Engineered Notes

### Brother PT-N25BT

BLE service and characteristics:

- Service: `A76EB9E0-F3AC-4990-84CF-3A94D2426B2B`
- Read/status: `A76EB9E1-F3AC-4990-84CF-3A94D2426B2B`
- Write-with-response: `A76EB9E2-F3AC-4990-84CF-3A94D2426B2B`
- Write-without-response and ACK notify:
  `A76EB9E3-F3AC-4990-84CF-3A94D2426B2B`
- Printer status notify: `A76EB9E4-F3AC-4990-84CF-3A94D2426B2B`

BLE write-without-response payloads are framed as:

```text
06 f0 <packet_count> 00 <payload>
```

Successful segment ACK:

```text
06 f0 01
```

### SUPVAN E10

Observed device:

- Advertised name: `T0011B2112291094`
- Advertised service: `FEE7`
- Active service: `0000E0FF-3C17-D293-8E48-14FE2E4DA212`
- Notify/write characteristic: `FFE1`
- Write characteristic: `FFE9`
- Notify characteristic: `FFEA`

The Android app maps E10 to `T15Print`:

- `dpi = 8.0`
- `fMaxDotValue = 96`
- `mPerLineByte = 12`
- `printingProcess = 15`

Command frames start with `7e 5a`, command responses echo the command byte at
offset 7, and E-series bulk frames are sent as 512-byte frames split into four
128-byte BLE writes.
