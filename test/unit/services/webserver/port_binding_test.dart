import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver/port_binding.dart';
import 'package:shelf/shelf.dart';

void main() {
  group('isAddressInUse', () {
    test('accepts the EADDRINUSE code of every supported platform', () {
      for (final code in addressInUseErrorCodes) {
        expect(
          isAddressInUse(
            SocketException('bind failed', osError: OSError('in use', code)),
          ),
          isTrue,
          reason: 'code $code should be recognised',
        );
      }
    });

    test('rejects a different socket failure', () {
      expect(
        isAddressInUse(
          SocketException('bind failed', osError: OSError('denied', 13)),
        ),
        isFalse,
      );
    });

    test('accepts Dart\'s same-process double-bind message', () {
      expect(
        isAddressInUse(
          SocketException(
            'bind failed',
            osError: const OSError(
              'The shared flag to bind() needs to be `true` if binding '
              'multiple times on the same (address, port) combination.',
            ),
          ),
        ),
        isTrue,
      );
    });

    test('rejects a SocketException with no OS error', () {
      expect(isAddressInUse(const SocketException('no osError')), isFalse);
    });

    test('rejects a non-socket error', () {
      expect(isAddressInUse(StateError('unrelated')), isFalse);
    });
  });

  group('serveOrReportPortInUse', () {
    test('serves on a free port', () async {
      final server = await serveOrReportPortInUse(
        (_) => Response.ok('ok'),
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => server.close(force: true));
      expect(server.port, greaterThan(0));
    });

    test('reports the port when it is already bound', () async {
      // Hold a real port, the way the other Decaid app would.
      final holder = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => holder.close());

      await expectLater(
        serveOrReportPortInUse(
          (_) => Response.ok('ok'),
          InternetAddress.loopbackIPv4,
          holder.port,
        ),
        throwsA(
          isA<WebServerPortInUse>().having((e) => e.port, 'port', holder.port),
        ),
      );
    });
  });

  group('probePortIsFree', () {
    test('is false while something holds the port', () async {
      final holder = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(() => holder.close());
      expect(await probePortIsFree(holder.port), isFalse);
    });

    test('is true once nothing holds it', () async {
      final holder = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final port = holder.port;
      await holder.close();
      expect(await probePortIsFree(port), isTrue);
    });
  });
}
