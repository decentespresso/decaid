import 'dart:io';

import 'package:reaprime/src/services/storage/process_identity_source.dart';

void main() {
  final identity = kernelProcessSessionIdentity(const OsProcessSessionProbe());
  stdout.writeln(identity == null ? 'kernel=none' : 'kernel=$identity');
}
