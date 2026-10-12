part of 'de1app_importer.dart';

typedef _BeanIdentity = (String, String);
typedef _BatchIdentity = (_BeanIdentity, DateTime?);

class _ImportedShotEntities {
  final BeanStorageService beanStorage;
  final GrinderStorageService grinderStorage;
  var beansCreated = 0;
  var beansSkipped = 0;
  var grindersCreated = 0;
  var grindersSkipped = 0;

  _ImportedShotEntities(this.beanStorage, this.grinderStorage);

  Future<List<ShotRecord>> reconcile(
    List<ParsedShot> shots,
    List<Grinder> dyeGrinders, {
    required List<ImportError> errors,
    void Function(ImportProgress)? onProgress,
  }) async {
    final beans = <_BeanIdentity, Bean>{};
    final batches = <_BatchIdentity, ParsedShot>{};
    final grinders = <String, Grinder>{};

    for (final parsed in shots) {
      final beanKey = _beanIdentity(parsed.beanBrand, parsed.beanType);
      if (beanKey != null) {
        beans.putIfAbsent(
          beanKey,
          () => Bean.create(
            roaster: parsed.beanBrand!,
            name: parsed.beanType!,
            notes: parsed.beanNotes,
          ),
        );
        batches.putIfAbsent(
          _batchIdentity(beanKey, _parseRoastDate(parsed.roastDate)),
          () => parsed,
        );
      }
      final model = _normalize(parsed.grinderModel);
      if (model != null) {
        grinders.putIfAbsent(
          model,
          () => Grinder.create(model: parsed.grinderModel!),
        );
      }
    }

    for (final dye in dyeGrinders) {
      final key = _normalize(dye.model);
      if (key == null) continue;
      final fromShot = grinders[key];
      grinders[key] = fromShot == null
          ? dye
          : fromShot.copyWith(
              burrs: dye.burrs,
              settingType: dye.settingType,
              settingValues: dye.settingValues,
              settingSmallStep: dye.settingSmallStep,
              settingBigStep: dye.settingBigStep,
            );
    }

    final storedBeans = <_BeanIdentity, String>{};
    final storedBatches = <_BatchIdentity, String>{};
    for (final bean in await beanStorage.getAllBeans()) {
      final key = _beanIdentity(bean.roaster, bean.name);
      if (key == null) continue;
      storedBeans[key] = bean.id;
      for (final batch in await beanStorage.getBatchesForBean(bean.id)) {
        storedBatches[_batchIdentity(key, batch.roastDate)] = batch.id;
      }
    }
    final storedGrinders = <String, String>{};
    for (final grinder in await grinderStorage.getAllGrinders()) {
      final key = _normalize(grinder.model);
      if (key != null) storedGrinders[key] = grinder.id;
    }

    final entityTotal = beans.length + grinders.length;
    var entityIndex = 0;
    void reportProgress() {
      entityIndex++;
      onProgress?.call(
        ImportProgress(
          current: entityIndex,
          total: entityTotal,
          phase: 'entities',
          beansCreated: beansCreated,
          grindersCreated: grindersCreated,
        ),
      );
    }

    for (final entry in beans.entries) {
      final bean = entry.value;
      if (storedBeans.containsKey(entry.key)) {
        beansSkipped++;
      } else {
        try {
          await beanStorage.insertBean(bean);
          storedBeans[entry.key] = bean.id;
          beansCreated++;
        } catch (e, st) {
          _recordFailure(
            errors,
            'Bean',
            '${bean.roaster} / ${bean.name}',
            e,
            st,
          );
        }
      }
      reportProgress();
    }

    for (final entry in batches.entries) {
      if (storedBatches.containsKey(entry.key)) continue;
      final beanId = storedBeans[entry.key.$1];
      if (beanId == null) continue;
      final parsed = entry.value;
      final batch = BeanBatch.create(
        beanId: beanId,
        roastDate: _parseRoastDate(parsed.roastDate),
        roastLevel: parsed.roastLevel,
      );
      try {
        await beanStorage.insertBatch(batch);
        storedBatches[entry.key] = batch.id;
      } catch (e, st) {
        _recordFailure(
          errors,
          'BeanBatch',
          '${parsed.beanBrand} / ${parsed.beanType} / ${parsed.roastDate ?? "unknown roast date"}',
          e,
          st,
        );
      }
    }

    for (final entry in grinders.entries) {
      final grinder = entry.value;
      if (storedGrinders.containsKey(entry.key)) {
        grindersSkipped++;
      } else {
        try {
          await grinderStorage.insertGrinder(grinder);
          storedGrinders[entry.key] = grinder.id;
          grindersCreated++;
        } catch (e, st) {
          _recordFailure(errors, 'Grinder', grinder.model, e, st);
        }
      }
      reportProgress();
    }

    return [
      for (final parsed in shots)
        _linkShot(
          parsed.shot,
          storedBatches[_batchKeyForShot(parsed)],
          storedGrinders[_normalize(parsed.grinderModel)],
        ),
    ];
  }

  static String? _normalize(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static _BeanIdentity? _beanIdentity(String? brand, String? type) {
    final normalizedBrand = _normalize(brand);
    final normalizedType = _normalize(type);
    return normalizedBrand == null || normalizedType == null
        ? null
        : (normalizedBrand, normalizedType);
  }

  static DateTime? _parseRoastDate(String? value) =>
      DateTime.tryParse(value?.trim() ?? '');

  static _BatchIdentity _batchIdentity(
    _BeanIdentity bean,
    DateTime? roastDate,
  ) => (bean, roastDate?.toUtc());

  static _BatchIdentity? _batchKeyForShot(ParsedShot parsed) {
    final bean = _beanIdentity(parsed.beanBrand, parsed.beanType);
    return bean == null
        ? null
        : _batchIdentity(bean, _parseRoastDate(parsed.roastDate));
  }

  static ShotRecord _linkShot(
    ShotRecord shot,
    String? batchId,
    String? grinderId,
  ) {
    final context = shot.workflow.context;
    if (context == null) return shot;
    final linked = context.copyWith(
      beanBatchId: batchId,
      clearBeanBatchId: batchId == null,
      grinderId: grinderId,
      clearGrinderId: grinderId == null,
    );
    return shot.copyWith(workflow: shot.workflow.copyWith(context: linked));
  }

  static void _recordFailure(
    List<ImportError> errors,
    String entity,
    String identity,
    Object error,
    StackTrace stackTrace,
  ) {
    _log.warning('Failed to store $entity $identity', error, stackTrace);
    errors.add(
      ImportError(
        filename: identity,
        reason: '$entity storage error',
        details: error.toString(),
      ),
    );
  }
}
