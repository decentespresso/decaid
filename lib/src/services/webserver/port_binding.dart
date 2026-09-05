import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;

typedef PortProbe = Future<bool> Function(int port);

class WebServerPortInUse implements Exception {
  const WebServerPortInUse(this.port);

  final int port;

  @override
  String toString() => 'WebServerPortInUse(port: $port)';
}

const Set<int> addressInUseErrorCodes = {98, 48, 10048};

const String sameProcessBindClashMessage = 'shared flag';

bool isAddressInUse(Object error) {
  if (error is! SocketException) return false;
  final osError = error.osError;
  if (osError == null) return false;
  return addressInUseErrorCodes.contains(osError.errorCode) ||
      osError.message.contains(sameProcessBindClashMessage);
}

Future<HttpServer> serveOrReportPortInUse(
  Handler handler,
  Object address,
  int port,
) async {
  try {
    return await io.serve(handler, address, port);
  } catch (e) {
    if (isAddressInUse(e)) {
      throw WebServerPortInUse(port);
    }
    rethrow;
  }
}

Future<bool> probePortIsFree(int port) async {
  try {
    final probe = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    await probe.close();
    return true;
  } catch (_) {
    return false;
  }
}
