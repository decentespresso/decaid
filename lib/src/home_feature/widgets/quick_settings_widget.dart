import 'dart:io';

import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

class QuickSettingsWidget extends StatefulWidget {
  final WebUIService webUIService;
  final SettingsController settingsController;
  final De1Controller de1controller;
  final WebUIStorage webUIStorage;

  const QuickSettingsWidget({
    super.key,
    required this.de1controller,
    required this.settingsController,
    required this.webUIService,
    required this.webUIStorage,
  });
  @override
  State<StatefulWidget> createState() {
    return _QuickSettingsState();
  }

  static void showQRCodeDialog(BuildContext context, String deviceIp) {
    showShadDialog(
      context: context,
      builder: (context) => ShadDialog(
        title: Text("Scan QR code to visit with your device"),
        actions: [
          ShadButton(
            child: Text("Close"),
            onPressed: () {
              Navigator.of(context).pop();
            },
          ),
        ],
        description: const Text(
          "This will open WebUI in the browser on your device",
        ),

        child: Center(
          child: SizedBox(
            height: 220,
            child: PrettyQrView.data(
              data:
                  'http://$deviceIp:3000/?_=${DateTime.now().millisecondsSinceEpoch}',
              decoration: PrettyQrDecoration(
                quietZone: PrettyQrQuietZone.standard,
                shape: PrettyQrSquaresSymbol(
                  unifiedFinderPattern: true,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickSettingsState extends State<QuickSettingsWidget> {
  bool _isServingUI = false;
  String? _errorMessage;

  static const String _selectedSkinPrefKey = 'selected_webui_skin_id';

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadCard(
      title: Text('Quick Glance', style: theme.textTheme.h4),
      child: Semantics(
        explicitChildNodes: true,
        label: 'Quick settings',
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16.0,
            children: [
              MergeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(child: Text("IP Address:")),
                    Flexible(
                      child: Text("${widget.webUIService.deviceIp()}:3000"),
                    ),
                  ],
                ),
              ),
              _buildWebUIControl(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWebUIControl(BuildContext context) {
    return StreamBuilder<De1Interface?>(
      stream: widget.de1controller.de1,
      builder: (context, de1State) {
        if (!de1State.hasData || de1State.data == null) {
          return SizedBox.shrink();
        }

        if (_errorMessage != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                "WebUI Error:",
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              Text(
                _errorMessage!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              ShadButton.secondary(
                onPressed: () {
                  setState(() {
                    _errorMessage = null;
                  });
                },
                child: Text("Dismiss"),
              ),
            ],
          );
        }

        if (_isServingUI) {
          return MergeSemantics(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(child: Text("WebUI:")),
                Flexible(
                  child: Row(
                    spacing: 8,
                    children: [
                      Semantics(
                        label: 'Starting WebUI',
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      Text("Starting..."),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        if (widget.webUIService.isServing) {
          final skinName = widget.webUIService.serverPath().split('/').last;
          return Column(
            spacing: 8.0,
            children: [
              MergeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(child: Text("WebUI:")),
                    Flexible(child: Text(skinName)),
                  ],
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: ShadButton(
                      child: Text("Open", overflow: TextOverflow.ellipsis),
                      onPressed: () async {
                        if (Platform.isLinux) {
                          final url = Uri.parse(
                            'http://localhost:3000?_=${DateTime.now().millisecondsSinceEpoch}',
                          );
                          await launchUrl(url);
                        } else {
                          SkinView.open(Navigator.of(context));
                        }
                      },
                    ),
                  ),
                  Flexible(
                    child: Semantics(
                      button: true,
                      label: 'Show QR code for WebUI',
                      child: ExcludeSemantics(
                        child: ShadIconButton(
                          icon: const Icon(Icons.qr_code),
                          onPressed: () async {
                            QuickSettingsWidget.showQRCodeDialog(
                              context,
                              widget.webUIService.deviceIp(),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        } else {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(child: Text("WebUI:")),
              Flexible(
                child: ShadButton(
                  onPressed: _startWebUI,
                  child: Text("Start WebUI"),
                ),
              ),
            ],
          );
        }
      },
    );
  }

  Future<void> _startWebUI() async {
    setState(() {
      _isServingUI = true;
      _errorMessage = null;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSkinId = prefs.getString(_selectedSkinPrefKey);

      final skins = widget.webUIStorage.installedSkins;

      if (skins.isEmpty) {
        throw Exception('No WebUI skins available. Please install a skin.');
      }

      WebUISkin? skinToUse;
      if (savedSkinId != null) {
        skinToUse = widget.webUIStorage.getSkin(savedSkinId);
      }
      skinToUse ??= widget.webUIStorage.defaultSkin;

      if (skinToUse == null) {
        throw Exception('No default WebUI skin found.');
      }

      await widget.webUIService.serveFolderAtPath(skinToUse.path, port: 3000);

      await prefs.setString(_selectedSkinPrefKey, skinToUse.id);

      if (mounted) {
        setState(() {
          _isServingUI = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isServingUI = false;
        });
      }
    }
  }
}
