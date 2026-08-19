import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/security_scoped_file.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

class SkinSelectorPage extends StatefulWidget {
  const SkinSelectorPage({
    super.key,
    required this.settingsController,
    required this.webUIService,
    required this.webUIStorage,
  });

  static const routeName = '/skins';

  final SettingsController settingsController;
  final WebUIService webUIService;
  final WebUIStorage webUIStorage;

  @override
  State<SkinSelectorPage> createState() => _SkinSelectorPageState();
}

class _SkinSelectorPageState extends State<SkinSelectorPage>
    with WidgetsBindingObserver {
  String? _selectedSkinId;
  static const String _liveEditSkinId = '__live_edit__';
  final TextEditingController _repoController = TextEditingController();
  final TextEditingController _detailController = TextEditingController();
  final Logger _log = Logger('SkinSelector');
  bool _storagePermissionGranted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _selectedSkinId = widget.webUIStorage.defaultSkin?.id;
    _checkStoragePermission();
  }

  @override
  void dispose() {
    _repoController.dispose();
    _detailController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStoragePermission();
    }
  }

  Future<void> _checkStoragePermission() async {
    if (!Platform.isAndroid) return;
    final status = await Permission.manageExternalStorage.status;
    if (mounted && status.isGranted != _storagePermissionGranted) {
      setState(() => _storagePermissionGranted = status.isGranted);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showStorageRow = Platform.isAndroid;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Web Interface'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add),
            tooltip: 'Install skin',
            onSelected: (value) => _handleInstallAction(context, value),
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'github-release',
                child: Text('GitHub Release'),
              ),
              PopupMenuItem<String>(
                value: 'github-branch',
                child: Text('GitHub Branch'),
              ),
              PopupMenuItem<String>(value: 'zip', child: Text('ZIP file')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ShadCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 16),
                _buildSkinSelector(),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _ActionButton(
                    label: Platform.isLinux ? 'Open in Browser' : 'Go to skin',
                    icon: Platform.isLinux ? Icons.open_in_browser : Icons.web,
                    onPressed: _goToSkin,
                  ),
                ),
                if (showStorageRow) ...[
                  const SizedBox(height: 16),
                  _buildStoragePermissionRow(),
                ],
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 12),
                _buildServerFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.web_outlined, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Active Skin',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Choose and manage your skins',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _ActionButton.outline(
          label: 'Check for updates',
          icon: Icons.refresh,
          size: ShadButtonSize.sm,
          onPressed: () => _checkForSkinUpdates(context),
        ),
      ],
    );
  }

  Widget _buildServerFooter() {
    final serving = widget.webUIService.isServing;
    final muted = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.7);

    final status = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: serving ? Colors.green : muted,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            serving ? 'Skin server running' : 'Skin server stopped',
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );

    final actions = <Widget>[];
    if (serving) {
      if (!Platform.isLinux) {
        actions.add(
          _ActionButton.ghost(
            label: 'Open in browser',
            icon: Icons.open_in_browser,
            size: ShadButtonSize.sm,
            foregroundColor: muted,
            onPressed: () async {
              await _openWebUIInBrowser();
            },
          ),
        );
      }
      actions.add(
        _ActionButton.ghost(
          label: 'Stop server',
          icon: Icons.stop,
          size: ShadButtonSize.sm,
          foregroundColor: ShadTheme.of(context).colorScheme.destructive,
          onPressed: () async {
            await widget.webUIService.stopServing();
            if (mounted) setState(() {});
          },
        ),
      );
    } else {
      actions.add(
        _ActionButton.ghost(
          label: 'Start server',
          icon: Icons.play_arrow,
          size: ShadButtonSize.sm,
          foregroundColor: muted,
          onPressed: _startSelectedSkin,
        ),
      );
    }

    return Row(
      children: [
        Expanded(child: status),
        const SizedBox(width: 12),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    );
  }

  Widget _buildSkinSelector() {
    final installedSkins = widget.webUIStorage.installedSkins;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: ShadTheme.of(context).colorScheme.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            borderRadius: BorderRadius.circular(8),
            value: _selectedSkinId,
            onChanged: (value) async {
              if (value == null) return;

              setState(() => _selectedSkinId = value);

              if (value == _liveEditSkinId) {
                await _pickLiveEditFolder(context);
              } else if (widget.webUIService.isServing) {
                await _restartServerWithSkin(value);
              }
            },
            items: [
              ...installedSkins.map((skin) {
                return DropdownMenuItem(
                  value: skin.id,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        skin.isBundled ? Icons.verified : Icons.folder,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(skin.name),
                      if (skin.version != null) ...[
                        const SizedBox(width: 6),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'v${skin.version}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                      if (!skin.isBundled) ...[
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            tooltip: 'Remove ${skin.name}',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () async {
                              Navigator.of(context).pop();

                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text('Remove skin?'),
                                  content: Text(
                                    'Remove "${skin.name}"? This cannot be undone.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.of(
                                        dialogContext,
                                      ).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(dialogContext).pop(true),
                                      child: const Text('Remove'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed != true) return;

                              try {
                                await widget.webUIStorage.removeSkin(skin.id);

                                if (_selectedSkinId == skin.id) {
                                  _selectedSkinId =
                                      widget.webUIStorage.defaultSkin?.id;
                                  if (widget.webUIService.isServing) {
                                    await widget.webUIService.stopServing();
                                  }
                                }
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Failed to remove skin: $e',
                                      ),
                                    ),
                                  );
                                }
                              }

                              setState(() {});
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
              if (Platform.isMacOS ||
                  Platform.isLinux ||
                  Platform.isWindows ||
                  (Platform.isAndroid &&
                      (_storagePermissionGranted ||
                          _selectedSkinId == _liveEditSkinId)))
                const DropdownMenuItem(
                  value: _liveEditSkinId,
                  child: Row(
                    children: [
                      Icon(Icons.folder_open, size: 16),
                      SizedBox(width: 8),
                      Text('Live-edit from folder...'),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStoragePermissionRow() {
    if (!Platform.isAndroid) {
      return const SizedBox.shrink();
    }

    if (_storagePermissionGranted) {
      return Row(
        children: [
          Icon(Icons.check_circle, color: Colors.green, size: 20),
          const SizedBox(width: 8),
          const Text('Full storage access granted'),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Grant full storage access to live-edit skins from external folders without copying.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        _ActionButton.outline(
          label: 'Grant Storage Access',
          icon: Icons.folder_open,
          onPressed: () async {
            final result = await Permission.manageExternalStorage.request();
            if (result.isPermanentlyDenied) {
              await openAppSettings();
            }
            await _checkStoragePermission();
          },
        ),
      ],
    );
  }

  Future<void> _restartServerWithSkin(String skinId) async {
    try {
      final skin = widget.webUIStorage.getSkin(skinId);
      if (skin == null) throw Exception('Selected skin not found');

      _log.info('Restarting WebUI server with skin: ${skin.name}');

      await widget.webUIService.stopServing();
      await widget.webUIService.serveFolderAtPath(skin.path);

      try {
        await widget.webUIStorage.setDefaultSkin(skin.id);
        _log.info('Set default skin to: ${skin.id}');
      } catch (e) {
        _log.warning('Failed to set default skin: $e');
      }

      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Skin server restarted with ${skin.name}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      _log.severe('Failed to restart WebUI server', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to restart skin server: $e')),
        );
      }
    }
  }

  Future<void> _startSelectedSkin() async {
    if (_selectedSkinId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a skin first')),
      );
      return;
    }

    if (_selectedSkinId == _liveEditSkinId) {
      await _pickLiveEditFolder(context);
      return;
    }

    try {
      final skin = widget.webUIStorage.getSkin(_selectedSkinId!);
      if (skin == null) throw Exception('Selected skin not found');

      await widget.webUIService.serveFolderAtPath(skin.path);

      try {
        await widget.webUIStorage.setDefaultSkin(skin.id);
        _log.info('Set default skin to: ${skin.id}');
      } catch (e) {
        _log.warning('Failed to set default skin: $e');
      }

      setState(() {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Skin server started with ${skin.name}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start skin server: $e')),
        );
      }
    }
  }

  Future<void> _pickCustomSkinZip(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );

    if (result == null || result.files.isEmpty) {
      setState(() => _selectedSkinId = widget.webUIStorage.defaultSkin?.id);
      return;
    }

    final filePath = result.files.single.path;
    if (filePath == null) {
      setState(() => _selectedSkinId = widget.webUIStorage.defaultSkin?.id);
      return;
    }

    try {
      final skinId = await widget.webUIStorage.installFromPath(filePath);
      final skin = widget.webUIStorage.getSkin(skinId);
      if (skin == null) {
        throw Exception('Installed skin not found: $skinId');
      }
      await widget.webUIService.serveFolderAtPath(skin.path);
      await widget.webUIStorage.setDefaultSkin(skinId);
      setState(() => _selectedSkinId = skinId);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Expanded(child: Text('Custom skin installed and loaded')),
                ShadButton.outline(
                  onPressed: () async {
                    await _openWebUIInBrowser();
                  },
                  child: const Text("Open"),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to install skin: $e')));
      }
      setState(() => _selectedSkinId = widget.webUIStorage.defaultSkin?.id);
    }
  }

  Future<void> _handleInstallAction(BuildContext context, String action) async {
    switch (action) {
      case 'github-release':
        await _installFromGitHub(context, release: true);
      case 'github-branch':
        await _installFromGitHub(context, release: false);
      case 'zip':
        await _pickCustomSkinZip(context);
    }
  }

  Future<void> _installFromGitHub(
    BuildContext context, {
    required bool release,
  }) async {
    _repoController.clear();
    _detailController.text = release ? '' : 'main';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          release
              ? 'Install from GitHub Release'
              : 'Install from GitHub Branch',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _repoController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Repository',
                hintText: 'owner/repo',
              ),
            ),
            TextField(
              controller: _detailController,
              decoration: InputDecoration(
                labelText: release ? 'Asset name (optional)' : 'Branch',
                hintText: release ? 'skin.zip' : 'main',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Install'),
          ),
        ],
      ),
    );

    final repo = _repoController.text.trim();
    final detail = _detailController.text.trim();
    if (confirmed != true || repo.isEmpty) return;
    if (!context.mounted) return;

    try {
      if (release) {
        await widget.webUIStorage.installFromGitHubRelease(
          repo,
          assetName: detail.isEmpty ? null : detail,
        );
      } else {
        await widget.webUIStorage.installFromGitHub(
          repo,
          branch: detail.isEmpty ? 'main' : detail,
        );
      }

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Skin installed from GitHub'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to install skin: $e')));
      }
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickLiveEditFolder(BuildContext context) async {
    final selectedDirectory = await FilePicker.getDirectoryPath();

    if (selectedDirectory != null) {
      if (Platform.isIOS) {
        await SecurityScopedFileService.startAccessing(selectedDirectory);
      }
      final indexFile = File('$selectedDirectory/index.html');
      final itExists = await indexFile.exists();

      if (itExists) {
        await widget.webUIService.serveFolderAtPath(selectedDirectory);
        setState(() {});

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Expanded(child: Text('Live-editing from $selectedDirectory')),
                  ShadButton.outline(
                    onPressed: () async {
                      await _openWebUIInBrowser();
                    },
                    child: const Text("Open"),
                  ),
                ],
              ),
            ),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('index.html not found in selected folder'),
            ),
          );
        }
        setState(() => _selectedSkinId = widget.webUIStorage.defaultSkin?.id);
      }
    } else {
      setState(() => _selectedSkinId = widget.webUIStorage.defaultSkin?.id);
    }
  }

  Future<bool> _openWebUIInBrowser() async {
    return await launchUrl(
      Uri.parse(
        'http://localhost:3000?_=${DateTime.now().millisecondsSinceEpoch}',
      ),
    );
  }

  Future<void> _goToSkin() async {
    if (!widget.webUIService.isServing) {
      await _startSelectedSkin();
    }
    if (!widget.webUIService.isServing) return;
    if (!mounted) return;

    if (Platform.isLinux) {
      await _openWebUIInBrowser();
    } else {
      await Navigator.of(context).pushNamed(SkinView.routeName);
    }
  }

  Future<void> _checkForSkinUpdates(BuildContext context) async {
    try {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Checking for skin updates...')),
      );

      await widget.webUIStorage.updateAllSkins();

      if (mounted) setState(() {});

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Skin updates completed'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e, stackTrace) {
      _log.severe('Error checking for skin updates', e, stackTrace);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to check for skin updates: $e')),
      );
    }
  }
}

