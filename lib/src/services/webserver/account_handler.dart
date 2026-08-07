part of '../webserver_service.dart';

class AccountHandler {
  final DecentAccountService _accountService;

  AccountHandler({required DecentAccountService accountService})
    : _accountService = accountService;

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/account/decent', _handleStatus);
  }

  Future<Response> _handleStatus(Request request) async {
    return jsonOk({'loggedIn': await _accountService.isLoggedIn()});
  }
}
