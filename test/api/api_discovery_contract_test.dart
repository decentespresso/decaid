import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:yaml/yaml.dart';

void main() {
  final spec =
      loadYaml(File('assets/api/rest_v1.yml').readAsStringSync()) as YamlMap;
  final html = File('assets/api/index.html').readAsStringSync();
  final manifestPath = apiDocsConfiguration.manifestPath;
  final openApiPath = apiDocsConfiguration.openApiPath;
  final asyncApiPath = apiDocsConfiguration.asyncApiPath;

  test('manifest paths match bundled docs assets and viewer references', () {
    expect(manifestPath, '/api/v1/manifest');
    expect(apiDocsConfiguration.port, 4001);
    expect(apiDocsConfiguration.viewerPath, '/');
    expect(apiDocsConfiguration.assetPaths, [
      'assets/api/index.html',
      'assets/api$openApiPath',
      'assets/api$asyncApiPath',
    ]);
    expect(
      apiDocsConfiguration.assetPaths.map(
        (assetPath) => File(assetPath).existsSync(),
      ),
      everyElement(isTrue),
    );
    expect(html, contains("url: '${openApiPath.substring(1)}'"));
    expect(html, contains("const specUrl = '${asyncApiPath.substring(1)}'"));
  });

  test('OpenAPI documents the exact discovery response', () {
    final operation =
        (spec['paths'] as YamlMap)[manifestPath]['get'] as YamlMap;
    final response = (operation['responses'] as YamlMap)['200'] as YamlMap;
    final schema =
        ((response['content'] as YamlMap)['application/json']
                as YamlMap)['schema']
            as YamlMap;

    expect(operation['description'], contains('same host'));
    expect(schema.keys.toSet(), {'type', 'required', 'properties'});
    expect(schema['type'], 'object');
    expect((schema['required'] as YamlList).toSet(), {'api', 'docs'});
    final properties = schema['properties'] as YamlMap;
    expect(properties.keys.toSet(), {'api', 'docs'});
    expect((properties['api'] as YamlMap).keys.toSet(), {'type', 'example'});
    expect(properties['api']['type'], 'string');
    expect(properties['api']['example'], 'v1');
    final docs = properties['docs'] as YamlMap;
    expect(docs.keys.toSet(), {'type', 'required', 'properties'});
    expect(docs['type'], 'object');
    expect((docs['required'] as YamlList).toSet(), {
      'port',
      'viewer',
      'openapi',
      'asyncapi',
    });
    final docsProperties = docs['properties'] as YamlMap;
    expect(docsProperties.keys.toSet(), {
      'port',
      'viewer',
      'openapi',
      'asyncapi',
    });
    for (final entry in docsProperties.entries) {
      final property = entry.value as YamlMap;
      expect(property.keys.toSet(), {'type', 'example'});
      expect(property['type'], entry.key == 'port' ? 'integer' : 'string');
    }
    expect(docsProperties['port']['type'], 'integer');
    expect(docsProperties['port']['example'], 4001);
    expect(docsProperties['viewer']['example'], '/');
    expect(docsProperties['openapi']['example'], openApiPath);
    expect(docsProperties['asyncapi']['example'], asyncApiPath);
  });
}
