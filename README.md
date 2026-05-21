# Brother PT-N25BT BLE Label Printer Tools

macOS tooling and a Codex skill for printing to the Brother PT-N25BT Bluetooth
Low Energy label printer.

This is reverse-engineered, unofficial software. It currently targets 12 mm tape
on the PT-N25BT.

## What Works

- Discover and connect to the PT-N25BT over BLE from macOS.
- Read printer status.
- Generate Brother raster PRN files from text or built-in 1bpp calibration
  patterns.
- Print PRN files through a signed CoreBluetooth app bundle.

## Requirements

- macOS with Bluetooth enabled.
- Xcode command line tools for `swiftc` and `codesign`.
- Python 3 with Pillow.

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

## Build

```sh
./scripts/build-ptn25bt.sh
```

The build creates `.build/PTN25BT.app`. Use the app bundle through `open` rather
than invoking the raw binary directly so macOS Bluetooth permissions attach to
the signed app.

Optional BLE scanner:

```sh
./scripts/build-ble-scan.sh
```

## Print A Label

Generate a 1bpp preview and PRN:

```sh
. .venv/bin/activate
python tools/ptn25bt/generate_prn.py work/hello.prn \
  --text "HELLO" \
  --length-px 320 \
  --preview-png work/hello.png
```

Review `work/hello.png`, then print:

```sh
open -Wn .build/PTN25BT.app \
  --stdout work/print.out \
  --stderr work/print.err \
  --args --name PT-N25BT --scan-seconds 60 send-file "$PWD/work/hello.prn"

cat work/print.out
cat work/print.err
```

Successful BLE transfers include `ackRaw=06f001`.

## Calibration Patterns

```sh
python tools/ptn25bt/generate_prn.py work/border.prn \
  --calibration border \
  --length-px 220 \
  --border-px 2 \
  --preview-png work/border.png

python tools/ptn25bt/generate_prn.py work/margin.prn \
  --calibration margin-test \
  --text "TEST" \
  --length-px 220 \
  --border-px 2 \
  --preview-png work/margin.png

python tools/ptn25bt/generate_prn.py work/showoff.prn \
  --calibration showoff \
  --length-px 560 \
  --preview-png work/showoff.png
```

Previews are true 1bpp PNGs and intentionally omit printer-specific trailing
padding. The generated PRN defaults to:

- Brother feed/margin command `ESC i d = 0`.
- `13.4 mm` of blank raster columns appended after the artwork.

This gives visually centered labels while avoiding Brother's feed/margin
behavior, which also changes cutter/head positioning. Override with
`--trailing-pad-mm 0` for raw geometry tests.

## Status

```sh
open -Wn .build/PTN25BT.app \
  --stdout work/status.out \
  --stderr work/status.err \
  --args --name PT-N25BT --scan-seconds 60 status

cat work/status.out
cat work/status.err
```

Expected idle status on the tested printer includes series `0x41`, model
`0x30`, `errors=0x0000`, and `width=12mm`.

## Codex Skill

This repository is also a Codex skill. The root [SKILL.md](SKILL.md) contains
the operational workflow for agents that need to generate or print labels.

## Reverse-Engineered Notes

PT-N25BT BLE service and characteristics:

- Service: `A76EB9E0-F3AC-4990-84CF-3A94D2426B2B`
- Read/status: `A76EB9E1-F3AC-4990-84CF-3A94D2426B2B`
- Write-with-response: `A76EB9E2-F3AC-4990-84CF-3A94D2426B2B`
- Write-without-response and ACK notify:
  `A76EB9E3-F3AC-4990-84CF-3A94D2426B2B`
- Printer status notify: `A76EB9E4-F3AC-4990-84CF-3A94D2426B2B`

BLE write-without-response payloads are sent as framed segments:

```text
06 f0 <packet_count> 00 <payload>
```

The printer acknowledges successful segments with:

```text
06 f0 01
```

The known-good raster stream uses uncompressed Brother raster data, 16-byte
transfer lines, and a 64-dot printable image in the first 8 bytes of each line.
TIFF/PackBits compression remains experimental on this model.
