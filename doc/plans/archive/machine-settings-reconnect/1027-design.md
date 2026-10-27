# Machine fan and refill overrides across reconnects (#1027)

Decaid persists API-written fan/refill overrides per physical machine and reapplies them after the connect handshake. Removing the connect writes was rejected: the refill-kit register is dual-purpose, and UnifiedDe1 must read detection before writing auto as the firmware handoff. The controller subsequently restores a refill override only when one is saved; otherwise the firmware handoff is the sole refill-kit write. Detection metadata remains unchanged.

The supervisor approved per-machine storage because one installation may control multiple machines. An app-global pair would copy one machine's preferences to another. A serial from the handshake is preferred, with device ID as fallback. Without either, the connection uses defaults and does not create a bucket. Identity changes do not migrate or merge buckets: a newly resolved identity receives its own stored values or defaults.

A local SharedPreferences JSON map holds at most 32 machines, evicting the oldest-updated entry. This is local persistence, not an extension of the separately allowlisted backup/sync format. There is no migration because these preferences did not previously exist.

Unset values retain the previous baseline: fan 55 (clamped to 50 by the DE1 register), refill auto. Explicit machine-settings reset restores the existing defaults and clears only the connected machine's saved entry. Workflow settings and profiles are unchanged. No new endpoint or physical-hardware operation is introduced.

Preference persistence remains inside the governed device-write operation: field writes and their captured-machine bookkeeping must stay ordered with later updates and reset. The trade-off is that local preference I/O holds the device-write slot.