enum _ActionButtonVariant { primary, outline, ghost }

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final _ActionButtonVariant variant;
  final ShadButtonSize? size;

  final Color? foregroundColor;

  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.variant = _ActionButtonVariant.primary,
    this.size,
    this.foregroundColor,
  });

  factory _ActionButton.outline({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    ShadButtonSize? size,
  }) {
    return _ActionButton(
      label: label,
      icon: icon,
      onPressed: onPressed,
      variant: _ActionButtonVariant.outline,
      size: size,
    );
  }

  factory _ActionButton.ghost({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    ShadButtonSize? size,
    Color? foregroundColor,
  }) {
    return _ActionButton(
      label: label,
      icon: icon,
      onPressed: onPressed,
      variant: _ActionButtonVariant.ghost,
      size: size,
      foregroundColor: foregroundColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final leading = Icon(icon, size: 16, color: foregroundColor);
    final child = Text(
      label,
      style: foregroundColor != null ? TextStyle(color: foregroundColor) : null,
    );

    final ShadButton button = switch (variant) {
      _ActionButtonVariant.outline => ShadButton.outline(
        leading: leading,
        onPressed: onPressed,
        size: size,
        child: child,
      ),
      _ActionButtonVariant.ghost => ShadButton.ghost(
        leading: leading,
        onPressed: onPressed,
        size: size,
        child: child,
      ),
      _ActionButtonVariant.primary => ShadButton(
        leading: leading,
        onPressed: onPressed,
        size: size,
        child: child,
      ),
    };

    return Semantics(
      button: true,
      label: label,
      child: ExcludeSemantics(child: button),
    );
  }
}
