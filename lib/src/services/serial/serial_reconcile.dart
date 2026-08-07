import 'package:reaprime/src/models/device/device.dart';

class TrackedPortSnapshot {
  final String path;

  final bool isHdsSerial;

  final bool present;

  final ConnectionState state;

  const TrackedPortSnapshot({
    required this.path,
    required this.isHdsSerial,
    required this.present,
    required this.state,
  });
}

class SerialReconcilePlan {
  final bool livenessPass;

  final Set<String> release;

  final Set<String> reap;

  final Set<String> suppressAdd;

  final Set<String> suppressRemove;

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

Set<String> hdsResuppressionPaths({
  required Set<String> hdsPaths,
  required Set<String> presentPorts,
  required Set<String> trackedPaths,
}) => {
  for (final p in hdsPaths)
    if (presentPorts.contains(p) && !trackedPaths.contains(p)) p,
};

bool serialDevicesChanged(Set<String> currentIds, Set<String> lastEmittedIds) =>
    currentIds.length != lastEmittedIds.length ||
    !currentIds.containsAll(lastEmittedIds);

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
