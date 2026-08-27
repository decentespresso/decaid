import 'package:flutter/material.dart';
import 'package:reaprime/src/account/app_log_upload_section.dart';
import 'package:reaprime/src/account/decent_login_form.dart';
import 'package:reaprime/src/account/account_tokens_section.dart';
import 'package:reaprime/src/controllers/account_tokens_controller.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/app_log_upload_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.accountService,
    this.tokensController,
    this.appLogUploadService,
  });

  static const routeName = '/account';

  final DecentAccountService accountService;
  final AccountTokensController? tokensController;
  final AppLogUploadService? appLogUploadService;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  Widget _appLogUploadCard(AppLogUploadService service) {
    return ShadCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: AppLogUploadSection(service: service),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Decent Account')),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: FutureBuilder<bool>(
            future: widget.accountService.isLoggedIn(),
            builder: (context, snapshot) {
              final loggedIn = snapshot.data ?? false;

              if (loggedIn) {
                return FutureBuilder<String?>(
                  future: widget.accountService.getEmail(),
                  builder: (context, emailSnap) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ShadCard(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.account_circle, size: 40),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Logged In',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleMedium,
                                          ),
                                          Text(
                                            emailSnap.data ?? '',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodySmall,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                ShadButton.destructive(
                                  onPressed: () async {
                                    final uploadService =
                                        widget.appLogUploadService;
                                    await Future.wait<void>([
                                      widget.accountService.logout(),
                                      if (uploadService != null)
                                        uploadService.setEnabled(false),
                                    ]);
                                    if (mounted) setState(() {});
                                  },
                                  child: const Text('Unlink Account'),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (widget.appLogUploadService != null) ...[
                          const SizedBox(height: 16),
                          _appLogUploadCard(widget.appLogUploadService!),
                        ],
                        if (widget.tokensController != null) ...[
                          const SizedBox(height: 16),
                          ShadCard(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: AccountTokensSection(
                                controller: widget.tokensController!,
                              ),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                );
              }

              final loginCard = ShadCard(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Link Your Account',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Link your Decent Espresso account to verify your machine serial number and access additional features.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 16),
                      DecentLoginForm(
                        accountService: widget.accountService,
                        onSuccess: () => setState(() {}),
                        secondaryLabel: 'Cancel',
                        onSecondary: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
              );
              final uploadService = widget.appLogUploadService;
              if (uploadService == null) return loginCard;
              return FutureBuilder<bool>(
                future: widget.accountService.hasLinkedAccount(),
                builder: (context, linkedSnapshot) {
                  if (linkedSnapshot.data != true) return loginCard;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      loginCard,
                      const SizedBox(height: 16),
                      _appLogUploadCard(uploadService),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
