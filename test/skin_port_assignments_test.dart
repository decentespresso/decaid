import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/main.dart' as app;

void main() {
  test('decodes a stored assignment map', () {
    final raw = jsonEncode({'skin:decal': 25123, 'skin:path:abc': 24801});

    expect(app.decodeSkinPortAssignments(raw), {
      'skin:decal': 25123,
      'skin:path:abc': 24801,
    });
  });

  test('returns an empty map for null or empty storage', () {
    expect(app.decodeSkinPortAssignments(null), isEmpty);
    expect(app.decodeSkinPortAssignments(''), isEmpty);
  });

  test('returns an empty map for garbage JSON', () {
    expect(app.decodeSkinPortAssignments('{not json'), isEmpty);
    expect(app.decodeSkinPortAssignments('\u0000\u0001'), isEmpty);
  });

  test('returns an empty map for JSON that is not a map', () {
    expect(app.decodeSkinPortAssignments('[25123]'), isEmpty);
    expect(app.decodeSkinPortAssignments('"skin:decal"'), isEmpty);
  });

  test('drops entries whose value is not an integer', () {
    final raw = jsonEncode({
      'skin:decal': 25123,
      'skin:bad': 'high',
      'skin:worse': 25123.5,
      'skin:null': null,
    });

    expect(app.decodeSkinPortAssignments(raw), {'skin:decal': 25123});
  });
}
