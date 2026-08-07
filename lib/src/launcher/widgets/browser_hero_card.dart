import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widget_previews.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class BrowserHeroCard extends StatelessWidget {
  const BrowserHeroCard({super.key, required this.deviceIp, this.port = 3000});

  final String deviceIp;
  final int port;

  String get _url =>
      'http://$deviceIp:$port/?_=${DateTime.now().millisecondsSinceEpoch}';

  String get _displayUrl => 'http://$deviceIp:$port';

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Row(
            spacing: 8,
            children: [
              Icon(
                LucideIcons.globe,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              Text('Open in your browser', style: theme.textTheme.h4),
            ],
          ),
          Text(
            "This device's built-in web view is unreliable, so the interface "
            "isn't shown inside the app. Open it in a browser instead — tap "
            'Open Browser below, or scan the code from a phone or laptop.',
            style: theme.textTheme.muted,
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              Semantics(
                label: 'QR code to open WebUI at $_displayUrl',
                excludeSemantics: true,
                child: SizedBox(
                  width: 120,
                  height: 120,
                  child: PrettyQrView.data(
                    data: _url,
                    decoration: PrettyQrDecoration(
                      quietZone: PrettyQrQuietZone.standard,
                      shape: PrettyQrSquaresSymbol(
                        unifiedFinderPattern: true,
                        color: theme.colorScheme.foreground,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    SelectableText(
                      _displayUrl,
                      style: theme.textTheme.p.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ShadButton.outline(
                          size: ShadButtonSize.sm,
                          leading: const Icon(LucideIcons.copy, size: 14),
                          child: const Text('Copy URL'),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: _url));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('URL copied'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                          },
                        ),
                        ShadButton(
                          size: ShadButtonSize.sm,
                          leading: const Icon(
                            LucideIcons.externalLink,
                            size: 14,
                          ),
                          child: const Text('Open Browser'),
                          onPressed: () {
                            launchUrl(Uri.parse(_url));
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

@Preview(name: 'Browser Hero Card', group: 'Launcher')
Widget browserHeroCardPreview() {
  return ShadApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(32),
        child: SizedBox(
          width: 500,
          child: BrowserHeroCard(deviceIp: '192.168.1.42'),
        ),
      ),
    ),
  );
}
