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
    final restProperties = schemas['GrinderSnapshot']['properties'] as YamlMap;
    final wsProperties =
        websocketSchemas['GrinderSnapshot']['properties'] as YamlMap;
    for (final properties in [restProperties, wsProperties]) {
      expect(properties['observedSetting']['type'], 'string');
      expect(properties['observedRpm']['type'], 'integer');
      expect(properties['observedRpm']['minimum'], 0);
      expect(properties['setting']['type'], 'string');
      expect(properties['rpm']['type'], 'integer');
    }
    expect(restProperties['observedSetting'], wsProperties['observedSetting']);
    expect(restProperties['observedRpm'], wsProperties['observedRpm']);
    final info = schemas['GrinderInfo']['properties'] as YamlMap;
    expect(info['observations']['items']['enum'], ['setting', 'rpm']);
    expect(info['controls']['properties'].keys, ['grindSetting', 'rpmControl']);
    final driver =
        schemas['PluginManifest']['properties']['drivers']['items']['properties']
            as YamlMap;
    expect(driver['observations']['items']['enum'], ['setting', 'rpm']);
    expect(driver['observations']['uniqueItems'], true);
  });
}
