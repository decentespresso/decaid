# Felicita Arc Reference Driver

Opt-in example for #809, beside the Bookoo reference plugin. It is not bundled
or enabled automatically; load it through the plugin source-development path.

The driver matches a case-insensitive `Felicita` name prefix. It verifies the
shared FFE0 service after connection, subscribes to FFE1, and uses acknowledged
writes to FFE1. A valid notification is exactly 18 bytes: the sign is byte 2,
bytes 3–8 are six ASCII weight digits in hundredths of a gram, and byte 15 is
the battery encoding. Raw battery values 129–158 map to 0–100; other values
retain the last valid battery value, with unknown initially represented as
null. Invalid frames are ignored.

Commands are one-byte acknowledged writes: tare `54`, timer start `52`, stop
`53`, and reset `43` (hex). Readiness waits for the first valid accepted weight;
connection and protocol failure remain host-owned. Display sleep deliberately
disconnects, and wake/reconnect remains host policy. The two-second valid-packet
silence watchdog is provisional and requires hardware cadence measurements.

No Felicita hardware verification is included in this example checkpoint.
