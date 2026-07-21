# Brother PT-N25BT Web Bluetooth Demo

This is a browser-only demo for printing simple 1bpp labels to a Brother
PT-N25BT over Web Bluetooth. It uses the same reverse-engineered BLE service,
framing, raster command stream, and PT-N25BT trailing padding as the macOS
CoreBluetooth tool.

## Run

Web Bluetooth requires a secure context. `localhost` is treated as secure, so
this is enough for local testing:

```sh
cd /path/to/ble-label-printers
python3 -m http.server 8000 --directory examples/web-bluetooth-ptn25bt
```

Open <http://localhost:8000> in Chrome or Edge on macOS.

## Use

1. Turn on the PT-N25BT and enable Bluetooth.
2. Open the demo page.
3. Click `Connect PT-N25BT` and choose the printer from the browser device
   picker.
4. Enter label text and click `Generate Preview`.
5. Verify the preview is readable and collision-free.
6. Click `Print Label`.

The preview intentionally omits the printer-specific trailing padding. The
generated PRN sent to the printer appends `13.4 mm` of blank raster columns to
balance the PT-N25BT mechanical leading margin.

## Browser Support

This targets Chromium Web Bluetooth implementations, especially Chrome/Edge on
macOS. Safari, Firefox, and normal iOS browsers do not expose the required Web
Bluetooth GATT APIs.

## Known Limitations

- The demo uses a conservative default write chunk size of `180` bytes because
  Web Bluetooth does not expose CoreBluetooth's maximum write length.
- Only simple uppercase bitmap text labels are generated.
- Browser permission prompts require direct user gestures; this cannot print
  silently in the background.
- If the printer sleeps, reconnect from the page after waking it.
