# Native serial regression tests (Linux)

Build the Linux release bundle once, then run each test file with its own loopback:

```sh
flutter build linux --release
python3 tool/serial_test/run_pty.py flutter test --no-pub test/services/serial/serial_port_reader_test.dart
```

Use the SDK and native prerequisites from the repository README. The helper also
needs Python 3 and a C compiler (`CC`, default `cc`). It locates the resolved
`flutter_libserialport` source through `.dart_tool/package_config.json` and links
the native library from `build/linux/x64/release/bundle/lib`.

The fixture creates two private PTYs and forwards bytes between them. The small
adapter permits libserialport to open/configure PTYs, which lack the USB metadata
and modem ioctls expected by the normal port discovery code. Reads, writes, queue
inspection, flush and close still use the real bundled libserialport library.
The adapter uses that library's private port layout, so build it against the same
resolved source as the bundle. No physical serial port is opened by this helper.

Run one test file per invocation: concurrent files must not share a byte stream.
Without the helper, these tests skip unless `SERIAL_TEST_RX` and `SERIAL_TEST_TX`
name an exclusively owned loopback pair and the native library is available.
Never point them at a machine or another live peripheral: they send test bytes.

The reader regression starts with a 255-byte warmup, leaves the line quiet, then
requires each short reply within 200 ms without supplying more bytes. The old
full-count read fails this check. A 4096-byte burst checks ordering and chunk
bounds. Reported timing is an integration measurement, not a hard realtime
scheduling guarantee. PTYs cannot reproduce every USB driver shutdown behavior;
physical-device verification is separate.
