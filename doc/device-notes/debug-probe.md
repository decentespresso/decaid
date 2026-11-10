# Raspberry Pi Debug Probe on Android

USB identity of the stock probe (verified against
[`raspberrypi/debugprobe`](https://github.com/raspberrypi/debugprobe) `src/usb_descriptors.c`):

| Property | Value |
|---|---|
| VID:PID | `0x2e8a:0x000c` (CMSIS-DAP Debug Probe) |
| Product string | `Debug Probe (CMSIS-DAP)` |
| Interfaces | 4: `0` = CMSIS-DAP probe (HID or vendor bulk), `1` = CDC COMM, `2` = CDC DATA, `3` = reset |

The product string is what the Android name gate admits; `0x000a` is the RP2040 bootrom,
not the probe, so a fixture that claims `000a` describes different hardware.

## CDC interface selection

Android opens the primary endpoint with `device.create(UsbSerial.CDC)` and no explicit
interface (`-1`). The pinned fork `AurelienBallier/UsbSerial:6.1.1` then picks the pair
itself: `CDCSerialDevice` resolves the control interface with `findFirstControl` (first
`USB_CLASS_COMM` interface) and the data interface with `findFirstCDC` (first
`USB_CLASS_CDC_DATA` interface). On the probe that is interface 1 and 2, so automatic
detection is correct and no explicit interface policy is needed.

Do not pass an explicit interface for the primary endpoint. Only a separately managed
auxiliary endpoint on a composite device needs one, because its interface is a vendor
endpoint rather than a CDC pair.

## Test fidelity

`test/services/serial/debug_probe_android_test.dart` uses the real VID/PID, product string and
`interfaceCount = 4`, and asserts that `create` is called with `type: 'cdc'` and
`interface: -1`. Dart-side fixtures cannot model USB interface classes, so the pair selection
itself is covered by the driver semantics above, not by the mock.

Real-hardware validation is still required before claiming functional discovery: enumeration,
460800 configuration, `R ...` telemetry, sensor registration, and rejection of a silent probe
without DE1 writes. Track results on #1105.
