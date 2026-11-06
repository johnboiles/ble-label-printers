# PT-P320BT: observed 12 mm protocol

Derived from an iPhone PacketLogger capture of Brother P-touch Design&Print 2
printing `HELLO`, followed by direct macOS BLE experiments on the same printer.

## Transport

The service and e1/e2/e3/e4 UUIDs match PT-N25BT exactly (see the root README).
Subscribe to e3 and e4, then write `00` to e2 with response. Send raster/status
commands through e3 without response. A segment begins with
`06 f0 <number-of-writes> 00`; continuation writes contain raw payload, without
repeating that header. Wait for e3 ACK `06 f0 01` after each complete segment.
Both the app capture and Mac observed a 247-byte write-value limit; use the
negotiated CoreBluetooth limit instead of assuming that value on other hosts.
The existing Swift client already implements this transport.

## Job format

| Bytes | Observed use |
| --- | --- |
| 100 zero bytes | Invalidate/padding |
| `1b 69 61 01` | Raster mode |
| `1b 40` | Initialize |
| `1b 69 7a c4 01 0c 00 <u32le columns> 02 00` | Media and column count |
| `1b 69 4b 08` | Advanced mode |
| `1b 69 4d 40` | Mode flags, preserved from app |
| `1b 69 6b 63 01 00` | Model-specific setting, not interpreted |
| `1b 69 64 1c 00` | 28-dot feed margin |
| `4d 00` | No compression |
| `1b 69 4c 00 01 01` | Model-specific setting, not interpreted |
| `1b 69 43 01 ff ff ff` | Model-specific setting, not interpreted |
| `47 08 00 <8 bytes>` repeated | 64-bit vertical columns |
| `1a` | Print/feed |

The app also sends 400 zero bytes + initialize and status requests before its
job. A separate Bleak prototype used that sequence for a custom 360 x 64 label
and received a print-completed status. The generator preserves the app's job
header, not the PT-N25BT header or its calibration padding.

## Status

Request `1b 69 53`. e4 returns 32 bytes beginning `80 20 42 30 83 30`.
Offsets (zero-based): error bytes 8/9, tape width 10, media type 11, status
type 18, phase type 19. With 12 mm laminated tape: width `0c`, media `01`.
Printing transitions observed: status/phase `06/01`, `01/01` (completed),
`06/00` (editing). No errors were reported during the custom label print.

## Validation

- Official-app 159-column `HELLO` payload: exact generator regression fixture.
- Custom 360 x 64 cat-in-UFO artwork: 4114-byte job, three ACKed BLE segments,
  status type `01` received from actual hardware using a Bleak prototype.
- Existing signed Swift app: status query verified against actual P320BT.
- End-to-end repository path: generated `PR READY` (240 x 64, 2794 bytes)
  with this generator and sent it through the unchanged signed `PTN25BT.app`
  using `--name PT-P320BT`. Both transport segments were ACKed, then e4
  reported `06/01`, `01/01`, `06/00`, with error bytes zero. This worked
  without the prototype's separate 400-byte initialization preamble.
- Automated tests cover bit order, column order, polarity, transparency,
  geometry bounds and the captured job. Physical appearance is distinct from
  the printer's protocol completion status.
