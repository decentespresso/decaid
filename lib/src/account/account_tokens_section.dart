import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reaprime/src/controllers/account_tokens_controller.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';

class AccountTokensSection extends StatefulWidget {
  const AccountTokensSection({super.key, required this.controller});

  final AccountTokensController controller;

  @override
  State<AccountTokensSection> createState() => _AccountTokensSectionState();
}

class _AccountTokensSectionState extends State<AccountTokensSection> {
  Future<void> _createToken() async {
    final controllerText = TextEditingController();
    var write = false;
    final result = await showDialog<({String label, bool write})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('New API token'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controllerText,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. my-laptop',
                ),
              ),
              SwitchListTile(
                key: const Key('token-write-toggle'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow write access'),
                subtitle: const Text('Permit POST/PUT through the proxy.'),
                value: write,
                onChanged: (v) => setDialogState(() => write = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                final text = controllerText.text.trim();
                if (text.isNotEmpty) {
                  Navigator.of(ctx).pop((label: text, write: write));
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (result == null || result.label.isEmpty) return;

    final token = await widget.controller.create(
      label: result.label,
      write: result.write,
    );
    if (!mounted) return;
    setState(() {});
    await _showTokenOnce(token);
  }

  Future<void> _showTokenOnce(String token) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Copy your token now'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "This is the only time the token is shown. Store it securely.",
            ),
            const SizedBox(height: 12),
            SelectableText(
              token,
              key: const Key('token-value'),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: token));
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Future<void> _revoke(String token, String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Revoke "$label"?'),
        content: const Text('Clients using this token will stop working.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.controller.revoke(token);
    if (!mounted) return;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.controller.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'API access tokens',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              key: const Key('create-token'),
              onPressed: _createToken,
              icon: const Icon(Icons.add),
              label: const Text('Create'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Named tokens let scripts and external tools call the account proxy '
          'without seeing your credentials.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (tokens.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No tokens yet.'),
          )
        else
          ...tokens.map(
            (t) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(t.label),
              subtitle: Text(
                t.scopes.contains(ProxyTokenService.scopeAccountProxyWrite)
                    ? 'read + write'
                    : 'read',
              ),
              trailing: IconButton(
                key: Key('revoke-${t.label}'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _revoke(t.token, t.label),
              ),
            ),
          ),
      ],
    );
  }
}
