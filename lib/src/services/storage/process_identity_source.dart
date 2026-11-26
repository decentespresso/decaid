import 'dart:io';

/// Process-session identity derived only from kernel facts, or null when this
/// system exposes no such source.
///
/// This is the platform-independent part of `ProcessSessionIdentityResolver`,
/// kept free of Flutter imports so a separate process can resolve the same
/// value without an engine.
String? kernelProcessSessionIdentity(ProcessSessionProbe probe) {
  final startTicks = probe.readProcessStartTicks()?.trim();
  if (startTicks == null || !_digits.hasMatch(startTicks)) return null;
  final bootId = probe.readBootId()?.trim();
  final boot = bootId == null || bootId.isEmpty ? '-' : bootId;
  return 'proc:$boot:${probe.processId}:$startTicks';
}

final RegExp _digits = RegExp(r'^\d+$');

abstract interface class ProcessSessionProbe {
  String? readBootId();

  String? readProcessStartTicks();

  int get processId;
}

final class OsProcessSessionProbe implements ProcessSessionProbe {
  const OsProcessSessionProbe();

  @override
  String? readBootId() => _readFirstLine('/proc/sys/kernel/random/boot_id');

  @override
  String? readProcessStartTicks() {
    final stat = _readFirstLine('/proc/self/stat');
    return stat == null ? null : processStartTicksFromStat(stat);
  }

  @override
  int get processId => pid;

  static String? _readFirstLine(String path) {
    try {
      final lines = File(path).readAsLinesSync();
      return lines.isEmpty ? null : lines.first;
    } on FileSystemException {
      return null;
    }
  }
}

/// Field 22 (start time in clock ticks since boot) of a `/proc/<pid>/stat` line.
///
/// The command field can contain spaces and parentheses, so parsing starts after
/// the last `)`.
String? processStartTicksFromStat(String stat) {
  final commandEnd = stat.lastIndexOf(')');
  if (commandEnd < 0) return null;
  final fields = stat.substring(commandEnd + 1).trim().split(RegExp(r'\s+'));
  const startTimeFieldIndex = 19;
  if (fields.length <= startTimeFieldIndex) return null;
  final startTime = fields[startTimeFieldIndex];
  return RegExp(r'^\d+$').hasMatch(startTime) ? startTime : null;
}
