import 'dart:convert';
import 'package:http/http.dart' as http;

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

class DecentAccountService {
  static const bool kEnableSerialVerification = true;

  final http.Client _httpClient;
  final CredentialStore _store;
  final String baseUrl;
  DecentAccountService({
    required http.Client httpClient,
    required CredentialStore credentialStore,
    this.baseUrl = "https://decentespresso.com",
  }) : _httpClient = httpClient,
       _store = credentialStore;

  Future<bool> login(String email, String password) async {
    final response = await _authedGet(
      email,
      password,
      '/support/api/login_test',
    );

    if (response.statusCode == 200 && response.body != '0') {
      await _store.write(key: 'email', value: email);
      await _store.write(key: 'password', value: response.body.trim());
      return true;
    }
    return false;
  }

  Future<void> logout() async {
    await _store.delete(key: 'email');
    await _store.delete(key: 'password');
  }

  Future<bool> isLoggedIn() async => await _store.read(key: 'email') != null;

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

  Future<void> emailSerialMismatch(String serial) async {
    final email = await _store.read(key: 'email');
    final password = await _store.read(key: 'password');
    if (email == null || password == null) {
      throw StateError('not logged in');
    }
    final subject = Uri.encodeComponent(
      'My machine serial number #$serial is not associated with my login',
    );
    final body = Uri.encodeComponent(
      'I linked my de1app to my Decent account, and found that this '
      'account does not list the machine #$serial I am connected to.',
    );
    final response = await _authedGet(
      email,
      password,
      '/support/api/email?subject=$subject&body=$body',
    );
    final responseBody = response.body.trim();
    if (response.statusCode != 200 || responseBody == '0') {
      throw Exception(
        'email serial mismatch failed (${response.statusCode}): ${response.body}',
      );
    }
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
