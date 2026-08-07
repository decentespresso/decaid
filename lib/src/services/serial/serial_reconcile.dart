import 'package:reaprime/src/models/device/device.dart';

/// Pure reconcile-decision logic for [SerialServiceDesktop]. No libserialport,
/// no I/O — the service resolves port enumeration and per-device state into the
/// plain snapshots below, calls these functions, then applies the result.
///
/// This is where the anti-churn rules live (the ones that produced the macOS
/// double-instance and USB↔WiFi contention bugs), so they can be unit-tested
/// without a serial port. See `serial_service_desktop.dart` for how the live
/// I/O builds the inputs and applies the outputs.

/// One tracked port, resolved to the plain data the reconcile needs.
class TrackedPortSnapshot {
  /// Port path (the map key, e.g. `/dev/cu.usbmodem123` or `COM3`).
  final String path;

  /// Whether the device bound to this path is the USB Half Decent Scale.
  final bool isHdsSerial;

  /// Whether the OS still enumerates this port (false ⇒ physical unplug/rename).
  final bool present;

  /// The bound device's current connection state.
  final ConnectionState state;

  const TrackedPortSnapshot({
    required this.path,
    required this.isHdsSerial,
    required this.present,
    required this.state,
  });
}

/// The map mutations a pre-probe reconcile decides on. The service applies them
/// (disposing transports for released/reaped paths, updating the suppression and
/// HDS sets). [release] and [reap] are disjoint.
class SerialReconcilePlan {
  /// Whether this reconcile runs a liveness pass (re-verify discovered HDS).
  final bool livenessPass;

  /// Discovered (not-connected) HDS paths released so this pass re-probes them.
  final Set<String> release;

  /// Stale tracked paths to drop (port vanished, or device self-disconnected).
  final Set<String> reap;

  /// Paths to ADD to the self-disconnected suppression set.
  final Set<String> suppressAdd;

  /// Paths to REMOVE from the self-disconnected suppression set.
  final Set<String> suppressRemove;

  /// Paths to forget from the "ever an HDS" set (the port physically vanished).
  final Set<String> hdsForget;

  SerialReconcilePlan({
    required this.livenessPass,
    required this.release,
    required this.reap,
    required this.suppressAdd,
    required this.suppressRemove,
    required this.hdsForget,
  }) : assert(
         release.intersection(reap).isEmpty,
         'a released path must not also be reaped',
       ),
       assert(
         suppressAdd.intersection(suppressRemove).isEmpty,
         'suppressAdd and suppressRemove must be disjoint (add wins)',
       );
}

/// Decide the pre-probe reconcile transition.
///
/// Mirrors the sequencing of the live scan exactly:
/// 1. A liveness pass (explicit scan, or every Nth timer reconcile) releases
///    each tracked HDS that is neither connected NOR connecting — a discovered
///    HDS released its port and would otherwise linger as "available" after the
///    scale powers off — and lifts suppression on every known HDS path so they
///    get re-probed. (A connecting HDS is left alone: disposing its transport
///    mid-connect frees the native port the connect is using.)
/// 2. Reap any remaining tracked path whose port vanished OR whose device
///    self-disconnected: a vanished port also clears suppression + forgets the
///    HDS mark (a replug re-detects fresh); a still-present self-disconnect is
///    suppressed so the timer reconcile doesn't churn it (reap→re-probe→
///    reconnect). A still-present, connected device is kept.
///
/// `suppressAdd` wins over `suppressRemove` (a present self-disconnected HDS
/// reaped in a liveness pass ends up suppressed), matching the original
/// `removeAll(hdsPaths)`-then-per-reap-add ordering.
SerialReconcilePlan planSerialReconcile({
  required bool explicitScan,
  required int livenessTick,
  required int livenessEveryN,
  required List<TrackedPortSnapshot> tracked,
  required Set<String> hdsPaths,
}) {
  final livenessPass = explicitScan || (livenessTick % livenessEveryN == 0);

  final release = <String>{};
  if (livenessPass) {
    for (final t in tracked) {
      // Release a discovered HDS for re-probing, but NOT one that is connected
      // OR connecting — disposing the transport mid-connect frees the native
      // port the connect is using (a libserialport double-free abort).
      if (t.isHdsSerial &&
          t.state != ConnectionState.connected &&
          t.state != ConnectionState.connecting) {
        release.add(t.path);
      }
    }
  }

  final reap = <String>{};
  final suppressAdd = <String>{};
  final suppressRemove = <String>{};
  final hdsForget = <String>{};
  for (final t in tracked) {
    if (release.contains(t.path)) continue;
    final portGone = !t.present;
    final selfDisconnected = t.state == ConnectionState.disconnected;
    if (!portGone && !selfDisconnected) continue;
    reap.add(t.path);
    if (portGone) {
      suppressRemove.add(t.path);
      hdsForget.add(t.path);
    } else {
      suppressAdd.add(t.path);
    }
  }

  if (livenessPass) suppressRemove.addAll(hdsPaths);
  suppressRemove.removeAll(suppressAdd);

  return SerialReconcilePlan(
    livenessPass: livenessPass,
    release: release,
    reap: reap,
    suppressAdd: suppressAdd,
    suppressRemove: suppressRemove,
    hdsForget: hdsForget,
  );
}

/// After probing, HDS paths that are still plugged in but were NOT re-detected
/// are silent (the scale is off): suppress them so they aren't re-probed every
/// reconcile (the next liveness pass lifts this and re-probes, so they
/// auto-recover when the scale powers back on).
Set<String> hdsResuppressionPaths({
  required Set<String> hdsPaths,
  required Set<String> presentPorts,
  required Set<String> trackedPaths,
}) => {
  for (final p in hdsPaths)
    if (presentPorts.contains(p) && !trackedPaths.contains(p)) p,
};

/// Whether the tracked device set changed since the last emission — steady-state
/// timer reconciles with no change stay silent.
bool serialDevicesChanged(Set<String> currentIds, Set<String> lastEmittedIds) =>
    currentIds.length != lastEmittedIds.length ||
    !currentIds.containsAll(lastEmittedIds);

/// Whether an untracked port is a candidate worth probing, by its metadata
/// (the suppression/tracked/stable-id gates are applied by the caller, which
/// holds that state). Pure given the port's name/transport/productName.
bool serialPortMatchesCandidate({
  required String name,
  required String transport,
  String? productName,
}) {
  if (transport == 'Bluetooth') return false;
  if (productName == 'DE1' ||
      productName == 'Bengle' ||
      productName == 'Half Decent Scale') {
    return true;
  }
  if (name.contains('serial') ||
      name.contains('usbmodem') ||
      name.contains('ttyACM') ||
      name.contains('ttyUSB')) {
    return true;
  }
  if (transport == 'USB' && name.startsWith('COM')) return true;
  return false;
}
