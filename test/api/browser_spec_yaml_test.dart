import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void _checkFlowSequenceIndentation(YamlNode node) {
  if (node is YamlMap) {
    for (final entry in node.nodes.entries) {
      final value = entry.value;
      if (value is YamlList &&
          value.style == CollectionStyle.FLOW &&
          value.span.start.line != value.span.end.line) {
        expect(
          value.span.end.column - 1,
          greaterThan(entry.key.span.start.column),
          reason:
              'Browser YAML parsing requires the multiline flow sequence for '
              '${entry.key.value} at line ${value.span.start.line + 1} '
              'to close past the key indentation',
        );
      }
      _checkFlowSequenceIndentation(value);
    }
  } else if (node is YamlList) {
    for (final item in node.nodes) {
      _checkFlowSequenceIndentation(item);
    }
  }
}

void main() {
  for (final spec in ['rest_v1.yml', 'websocket_v1.yml']) {
    test('$spec multiline flow sequences retain browser-safe indentation', () {
      final document = loadYamlNode(
        File('assets/api/$spec').readAsStringSync(),
      );
      _checkFlowSequenceIndentation(document);
    });
  }
}
