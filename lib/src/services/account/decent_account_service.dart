import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'registered_decent_machine.dart';

List<String> parseSerialNumbers(String body) =>
    parseRegisteredMachines(body).map((m) => m.serial).toList();

abstract class CredentialStore {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});

  Future<void> delete({required String key});
}

class _IdentityMapping {
  final String transportType;
  final String deviceId;
  final String serial;

  const _IdentityMapping({
    required this.transportType,
    required this.deviceId,
    required this.serial,
  });

  Map<String, dynamic> toJson() => {
    'transportType': transportType,
    'deviceId': deviceId,
    'serial': serial,
  };

  factory _IdentityMapping.fromJson(Map<String, dynamic> json) =>
      _IdentityMapping(
        transportType: json['transportType'] as String,
        deviceId: json['deviceId'] as String,
        serial: json['serial'] as String,
      );
}

enum DecentAccountStatus { authenticated, unauthenticated, indeterminate }

class DecentAccountService {
  static const bool kEnableSerialVerification = true;
  static const int _maxContactIdLength = 256;

  static const String _registeredMachinesKey = 'registered_machines';
  static const String _identityMappingsKey = 'identity_mappings';

  final http.Client _httpClient;
  final CredentialStore _store;
  final String baseUrl;
  final Duration retryInterval;
  final Logger _log = Logger('DecentAccount');

  bool? _authenticated;
  Future<bool>? _validationFuture;
  DateTime? _cooldownUntil;
  int _authGeneration = 0;
  Future<void> _accountWriteLock = Future.value();

  List<RegisteredDecentMachine> _machines = const [];
  List<_IdentityMapping> _mappings = const [];
  bool _cacheLoaded = false;
  bool _machineCacheLoadFailed = false;
  bool _mappingCacheLoadFailed = false;
  bool _hasLinkedAccount = false;
  bool _linkedAccountKnown = false;
  bool _machinesRefreshed = false;
  Future<void>? _refreshFuture;
  Completer<void> _refreshChanged = Completer<void>();
  final StreamController<void> _identityAuthorityChanges =
      StreamController<void>.broadcast(sync: true);

  DecentAccountService({
    required http.Client httpClient,
    required CredentialStore credentialStore,
    this.baseUrl = "https://decentespresso.com",
    this.retryInterval = const Duration(seconds: 30),
  }) : _httpClient = httpClient,
       _store = credentialStore;

  Stream<void> get identityAuthorityChanges => _identityAuthorityChanges.stream;

  void _notifyIdentityAuthorityChanged() {
    _identityAuthorityChanges.add(null);
  }

  Future<void> initialize() async {
    try {
      _hasLinkedAccount = await hasLinkedAccount();
      _linkedAccountKnown = true;
    } catch (e, st) {
      _hasLinkedAccount = false;
      _log.warning('Failed to read linked account', e, st);
    }
    await _loadCachedRegisteredMachines();
    await _loadCachedMappings();
    _cacheLoaded = true;
    unawaited(_ensureMachinesFresh());
  }

  Future<void> get accountReady async {
    while (true) {
      var inFlight = _refreshFuture;
      if (inFlight == null) {
        if ((_machinesRefreshed &&
                !_machineCacheLoadFailed &&
                !_mappingCacheLoadFailed) ||
            !_cacheLoaded ||
            (!_hasLinkedAccount && _linkedAccountKnown)) {
          return;
        }
        inFlight = _ensureMachinesFresh();
      }
      await Future.any([inFlight, _refreshChanged.future]);
      final latest = _refreshFuture;
      if (latest != null && !identical(inFlight, latest)) continue;
      return;
    }
  }

  Future<void> _ensureMachinesFresh() {
    final inFlight = _refreshFuture;
    if (inFlight != null) return inFlight;
    return _trackRefresh(_backgroundRefresh());
  }

  Future<void> _trackRefresh(Future<void> future) {
    _replaceRefresh(future);
    future.whenComplete(() {
      if (identical(_refreshFuture, future)) _refreshFuture = null;
    }).ignore();
    return future;
  }

