import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

PluginDriverDeclaration driver(String id, Map<String, dynamic> match) =>
    PluginDriverDeclaration.fromJson({
      'id': id,
      'type': 'sensor',
      'ble': {'match': match},
    });

void main() {
  test(
    'an empty system service list does not prove a negative advertisement',
    () {
      final registry = PluginBleRegistry();
      registry.register(
        pluginId: 'a',
        generation: 1,
        declaration: driver('one', {
          'serviceUuids': ['0ffe'],
        }),
        permissions: {PluginPermissions.transportBle},
        factoryHandle: 'a',
      );
      expect(
        registry
            .decide(
              BleAdvertisementEvidence(
                source: BleEvidenceSource.system,
                serviceUuids: [],
              ),
            )
            .kind,
        PluginBleOwnership.pending,
      );
    },
  );

  test('a declaration without a permitted runtime factory is ineligible', () {
    final registry = PluginBleRegistry();
    final declaration = driver('one', {
      'name': {'exact': 'bookoo'},
    });
    expect(
      () => registry.register(
        pluginId: 'a',
        generation: 1,
        declaration: declaration,
        permissions: {},
        factoryHandle: 'factory',
      ),
      throwsStateError,
    );
    expect(
      registry.decide(BleAdvertisementEvidence(name: 'bookoo')).kind,
      PluginBleOwnership.native,
    );
  });

  test('definite match cannot defeat an indeterminate competitor', () {
    final registry = PluginBleRegistry();
    registry.register(
      pluginId: 'a',
      generation: 1,
      declaration: driver('one', {
        'name': {'exact': 'bookoo'},
      }),
      permissions: {PluginPermissions.transportBle},
      factoryHandle: 'a',
    );
    registry.register(
      pluginId: 'b',
      generation: 2,
      declaration: driver('two', {
        'serviceUuids': ['0ffe'],
      }),
      permissions: {PluginPermissions.transportBle},
      factoryHandle: 'b',
    );
    expect(
      registry.decide(BleAdvertisementEvidence(name: 'bookoo')).kind,
      PluginBleOwnership.pending,
    );
    final conflict = registry.decide(
      BleAdvertisementEvidence(name: 'bookoo', serviceUuids: ['0ffe']),
    );
    expect(conflict.kind, PluginBleOwnership.conflict);
    expect(conflict.drivers.map((driver) => driver.pluginId), ['a', 'b']);
    final owned = registry.decide(
      BleAdvertisementEvidence(name: 'bookoo', serviceUuids: []),
    );
    expect(owned.kind, PluginBleOwnership.plugin);
    expect(owned.drivers.single.pluginId, 'a');
    registry.removeGeneration('a', 1);
    expect(
      registry
          .decide(BleAdvertisementEvidence(name: 'bookoo', serviceUuids: []))
          .kind,
      PluginBleOwnership.native,
    );
  });

  test(
    'complete advertisement supersedes incomplete system metadata in either order',
    () {
      final advertisement = BleAdvertisementEvidence(
        name: 'bookoo',
        serviceUuids: ['0ffe'],
        observedAt: DateTime.utc(2026, 9, 7),
      );
      final system = BleAdvertisementEvidence(
        name: 'bookoo',
        source: BleEvidenceSource.system,
        observedAt: DateTime.utc(2026, 9, 7, 0, 0, 1),
      );
      for (final observations in [
        [system, advertisement],
        [advertisement, system],
      ]) {
        final cache = BleAdvertisementCache();
        cache.beginGeneration(1);
        for (final observation in observations) {
          cache.record('AB:CD', 1, observation);
        }
        expect(cache.get('ab:cd')!.serviceUuids, ['0ffe']);
        expect(cache.get('ab:cd')!.source, BleEvidenceSource.advertisement);
        cache.beginGeneration(2);
        expect(cache.get('ab:cd'), isNull);
        cache.record('AB:CD', 1, advertisement);
        expect(cache.get('ab:cd'), isNull);
      }
    },
  );

  test('observations are not combined into a fabricated match', () {
    final cache = BleAdvertisementCache()..beginGeneration(1);
    cache.record('one', 1, BleAdvertisementEvidence(name: 'bookoo'));
    cache.record('one', 1, BleAdvertisementEvidence(serviceUuids: ['0ffe']));
    expect(cache.get('one')!.name, isNull);
  });

  test(
    'stale factory and physical claims cannot pass connection admission',
    () {
      final registry = PluginBleRegistry(activeBindingLimit: 2);
      final entry = registry.register(
        pluginId: 'a',
        generation: 1,
        declaration: driver('one', {
          'name': {'exact': 'bookoo'},
        }),
        permissions: {PluginPermissions.transportBle},
        factoryHandle: 'a',
      );
      final first = registry.reserve(entry, 'AB:CD');
      expect(first.publicId, 'plugin:a:one:ab:cd');
      expect(() => registry.reserve(entry, 'ab:cd'), throwsStateError);
      final second = registry.reserve(entry, 'other');
      expect(() => registry.reserve(entry, 'third'), throwsStateError);
      registry.removeGeneration('a', 1);
      expect(() => registry.reserve(entry, 'third'), throwsStateError);
      expect(registry.activeBindingCount, 2);
      registry.release(first);
      registry.release(first);
      expect(registry.activeBindingCount, 1);
      registry.release(second);
      expect(registry.activeBindingCount, 0);
    },
  );
}
