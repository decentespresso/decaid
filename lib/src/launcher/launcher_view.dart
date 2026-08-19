import 'dart:io';

import 'package:flutter/material.dart';
import 'package:reaprime/src/account/account_page.dart';
import 'package:reaprime/src/controllers/battery_controller.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/scale_controller.dart';
import 'package:reaprime/src/controllers/scan_state_guardian.dart';
import 'package:reaprime/src/launcher/launcher_scan_page.dart';
import 'package:reaprime/src/launcher/widgets/browser_hero_card.dart';
import 'package:reaprime/src/launcher/widgets/connect_device_hero_card.dart';
import 'package:reaprime/src/launcher/widgets/destination_card.dart';
import 'package:reaprime/src/launcher/widgets/skin_unavailable_card.dart';
import 'package:reaprime/src/launcher/widgets/status_bar.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/settings/advanced_page.dart';
import 'package:reaprime/src/settings/data_management_page.dart';
import 'package:reaprime/src/settings/device_management_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_view.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/skin_selector/skin_selector_page.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

enum LauncherSkinSlot { browserHero, returnToSkin, skinUnavailable }

LauncherSkinSlot resolveLauncherSkinSlot({
  required bool supportsWebView,
  required bool isDegradedAndroid,
  required bool isServing,
}) {
  if (!supportsWebView || isDegradedAndroid) {
    return LauncherSkinSlot.browserHero;
  }
  if (isServing) return LauncherSkinSlot.returnToSkin;
  return LauncherSkinSlot.skinUnavailable;
}

class LauncherView extends StatelessWidget {
  static const routeName = '/home';

  const LauncherView({
    super.key,
    required this.de1Controller,
    required this.scaleController,
    required this.webUIService,
    required this.connectionManager,
    required this.deviceController,
    required this.settingsController,
    required this.scanStateGuardian,
    this.batteryController,
    this.decentAccountService,
    this.isDegradedAndroid = false,
  });

  final De1Controller de1Controller;
  final ScaleController scaleController;
  final WebUIService webUIService;
  final ConnectionManager connectionManager;
  final DeviceController deviceController;
  final SettingsController settingsController;
  final ScanStateGuardian scanStateGuardian;
  final BatteryController? batteryController;
  final DecentAccountService? decentAccountService;

  final bool isDegradedAndroid;

  bool get _supportsWebView =>
      Platform.isIOS ||
      Platform.isAndroid ||
      Platform.isMacOS ||
      Platform.isWindows;

  @override
  Widget build(BuildContext context) {
    final slot = resolveLauncherSkinSlot(
      supportsWebView: _supportsWebView,
      isDegradedAndroid: isDegradedAndroid,
      isServing: webUIService.isServing,
    );

    return Scaffold(
      body: Column(
        children: [
          StatusBar(
            de1Controller: de1Controller,
            scaleController: scaleController,
            batteryController: batteryController,
            webUIService: webUIService,
          ),

          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 24,
                    children: [
                      StreamBuilder<De1Interface?>(
                        stream: de1Controller.de1,
                        builder: (context, snapshot) {
                          final hasMachine = snapshot.data != null;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            spacing: 24,
                            children: [
                              if (!hasMachine)
                                ConnectDeviceHeroCard(
                                  onScan: () => Navigator.of(
                                    context,
                                  ).pushNamed(LauncherScanPage.routeName),
                                ),
                              _buildSkinSlot(context, slot),
                            ],
                          );
                        },
                      ),

                      _buildGrid(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkinSlot(BuildContext context, LauncherSkinSlot slot) {
    switch (slot) {
      case LauncherSkinSlot.browserHero:
        return BrowserHeroCard(deviceIp: webUIService.deviceIp());
      case LauncherSkinSlot.returnToSkin:
        return _ReturnToSkinButton(
          onTap: () {
            Navigator.of(context).pushNamed(SkinView.routeName);
          },
        );
      case LauncherSkinSlot.skinUnavailable:
        return SkinUnavailableCard(
          reason: SkinUnavailableReason.notServing,
          onPickSkin: () {
            Navigator.of(context).pushNamed(SkinSelectorPage.routeName);
          },
          onSendFeedback: () {
            Navigator.of(context).pushNamed(SettingsView.routeName);
          },
        );
    }
  }

  Widget _buildGrid(BuildContext context) {
    final destinations = <_Destination>[
      _Destination(
        icon: LucideIcons.settings,
        label: 'Settings',
        route: SettingsView.routeName,
      ),
      _Destination(
        icon: LucideIcons.bluetooth,
        label: 'Devices',
        route: DeviceManagementPage.routeName,
      ),
      _Destination(
        icon: LucideIcons.database,
        label: 'Data',
        route: DataManagementPage.routeName,
      ),
      _Destination(
        icon: LucideIcons.palette,
        label: 'Skins',
        route: SkinSelectorPage.routeName,
      ),
      if (decentAccountService != null)
        _Destination(
          icon: LucideIcons.user,
          label: 'Account',
          route: AccountPage.routeName,
        ),
      _Destination(
        icon: LucideIcons.puzzle,
        label: 'Plugins',
        route: '/plugins',
      ),
      _Destination(
        icon: LucideIcons.wrench,
        label: 'Advanced',
        route: AdvancedPage.routeName,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 400 ? 4 : 3;
        return GridView.count(
          crossAxisCount: crossAxisCount,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.0,
          children: destinations
              .map(
                (d) => DestinationCard(
                  icon: d.icon,
                  label: d.label,
                  onTap: () => Navigator.of(context).pushNamed(d.route),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _Destination {
  final IconData icon;
  final String label;
  final String route;

  const _Destination({
    required this.icon,
    required this.label,
    required this.route,
  });
}

class _ReturnToSkinButton extends StatelessWidget {
  const _ReturnToSkinButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadButton(
      size: ShadButtonSize.lg,
      leading: const Icon(LucideIcons.arrowLeft, size: 18),
      onPressed: onTap,
      child: Text(
        'Return to Skin',
        style: theme.textTheme.p.copyWith(
          color: theme.colorScheme.primaryForeground,
        ),
      ),
    );
  }
}
