# PT-P320BT reference job

`hello.prn` is the 1903-byte raster payload extracted from a successful official
Brother P-touch Design&Print 2 print of the text `HELLO` on 12 mm tape.
`hello.png` reconstructs its 159 uncompressed 64-bit columns in horizontal label
orientation. The regression compares the generator against this captured job.

Only the print payload and decoded artwork are included. Neither file contains
Bluetooth identifiers or unrelated traffic from the original iPhone HCI trace.
