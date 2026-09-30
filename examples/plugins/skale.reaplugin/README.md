# Skale JS Reference Driver

This opt-in example ports the Skale BLE weight protocol through the host-owned
GATT bridge. It matches the `ff08` service and keeps all protocol state inside
the `create()` result for the currently selected primary scale.

The driver accepts the native 4-byte fixed-point frame and the 5/9-byte signed
mantissa/exponent frames. It reports the first valid live weight only after the
display initialization sequence and exposes tare and timer commands with
explicit write-without-response operations, including display sleep/wake.
Battery reads use the standard
`180f/2a19` service when advertised and retain only valid 0..100 values.

The `device-settings` endpoint stores a default-off `usbPower` declaration per
public device identity in the host `kvStore` namespace. Enabling it clears and
suppresses battery reads; disabling it resumes reads and refreshes the value.
The endpoint validates the declaration before persistence and returns only
after the host store confirms the write.

The same endpoint serves a small settings page with persistence error
feedback. Physical button actions are staged separately with the held guarded
machine-action work; this runtime consumer does not issue machine-control requests.
The plugin page works independently; the native settings entry requires the
host #849 plugin-settings UI integration.

Changing between the native and plugin driver representations changes the
public device identity. Reselect the primary scale after that change; saved
native settings are not migrated automatically.

When the device advertises the standard device-information service, firmware is
read from `180a/2a26` and published with the session-scoped
`publishInfo({firmwareVersion, batteryLevel})` method.

No physical hardware validation is included in this checkpoint.
