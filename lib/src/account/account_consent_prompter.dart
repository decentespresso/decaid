import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AccountConsentPrompter {
  final GlobalKey<NavigatorState> _navigatorKey;
  final Duration timeout;

  AccountConsentPrompter({
    required GlobalKey<NavigatorState> navigatorKey,
    this.timeout = const Duration(seconds: 30),
  }) : _navigatorKey = navigatorKey;

  Future<AccountConsentDecision?> prompt(String callerLabel) {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return Future.value();
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return Future.value();
    final route = ShadDialogRoute<AccountConsentDecision>(
      pageBuilder: (context) => _AccountConsentDialog(callerLabel: callerLabel),
      barrierDismissible: false,
    );
    final result = navigator.push(route);
    final timer = Timer(timeout, () {
      if (route.isActive && navigator.mounted) navigator.removeRoute(route);
    });
    return result.whenComplete(timer.cancel);
  }
}

class _AccountConsentDialog extends StatelessWidget {
  final String callerLabel;

  const _AccountConsentDialog({required this.callerLabel});

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('Decent account access'),
      description: Text(
        '$callerLabel wants to use your linked Decent account.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () =>
              Navigator.of(context).pop(AccountConsentDecision.denied),
          child: const Text('Deny'),
        ),
        ShadButton(
          onPressed: () =>
              Navigator.of(context).pop(AccountConsentDecision.allowed),
          child: const Text('Allow'),
        ),
      ],
      child: const Text(
        'This request may come from another device on your local network.',
      ),
    );
  }
}
