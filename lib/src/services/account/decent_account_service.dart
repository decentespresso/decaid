import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

List<String> parseSerialNumbers(String body) {
  return const LineSplitter()
      .convert(body)
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map((line) => line.split(RegExp(r'\s+')).first)
      .where((serial) => serial.isNotEmpty)
      .toSet()
      .toList();
}

abstract class CredentialStore {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});

  Future<void> delete({required String key});
}

enum DecentAccountStatus { authenticated, unauthenticated, indeterminate }

class DecentAccountService {
  static const bool kEnableSerialVerification = true;
  static const int _maxContactIdLength = 256;

  final http.Client _httpClient;
  final CredentialStore _store;
  final String baseUrl;
  final Duration retryInterval;
  final Logger _log = Logger('DecentAccount');

  bool? _authenticated;
  Future<bool>? _validationFuture;
  DateTime? _cooldownUntil;
  int _authGeneration = 0;

  DecentAccountService({
    required http.Client httpClient,
    required CredentialStore credentialStore,
    this.baseUrl = "https://decentespresso.com",
    this.retryInterval = const Duration(seconds: 30),
  }) : _httpClient = httpClient,
       _store = credentialStore;

  Future<bool> login(String email, String password) async {
    final response = await _authedGet(
      email,
      password,
      '/support/api/login_test',
    );

    if (response.statusCode == 200 && response.body.trim() != '0') {
      await _store.write(key: 'email', value: email);
      await _store.write(key: 'password', value: response.body.trim());
      _authGeneration++;
      _authenticated = true;
      _log.info('login -> accepted');
      return true;
    }
    _log.warning('login -> rejected');
    return false;
  }

  Future<void> logout() async {
    await _store.delete(key: 'email');
    await _store.delete(key: 'password');
    _authGeneration++;
    _authenticated = false;
  }

  Future<bool> hasLinkedAccount() async =>
      await _store.read(key: 'email') != null &&
      await _store.read(key: 'password') != null;

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
    });
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
    final valid = response.statusCode == 200 && response.body.trim() != '0';
    final rejected =
        response.statusCode == 401 ||
        (response.statusCode == 200 && response.body.trim() == '0');
    if (!valid && !rejected) {
      _log.info('validation -> indeterminate');
      return _authenticated == false
          ? DecentAccountStatus.unauthenticated
          : DecentAccountStatus.indeterminate;
    }
    if (valid) {
      _log.info('validation -> accepted');
      _setAuthenticated(generation, valid);
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
    if (generation == _authGeneration) _authenticated = value;
  }

  void reportAuthenticationFailure() {
    _authGeneration++;
    _authenticated = false;
  }

  Future<bool> isAuthKnownInvalid() async => _authenticated == false;

  Future<String?> getEmail() async => _store.read(key: 'email');

  Future<List<String>> fetchSerialNumbers() async {
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      throw StateError('not logged in');
    }
    final response = await _authedGet(
      email,
      password,
      '/support/api/sn?onlyespressomachines=1',
    );
    if (response.statusCode != 200) {
      throw Exception(
        'serial fetch failed (${response.statusCode}): ${response.body.trim()}',
      );
    }
    final body = response.body.trim();

    if (body == '0') {
      throw StateError('Unexpected response: $body');
    }

    if (body.isEmpty) {
      return [];
    }

    return parseSerialNumbers(body);
  }

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
  }) async {
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      throw StateError('not logged in');
    }
    final query = Uri(
      queryParameters: {'subject': subject, 'body': body},
    ).query;
    final response = await _authedGet(
      email,
      password,
      '/support/api/email?$query',
    );
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
    String path,
  ) async {
    final basic = base64Encode(
      utf8.encode("${email.trim()}:${password.trim()}"),
    );
    return _httpClient.get(
      Uri.parse('$baseUrl$path'),
      headers: {'authorization': "Basic $basic"},
    );
  }
}
