import 'package:flutter/material.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class FeedbackButton extends StatelessWidget {
  final DecentAccountService? accountService;
  final VoidCallback onPressed;

  const FeedbackButton({
    super.key,
    required this.accountService,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: accountService?.identityAuthorityChanges,
      builder: (context, _) => FutureBuilder<bool>(
        future: accountService?.isLoggedIn(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done ||
              snapshot.data != true ||
              snapshot.hasError) {
            return const Text('Sign in under Decent Account to send feedback.');
          }
          return ShadButton.outline(
            onPressed: onPressed,
            child: const Text('Send Feedback'),
          );
        },
      ),
    );
  }
}