  void _replaceRefresh(Future<void>? future) {
    final changed = _refreshChanged;
    _refreshFuture = future;
    _refreshChanged = Completer<void>();
    changed.complete();
  }

  Future<void> _backgroundRefresh() async {
    final generation = _authGeneration;
    try {
      if (_machineCacheLoadFailed) await _loadCachedRegisteredMachines();
      if (_mappingCacheLoadFailed) await _loadCachedMappings();
      if (_machinesRefreshed) return;
      final linked = await hasLinkedAccount();
      if (generation != _authGeneration) return;
      _hasLinkedAccount = linked;
      _linkedAccountKnown = true;
      if (!linked) return;
      if (!await isLoggedIn()) return;
      await refreshRegisteredMachines();
    } catch (e) {
      _log.info('Background registered-machine refresh unavailable: $e');
    }
  }

  Future<void> _loadCachedRegisteredMachines() async {
    _machineCacheLoadFailed = false;
    try {
      final raw = await _store.read(key: _registeredMachinesKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (!await _cacheMatchesCurrentAccount(decoded)) return;
      final machinesJson = decoded['machines'] as List? ?? const [];
      _machines = [
        for (final m in machinesJson)
          RegisteredDecentMachine.fromJson(m as Map<String, dynamic>),
      ];
    } catch (e) {
      _machineCacheLoadFailed = true;
      _log.warning('Failed to load cached registered machines: $e');
    }
  }

  Future<void> _loadCachedMappings() async {
    _mappingCacheLoadFailed = false;
    try {
      final raw = await _store.read(key: _identityMappingsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (!await _cacheMatchesCurrentAccount(decoded)) return;
      _mappings = [
        for (final m in (decoded['mappings'] as List? ?? const []))
          _IdentityMapping.fromJson(m as Map<String, dynamic>),
      ];
    } catch (e) {
      _mappingCacheLoadFailed = true;
      _log.warning('Failed to load cached identity mappings: $e');
    }
  }

  Future<void> _persistRegisteredMachines(
    List<RegisteredDecentMachine> machines, {
    required String account,
  }) async {
    await _store.write(
      key: _registeredMachinesKey,
      value: jsonEncode({
        'account': account,
        'machines': [for (final m in machines) m.toJson()],
      }),
    );
  }

  Future<T> _withAccountWriteLock<T>(Future<T> Function() action) {
    final run = _accountWriteLock.then((_) => action());
    _accountWriteLock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<bool> _cacheMatchesCurrentAccount(Map<String, dynamic> decoded) async {
    final storedAccount = decoded['account'] as String?;
    final currentEmail = await _store.read(key: 'email');
    if (storedAccount == null || currentEmail == null) return false;
    return _normalizeEmail(storedAccount) == _normalizeEmail(currentEmail);
  }

  Future<void> _persistMappings(
    String account,
    List<_IdentityMapping> mappings,
  ) async {
    await _store.write(
      key: _identityMappingsKey,
      value: jsonEncode({
        'account': account,
        'mappings': [for (final m in mappings) m.toJson()],
      }),
    );
  }

  static String _normalizeEmail(String email) => email.trim().toLowerCase();

  Future<bool> login(String email, String password) async {
    final generation = _authGeneration;
    final response = await _authedGet(
      email,
      password,
      '/support/api/login_test',
    );
    if (generation != _authGeneration) return false;

    final token = response.body.trim();
    if (response.statusCode == 200 && token.isNotEmpty && token != '0') {
      final storedEmail = await _store.read(key: 'email');
      if (generation != _authGeneration) return false;
      final emailChanged =
          _normalizeEmail(storedEmail ?? '') != _normalizeEmail(email);
      final committedGeneration = ++_authGeneration;
      _authenticated = false;
      _hasLinkedAccount = false;
      _linkedAccountKnown = true;
      _notifyIdentityAuthorityChanged();
      final committed = await _withAccountWriteLock(() async {
        if (committedGeneration != _authGeneration) return false;
        if (emailChanged) {
          _machines = const [];
          _mappings = const [];
          await _store.delete(key: _registeredMachinesKey);
          await _store.delete(key: _identityMappingsKey);
          _machineCacheLoadFailed = false;
          _mappingCacheLoadFailed = false;
        }
        _machinesRefreshed = false;
        await _store.write(key: 'email', value: email);
        await _store.write(key: 'password', value: token);
        return committedGeneration == _authGeneration;
      });
      if (!committed || committedGeneration != _authGeneration) return false;
      _authenticated = true;
      _hasLinkedAccount = true;
      _log.info('login -> accepted');
      await _trackRefresh(_refreshAfterLogin());
      final accepted =
          committedGeneration == _authGeneration && _authenticated == true;
      if (accepted) _notifyIdentityAuthorityChanged();
      return accepted;
    }
    _log.warning('login -> rejected');
    return false;
  }

  Future<void> _refreshAfterLogin() async {
    try {
      await refreshRegisteredMachines();
    } catch (e) {
      _log.warning('Registered-machine refresh after login failed: $e');
    }
  }

  Future<void> logout() {
    _authGeneration++;
    _authenticated = false;
    _hasLinkedAccount = false;
    _linkedAccountKnown = true;
    _machineCacheLoadFailed = false;
    _mappingCacheLoadFailed = false;
    _replaceRefresh(null);
    _notifyIdentityAuthorityChanged();
    return _withAccountWriteLock(() async {
      _machines = const [];
      _mappings = const [];
      _machinesRefreshed = false;
      await Future.wait([
        _store.delete(key: _registeredMachinesKey),
        _store.delete(key: _identityMappingsKey),
        _store.delete(key: 'email'),
        _store.delete(key: 'password'),
      ]);
    });
  }

  Future<bool> hasLinkedAccount() async =>
      await _store.read(key: 'email') != null &&
      await _store.read(key: 'password') != null;

  bool get hasLinkedCredentials => _linkedAccountKnown && _hasLinkedAccount;

  bool get hasUsableAccountCache =>
      _cacheLoaded && _hasLinkedAccount && _authenticated != false;

  List<RegisteredDecentMachine> get usableRegisteredMachines =>
      hasUsableAccountCache ? List.unmodifiable(_machines) : const [];

  Future<List<RegisteredDecentMachine>> fetchRegisteredMachines() async {
    final generation = _authGeneration;
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      throw StateError('not logged in');
    }
    final response = await _authedGet(
      email,
      password,
      '/support/api/sn?onlyespressomachines=1&withskus=1',
    );
    if (response.statusCode == 401 && generation == _authGeneration) {
      reportAuthenticationFailure();
    }
    if (response.statusCode != 200) {
      throw Exception(
        'registered machine fetch failed (${response.statusCode}): '
        '${response.body.trim()}',
      );
    }
    final body = response.body.trim();
    if (body == '0') {
      throw StateError('Unexpected response: $body');
    }
    return parseRegisteredMachines(body);
  }

  Future<void> refreshRegisteredMachines() async {
    final generation = _authGeneration;
    final email = await _store.read(key: 'email');
    if (generation != _authGeneration) return;
    if (email == null) {
      throw StateError('not logged in');
    }
    final account = _normalizeEmail(email);
    final machines = await fetchRegisteredMachines();
    await _withAccountWriteLock(() async {
      if (generation != _authGeneration) return;
      final currentEmail = await _store.read(key: 'email');
      if (currentEmail == null || _normalizeEmail(currentEmail) != account) {
        return;
      }
      if (generation != _authGeneration) return;
      _machines = machines;
      _cacheLoaded = true;
      await _persistRegisteredMachines(machines, account: account);
      _machineCacheLoadFailed = false;
      await _pruneMappings(machines, account);
      _machinesRefreshed = true;
      _notifyIdentityAuthorityChanged();
    });
  }

  Future<void> saveMapping({
    required String transportType,
    required String deviceId,
    required String serial,
  }) async {
    final generation = _authGeneration;
    final accountLinked = _hasLinkedAccount;
    final email = await _store.read(key: 'email');
    if (email == null) {
      throw StateError('not logged in');
    }
    final account = _normalizeEmail(email);
    await _withAccountWriteLock(() async {
      if (!accountLinked ||
          !hasUsableAccountCache ||
          generation != _authGeneration) {
        return;
      }
      final currentEmail = await _store.read(key: 'email');
      if (currentEmail == null || _normalizeEmail(currentEmail) != account) {
        return;
      }
      if (generation != _authGeneration) return;
      if (!_machines.any((machine) => machine.serial == serial)) return;
      final mappings = [
        ..._mappings.where(
          (m) => !(m.transportType == transportType && m.deviceId == deviceId),
        ),
        _IdentityMapping(
          transportType: transportType,
          deviceId: deviceId,
          serial: serial,
        ),
      ];
      await _persistMappings(account, mappings);
      _mappings = mappings;
    });
  }

  Future<RegisteredDecentMachine?> lookupMapping({
    required String transportType,
    required String deviceId,
  }) async {
    final generation = _authGeneration;
    if (!hasUsableAccountCache) return null;
    if (!await hasLinkedAccount()) return null;
    if (generation != _authGeneration || !hasUsableAccountCache) return null;
    final serial = _mappings
        .where(
          (m) => m.transportType == transportType && m.deviceId == deviceId,
        )
        .map((m) => m.serial)
        .firstOrNull;
    if (serial == null) return null;
    return _machines.where((m) => m.serial == serial).firstOrNull;
  }

  Future<void> _pruneMappings(
    List<RegisteredDecentMachine> machines,
    String account,
  ) async {
    final serials = machines.map((m) => m.serial).toSet();
    final pruned = _mappings.where((m) => serials.contains(m.serial)).toList();
    if (pruned.length == _mappings.length) return;
    await _persistMappings(account, pruned);
    _mappings = pruned;
  }

  Future<bool> isLoggedIn() async {
    if (!await hasLinkedAccount()) return false;
    final cached = _authenticated;
    if (cached != null) return cached;
    final pending = _validationFuture;
    if (pending != null) return pending;
    final cooldownUntil = _cooldownUntil;
    if (cooldownUntil != null) {
      if (clock.now().isBefore(cooldownUntil)) return false;
      _cooldownUntil = null;
    }
    final future = verifyStoredCredentials();
    _validationFuture = future;
    future.whenComplete(() {
      _validationFuture = null;
      if (_authenticated == null) {
        _cooldownUntil = clock.now().add(retryInterval);
      }
    }).ignore();
    return future;
  }

  Future<bool> verifyStoredCredentials() async {
    await verifyStoredCredentialsStatus();
    return _authenticated ?? false;
  }

  Future<DecentAccountStatus> verifyStoredCredentialsStatus() async {
    final generation = _authGeneration;
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      _log.info('validation -> no stored credentials (account not linked)');
      if (generation == _authGeneration) {
        _hasLinkedAccount = false;
        _linkedAccountKnown = true;
      }
      _setAuthenticated(generation, false);
      return _accountStatus;
    }
    final http.Response response;
    try {
      response = await _authedGet(email, password, '/support/api/login_test');
    } catch (_) {
      _log.info('validation -> indeterminate');
      return _authenticated == false
          ? DecentAccountStatus.unauthenticated
          : DecentAccountStatus.indeterminate;
    }
    final token = response.body.trim();
    final valid =
        response.statusCode == 200 && token.isNotEmpty && token != '0';
    final rejected =
        response.statusCode == 401 ||
        (response.statusCode == 200 && (token.isEmpty || token == '0'));
    if (!valid && !rejected) {
      _log.info('validation -> indeterminate');
      return _authenticated == false
          ? DecentAccountStatus.unauthenticated
          : DecentAccountStatus.indeterminate;
    }
    if (valid) {
      _log.info('validation -> accepted');
      _setAuthenticated(generation, valid);
      if (!_machinesRefreshed) {
        unawaited(_ensureMachinesFresh());
      }
      return _accountStatus;
    }
    _log.info('validation -> rejected');
    _setAuthenticated(generation, false);
    return _accountStatus;
  }

  DecentAccountStatus get _accountStatus => switch (_authenticated) {
    true => DecentAccountStatus.authenticated,
    false => DecentAccountStatus.unauthenticated,
    null => DecentAccountStatus.indeterminate,
  };

  void _setAuthenticated(int generation, bool value) {
    if (generation != _authGeneration) return;
    final changed = _authenticated != value;
    _authenticated = value;
    if (value) {
      _hasLinkedAccount = true;
      _linkedAccountKnown = true;
    }
    if (changed) _notifyIdentityAuthorityChanged();
  }

  void reportAuthenticationFailure() {
    _authGeneration++;
    final changed = _authenticated != false;
    _authenticated = false;
    if (changed) _notifyIdentityAuthorityChanged();
  }

  Future<bool> isAuthKnownInvalid() async => _authenticated == false;

  Future<String?> getEmail() async => _store.read(key: 'email');

  Future<List<String>> fetchSerialNumbers() async =>
      (await fetchRegisteredMachines()).map((m) => m.serial).toList();

  Future<bool> verifyMachineSerial(String serial) async {
    final list = await fetchSerialNumbers();
    return list.contains(serial);
  }

  Future<http.Response> uploadAppLogs(
    String body, {
    required bool Function() isAllowed,
    required Duration timeout,
  }) async {
    final generation = _authGeneration;
    if (await isAuthKnownInvalid()) {
      throw StateError('account authentication rejected');
    }
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      throw StateError('not logged in');
    }
    if (generation != _authGeneration || !isAllowed()) {
      throw StateError('upload cancelled');
    }
    final basic = base64Encode(
      utf8.encode('${email.trim()}:${password.trim()}'),
    );
    final abort = Completer<void>();
    final timer = Timer(timeout, abort.complete);
    final request =
        http.AbortableRequest(
            'POST',
            Uri.parse('$baseUrl/support/api/applog_upload'),
            abortTrigger: abort.future,
          )
          ..headers.addAll({
            'authorization': 'Basic $basic',
            'content-type': 'application/json; charset=utf-8',
          })
          ..bodyBytes = utf8.encode(body);
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _httpClient.send(request),
      );
    } finally {
      timer.cancel();
    }
    if (response.statusCode == 401 && generation == _authGeneration) {
      reportAuthenticationFailure();
    }
    return response;
  }

  Future<String> sendSupportMessage({
    required String subject,
    required String body,
    Future<void>? abortTrigger,
  }) async {
    final generation = _authGeneration;
    if (await isAuthKnownInvalid()) {
      throw StateError('account authentication rejected');
    }
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      throw StateError('not logged in');
    }
    if (generation != _authGeneration) {
      throw StateError('account authentication changed');
    }
    final query = Uri(
      queryParameters: {'subject': subject, 'body': body},
    ).query;
    final response = await _authedGet(
      email,
      password,
      '/support/api/email?$query',
      abortTrigger: abortTrigger,
    );
    if (response.statusCode == 401 && generation == _authGeneration) {
      reportAuthenticationFailure();
    }
    final contactId = response.body.trim();
    if (response.statusCode != 200 ||
        contactId.isEmpty ||
        contactId == '0' ||
        contactId.length > _maxContactIdLength ||
        contactId.contains('\r') ||
        contactId.contains('\n') ||
        contactId.contains('`')) {
      throw Exception('support message failed (${response.statusCode})');
    }
    return contactId;
  }

  Future<void> emailSerialMismatch(String serial) async {
    await sendSupportMessage(
      subject:
          'My machine serial number #$serial is not associated with my login',
      body:
          'I linked my de1app to my Decent account, and found that this '
          'account does not list the machine #$serial I am connected to.',
    );
  }

  Future<http.Response> _authedGet(
    String email,
    String password,
    String path, {
    Future<void>? abortTrigger,
  }) async {
    final basic = base64Encode(
      utf8.encode("${email.trim()}:${password.trim()}"),
    );
    if (abortTrigger != null) {
      final request = http.AbortableRequest(
        'GET',
        Uri.parse('$baseUrl$path'),
        abortTrigger: abortTrigger,
      )..headers['authorization'] = "Basic $basic";
      return http.Response.fromStream(await _httpClient.send(request));
    }
    return _httpClient.get(
      Uri.parse('$baseUrl$path'),
      headers: {'authorization': "Basic $basic"},
    );
  }
}
