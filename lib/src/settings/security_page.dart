import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/account/account_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key, required this.controller});

  static const cafeHardeningGuideUrl =
      'https://github.com/decentespresso/decaid/blob/main/doc/deployment/cafe-provisioning.md';

  final SettingsController controller;

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  final _log = Logger('Security Page');
  bool _saving = false;

  Future<void> _setRequireExtensionManagementAuthorization(bool value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.controller.setRequireExtensionManagementAuthorization(value);
    } catch (error, stackTrace) {
      _log.warning(
        'Saving extension management policy failed',
        error,
        stackTrace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save the security setting. Try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openCafeHardeningGuide() async {
    await launchUrl(
      Uri.parse(SecurityPage.cafeHardeningGuideUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final protected =
              widget.controller.requireExtensionManagementAuthorization;
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  _buildModeCard(protected),
                  if (protected)
                    _buildProtectedScopeCard()
                  else ...[
                    _buildCompatibilityWarningCard(),
                    _buildUpgradeNoticeCard(),
                  ],
                  _buildLinksCard(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildModeCard(bool protected) {
    final scheme = Theme.of(context).colorScheme;
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Text(
            protected ? 'Protected mode (ON)' : 'Compatibility mode (OFF)',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: protected ? scheme.primary : scheme.error,
            ),
          ),
          ShadSwitch(
            value: protected,
            enabled: !_saving,
            onChanged: _saving
                ? null
                : (value) => _setRequireExtensionManagementAuthorization(value),
            label: const Text('Require authorization for extension management'),
            sublabel: const Text(
              'Require an extensions:manage API token, or an approved plugin '
              'grant, before extensions and extension settings can be changed.',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompatibilityWarningCard() {
    final scheme = Theme.of(context).colorScheme;
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          _cardHeading(
            icon: Icons.warning_amber_outlined,
            color: scheme.error,
            text: 'Anyone can manage extensions',
          ),
          Text(
            'While protection is off, anyone who can reach the management API '
            "on this device's network, or a plugin that is allowed to call it, "
            'can install, modify, approve and remove extensions, approve '
            'permission escalations and change extension settings.',
          ),
          Text(
            'Compatibility mode keeps Home Assistant, MCP clients, skins and '
            'other existing integrations working without tokens. It is a '
            'compatibility tradeoff, not a security guarantee.',
          ),
        ],
      ),
    );
  }

  Widget _buildUpgradeNoticeCard() {
    final scheme = Theme.of(context).colorScheme;
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          _cardHeading(
            icon: Icons.system_update_alt_outlined,
            color: scheme.error,
            text: 'Upgrade notice',
          ),
          Text(
            'Decaid 0.9.3 removes the always-on extension-management '
            'protection that shipped in 0.9.2, for both new and existing '
            'installations. Fleet and café operators should turn this setting '
            'on and apply network restrictions.',
          ),
        ],
      ),
    );
  }

  Widget _buildProtectedScopeCard() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          _cardHeading(
            icon: Icons.lock_outline,
            color: Theme.of(context).colorScheme.primary,
            text: 'What protected mode covers',
          ),
          Text(
            'Installing, updating, removing, approving permission escalations '
            'and changing extension settings all require a valid '
            'extensions:manage API token or an approved plugin grant.',
          ),
          Text(
            'Protection covers extension management only. Tokens are bearer '
            'credentials sent over plain HTTP on port 8080, so anyone on the '
            'same network can observe them; HTTPS for the web server is '
            'proposed in #925. Other REST and WebSocket APIs are not covered by '
            'this setting, and optional full API authentication is tracked in '
            '#1135.',
          ),
        ],
      ),
    );
  }

  Widget _buildLinksCard() {
    return ShadCard(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('API tokens'),
              subtitle: const Text(
                'Create and revoke extensions:manage tokens',
              ),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: () =>
                  Navigator.of(context).pushNamed(AccountPage.routeName),
            ),
            const Divider(height: 1, indent: 56),
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('Café hardening guide'),
              subtitle: const Text(
                'Securing a tablet on a shared or commercial network',
              ),
              trailing: const Icon(Icons.open_in_new, size: 20),
              onTap: _openCafeHardeningGuide,
            ),
          ],
        ),
      ),
    );
  }

  Widget _cardHeading({
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
