import 'dart:io';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/controllers/presence_controller.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/macos_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/battery_charging_settings_page.dart';
import 'package:reaprime/src/settings/common.dart';
import 'package:reaprime/src/settings/presence_settings_page.dart';
import 'package:reaprime/src/settings/charging_mode.dart';
import 'package:reaprime/src/settings/update_dialog.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import 'settings_controller.dart';

/// Flat iOS-style list of settings. Heavy sub-pages (devices, data, skins,
/// account, advanced) are standalone launcher destinations.
class SettingsView extends StatelessWidget {
  const SettingsView({
    super.key,
    required this.controller,
    this.updateCheckService,
    this.macosUpdater,
    required this.presenceController,
    this.webUIStorage,
  });

  static const routeName = '/settings';

  final SettingsController controller;
  final PresenceController presenceController;
  final UpdateCheckService? updateCheckService;
  final MacOSUpdater? macosUpdater;
  final WebUIStorage? webUIStorage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final isMobile = Platform.isAndroid || Platform.isIOS;
          return ListView(
            children: [
              const SettingsSectionHeader('General'),
              SettingsTile(
                icon: Icons.palette_outlined,
                label: 'Appearance',
                trailing: Text(_themeModeLabel(controller.themeMode)),
                onTap: () => _showThemePicker(context),
              ),
              const SettingsDivider(),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: ShadSwitch(
                  value: controller.showSkinExitInstructions,
                  onChanged: (value) async {
                    await controller.setShowSkinExitInstructions(value);
                  },
                  label: const Text('Skin navigation guide'),
                  sublabel: const Text(
                    'Show how to return to the dashboard when opening a skin',
                  ),
                ),
              ),

              const SettingsSectionHeader('Updates'),
              if (!Platform.isIOS) ...[
                SettingsTile(
                  icon: Icons.science_outlined,
                  label: 'Update channel',
                  trailing: Text(_updateChannelLabel(controller.updateChannel)),
                  onTap: () => _showUpdateChannelPicker(context),
                ),
                const SettingsDivider(),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: ShadSwitch(
                  value: controller.automaticUpdateCheck,
                  onChanged: (v) async {
                    await controller.setAutomaticUpdateCheck(v);
                    if (v) {
                      await updateCheckService?.enableAutomaticChecks();
                    } else {
                      await updateCheckService?.disableAutomaticChecks();
                    }
                    if (macosUpdater?.isAvailable == true) {
                      try {
                        await macosUpdater?.setAutomaticChecks(v);
                      } catch (e, st) {
                        Logger('Settings View').warning(
                          'Sparkle automatic-check toggle failed',
                          e,
                          st,
                        );
                      }
                    }
                  },
                  label: const Text('Automatic update checks'),
                  sublabel: const Text('Check for updates every 12 hours'),
                ),
              ),
              const SettingsDivider(),
              ListTile(
                leading: const Icon(LucideIcons.refreshCcwDot),
                title: const Text('Check for updates'),
                trailing: updateCheckService?.hasAvailableUpdate == true
                    ? Chip(
                        label: Text(
                          updateCheckService?.availableUpdate?.version ?? '',
                          style: const TextStyle(fontSize: 12),
                        ),
                        backgroundColor: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                onTap: () => _checkForUpdates(context),
              ),

              const SettingsSectionHeader('Power'),
              if (isMobile) ...[
                SettingsTile(
                  icon: Icons.battery_charging_full_outlined,
                  label: 'Battery & Charging',
                  trailing: Text(_chargingModeLabel(controller.chargingMode)),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            BatteryChargingSettingsPage(controller: controller),
                      ),
                    );
                  },
                ),
                const SettingsDivider(),
              ],
              SettingsTile(
                icon: Icons.schedule_outlined,
                label: 'Sleep & Wake',
                trailing: Text(_presenceSubtitle()),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PresenceSettingsPage(
                        controller: controller,
                        keepAwakeUntil: presenceController.keepAwakeUntil,
                      ),
                    ),
                  );
                },
              ),
              const SettingsDivider(),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: ShadSwitch(
                  value: controller.keepAwake,
                  onChanged: (value) async {
                    await controller.setKeepAwake(value);
                  },
                  label: const Text('Keep screen awake'),
                  sublabel: const Text(
                    'Prevent the tablet screen from turning off while the app is running',
                  ),
                ),
              ),

              const SettingsSectionHeader('About'),
              SettingsTile(
                icon: Icons.info_outline,
                label: 'About',
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => _showAboutSection(context),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _themeModeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'System';
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
    }
  }

  static String _updateChannelLabel(UpdateChannel channel) {
    switch (channel) {
      case UpdateChannel.stable:
        return 'Stable';
      case UpdateChannel.beta:
        return 'Beta';
    }
  }

  String _chargingModeLabel(ChargingMode mode) {
    switch (mode) {
      case ChargingMode.disabled:
        return 'Always charge';
      case ChargingMode.longevity:
        return 'Lifespan';
      case ChargingMode.balanced:
        return 'Balanced';
      case ChargingMode.highAvailability:
        return 'Always ready';
    }
  }

  String _presenceSubtitle() {
    final enabled = controller.userPresenceEnabled;
    final timeout = controller.sleepTimeoutMinutes;
    if (!enabled) return 'Disabled';
    if (timeout > 0) return 'Sleep after $timeout min';
    return 'Enabled, no sleep timeout';
  }

  void _showThemePicker(BuildContext context) {
    showShadDialog(
      context: context,
      builder: (dialogContext) {
        return ShadDialog(
          title: const Text('Appearance'),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('System Theme'),
                  trailing: controller.themeMode == ThemeMode.system
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    controller.updateThemeMode(ThemeMode.system);
                    Navigator.of(dialogContext).pop();
                  },
                ),
                ListTile(
                  title: const Text('Light Theme'),
                  trailing: controller.themeMode == ThemeMode.light
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    controller.updateThemeMode(ThemeMode.light);
                    Navigator.of(dialogContext).pop();
                  },
                ),
                ListTile(
                  title: const Text('Dark Theme'),
                  trailing: controller.themeMode == ThemeMode.dark
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    controller.updateThemeMode(ThemeMode.dark);
                    Navigator.of(dialogContext).pop();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showUpdateChannelPicker(BuildContext context) {
    showShadDialog(
      context: context,
      builder: (dialogContext) {
        return ShadDialog(
          title: const Text('Update channel'),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('Stable'),
                  subtitle: const Text('Final releases only'),
                  trailing: controller.updateChannel == UpdateChannel.stable
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () =>
                      _selectUpdateChannel(dialogContext, UpdateChannel.stable),
                ),
                ListTile(
                  title: const Text('Beta'),
                  subtitle: const Text('Final and prerelease builds'),
                  trailing: controller.updateChannel == UpdateChannel.beta
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () =>
                      _selectUpdateChannel(dialogContext, UpdateChannel.beta),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _selectUpdateChannel(
    BuildContext dialogContext,
    UpdateChannel channel,
  ) async {
    await controller.setUpdateChannel(channel);
    if (dialogContext.mounted) Navigator.of(dialogContext).pop();
    if (macosUpdater?.isAvailable == true) {
      try {
        await macosUpdater?.setChannel(channel);
      } catch (e, st) {
        Logger('Settings View').warning('Sparkle channel change failed', e, st);
      }
    } else {
      await updateCheckService?.requestCheck();
    }
  }

  void _showAboutSection(BuildContext context) {
    showShadDialog(
      context: context,
      builder: (dialogContext) {
        return ShadDialog(
          title: const Text('About'),
          actions: [
            ShadButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InfoRow('Version', BuildInfo.version),
              const SizedBox(height: 8),
              InfoRow('Build', BuildInfo.buildNumber),
              const SizedBox(height: 8),
              InfoRow('Commit', BuildInfo.commitShort),
              const SizedBox(height: 8),
              InfoRow('Branch', BuildInfo.branch),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'License',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Copyright © 2025-2026 Decent Espresso',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(
                'Licensed under GNU General Public License v3.0',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              ShadButton.outline(
                onPressed: () async {
                  await launchUrl(
                    Uri.parse('https://www.gnu.org/licenses/gpl-3.0.html'),
                  );
                },
                child: const Text('View GPL v3 License'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _checkForUpdates(BuildContext context) async {
    final updater = macosUpdater;
    if (updater != null && updater.isSupported) {
      // macOS: Sparkle owns app updates.
      if (updater.isAvailable) {
        try {
          await updater.checkForUpdates();
        } catch (e, st) {
          Logger('Settings View').warning('Sparkle manual check failed', e, st);
          if (!context.mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Update check failed: $e')));
        }
        return;
      }
      // Sparkle could not be configured: no functional app-update path exists
      // on macOS, so never claim a Dart "latest version" result.
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Auto-update unavailable'),
          content: const Text(
            'The built-in updater could not be configured on this Mac. '
            'Download the latest Decaid build from GitHub Releases.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Later'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await launchUrl(
                  Uri.parse(
                    'https://github.com/decentespresso/decaid/releases',
                  ),
                );
              },
              child: const Text('Open Releases'),
            ),
          ],
        ),
      );
      return;
    }
    final log = Logger('Settings View');
    try {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Checking for updates...')));

      final updateInfo = await updateCheckService?.checkForUpdate();

      if (!context.mounted) return;

      if (updateInfo != null) {
        if (Platform.isAndroid) {
          final updater = AndroidUpdater(owner: 'tadelv', repo: 'reaprime');
          final releaseUrl = updateCheckService?.getReleaseUrl(updateInfo);
          showDialog(
            context: context,
            builder: (context) => UpdateDialog(
              updateInfo: updateInfo,
              currentVersion: BuildInfo.version,
              onViewReleaseNotes: () {
                if (releaseUrl != null) launchUrl(Uri.parse(releaseUrl));
              },
              onDownload: (info, onProgress) =>
                  updater.downloadUpdate(info, onProgress: onProgress),
              onInstall: (path) => updater.installUpdate(path),
            ),
          );
        } else {
          final releaseUrl = updateCheckService?.getReleaseUrl(updateInfo);
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Update Available'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Version ${updateInfo.version} is available'),
                  const SizedBox(height: 8),
                  Text('Current version: ${BuildInfo.version}'),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Later'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    Navigator.of(context).pop();
                    if (releaseUrl != null) {
                      await launchUrl(Uri.parse(releaseUrl));
                    }
                  },
                  child: const Text("What's new"),
                ),
              ],
            ),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You are on the latest version')),
        );
      }

      await webUIStorage?.downloadRemoteSkins();
    } catch (e, stackTrace) {
      log.severe('Error checking for updates', e, stackTrace);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to check for updates: $e')),
      );
    }
  }
}
