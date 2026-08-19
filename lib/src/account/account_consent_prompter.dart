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

    return showShadDialog<AccountConsentDecision>(
      context: context,
      barrierDismissible: false,
      builder: (context) =>
          _AccountConsentDialog(callerLabel: callerLabel, timeout: timeout),
    );
  }
}

class _AccountConsentDialog extends StatefulWidget {
  final String callerLabel;
  final Duration timeout;

  const _AccountConsentDialog({
    required this.callerLabel,
    required this.timeout,
  });

  @override
  State<_AccountConsentDialog> createState() => _AccountConsentDialogState();
}

class _AccountConsentDialogState extends State<_AccountConsentDialog> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.timeout, () {
      if (mounted) Navigator.of(context).pop<AccountConsentDecision>();
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('Decent account access'),
      description: Text(
        '${widget.callerLabel} wants to use your linked Decent account.',
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
