# Device Notes

Hardware- and firmware-specific implementation notes live here. Keep
cross-device transport, discovery, controller, storage, testing, and API
architecture in the existing `doc/AI_*_NOTES.md` files.

- [DE1](de1.md): firmware behavior, serial protocol, profile synchronization,
  and machine-specific troubleshooting.
- [Bengle](bengle.md): MMR surface, integrated hardware, calibration, wake
  scheduling, and EBus tap.
- [Scales](scales.md): named scale protocols, readiness gates, and
  troubleshooting.
- [Sensors](sensors.md): named external sensor protocols and behavior.
- [Simulators](simulators.md): simulated-device modes and model behavior.

When adding guidance, put reusable architecture in the matching general note
and device-specific bytes, timings, firmware quirks, or field diagnostics here.
