import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('REST and WebSocket specs expose connected Grinder contracts', () {
    final rest =
        loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;
    final paths = rest['paths'] as YamlMap;
    for (final path in [
      '/api/v1/grinder/info',
      '/api/v1/grinder/state',
      '/api/v1/grinder/state/grinding',
      '/api/v1/grinder/state/idle',
      '/api/v1/grinder/setting',
      '/api/v1/grinder/rpm',
    ]) {
      expect(paths, contains(path));
    }
    final schemas = (rest['components'] as YamlMap)['schemas'] as YamlMap;
    expect(schemas, contains('GrinderInfo'));
    expect(schemas, contains('GrinderSnapshot'));
    expect(
      (schemas['ReaSettings'] as YamlMap)['properties'],
      contains('preferredGrinderDeviceId'),
    );

    final websocket =
        loadYaml(File('assets/api/websocket_v1.yml').readAsStringSync())
            as YamlMap;
    final channels = websocket['channels'] as YamlMap;
    expect(
      (channels['GrinderSnapshot'] as YamlMap)['address'],
      'ws/v1/grinder/snapshot',
    );
    final websocketSchemas =
        (websocket['components'] as YamlMap)['schemas'] as YamlMap;
    expect(websocketSchemas, contains('GrinderSnapshot'));
  });
}
