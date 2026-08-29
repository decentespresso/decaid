import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('personal flavor prevents native Firebase initialization and collection',
      () {
    final manifest = File(
      'android/app/src/personal/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('com.google.firebase.provider.FirebaseInitProvider'));
    expect(manifest, contains('tools:node="remove"'));
    expect(manifest, contains('firebase_analytics_collection_deactivated'));
    expect(manifest, contains('firebase_crashlytics_collection_enabled'));
    expect(manifest, contains('firebase_performance_collection_deactivated'));
  });
}
