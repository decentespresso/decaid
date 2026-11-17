# Auxiliary scale connections

Issue #833 originally proposed a dosing-specific second controller and
dosingScaleId. The maintainer decision chose one primary ScaleController for
all brewing and shot behavior, plus runtime-only auxiliary scale sessions.

Auxiliary sessions are explicitly selected through the generic device connect
operation and are addressed by opaque device ID for snapshots and tare. They
have no persisted role or purpose, and legacy singular scale routes remain
primary-only. Primary automatic selection excludes reserved auxiliary IDs;
closing and pending claims remain reserved until transport cleanup settles.

BengleVirtualScale remains primary. Bengle automatic policy still skips
external primary selection, while explicit external auxiliary discovery and
connection remain available. Auxiliary snapshots and tare never enter shot
sequencing or stop-at-weight.

The generic ID routes depend on the shared #858 opaque path-component helper.
