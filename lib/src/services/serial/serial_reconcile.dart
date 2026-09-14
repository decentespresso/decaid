import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/services/serial/utils.dart';

final _serialAliasPattern = RegExp(r'^(?:cu|tty)\.(.+)$');

class SerialPortMetadata {
  final String path;
  final String name;
  final String transport;
  final String? productName;
  final int? vid;
  final int? pid;
  final String? serial;
  final int? interfaceNumber;

  const SerialPortMetadata({
    required this.path,
    required this.name,
    required this.transport,
    this.productName,
    this.vid,
    this.pid,
    this.serial,
    this.interfaceNumber,
  });

  String get canonicalId =>
      computeUsbStableId(
        vid: vid,
        pid: pid,
        serial: serial,
        interfaceNumber: interfaceNumber,
      ) ??
      'serial-${path.split('/').last}';

  Set<String> get acceptedIds => {canonicalId, ...desktopSerialLegacyIds(path)};
}

Set<String> desktopSerialLegacyIds(String portPath) {
  final basename = portPath.split('/').last;
  final match = _serialAliasPattern.firstMatch(basename);
  if (match == null) return {'serial-$basename'};
  final suffix = match.group(1)!;
  return {'serial-cu.$suffix', 'serial-tty.$suffix'};
}

List<SerialPortMetadata> dedupeSerialCandidates(
  List<SerialPortMetadata> candidates,
) {
  final result = <SerialPortMetadata>[];
  final indexes = <String, int>{};
  for (final candidate in candidates) {
    final basename = candidate.path.split('/').last;
    final stableId = computeUsbStableId(
      vid: candidate.vid,
      pid: candidate.pid,
      serial: candidate.serial,
      interfaceNumber: candidate.interfaceNumber,
    );
    final aliasMatch = _serialAliasPattern.firstMatch(basename);
    final key =
        stableId ??
        (aliasMatch == null
            ? 'path:${candidate.canonicalId}'
            : 'alias:${aliasMatch.group(1)}');
    final existingIndex = indexes[key];
    if (existingIndex == null) {
      indexes[key] = result.length;
      result.add(candidate);
      continue;
    }
    final existingBasename = result[existingIndex].path.split('/').last;
    if (basename.startsWith('cu.') && existingBasename.startsWith('tty.')) {
      result[existingIndex] = candidate;
    }
  }
  return result;
}

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
