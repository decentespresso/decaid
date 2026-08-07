import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:logging/logging.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

const _maxPluginSafDepth = 32;
const _maxPluginSafEntries = 10000;

// Parses an input string into the value for a setting schema type.
dynamic parseValue(String value, String type) {
  if (type == 'number') {
    return num.tryParse(value);
  }
  if (type == 'boolean') {
    return switch (value.trim().toLowerCase()) {
      'true' => true,
      'false' => false,
      _ => null,
    };
  }
  return value;
}

/// Dialog-local draft for a secure setting input.
///
/// The editable text is kept separate from the stored credential state so
/// that typing (or erasing) never touches the credential until Save. Only the
/// explicit clear action marks the credential for deletion.
class _SecureDraft {
  _SecureDraft({required this.originalIsSet, this.type});

  final bool originalIsSet;
  final String? type;
  String text = '';
  bool clearRequested = false;
}

class _PluginSafCopyState {
  final visitedDirectoryUris = <String>{};
  int entriesSeen = 0;
}

Future<void> copyPluginDirectoryFromSaf(
  String sourceUri,
  Directory destination,
) => _copyPluginDirectoryFromSaf(
  sourceUri,
  destination,
  0,
  _PluginSafCopyState(),
);

Future<void> _copyPluginDirectoryFromSaf(
  String sourceUri,
  Directory destination,
  int depth,
  _PluginSafCopyState state,
) async {
  if (depth > _maxPluginSafDepth) {
    throw const FormatException('Plugin directory exceeds maximum depth');
  }
  if (!state.visitedDirectoryUris.add(sourceUri)) {
    throw FormatException('Plugin contains repeated directory URI: $sourceUri');
  }

  final entries = await SafUtil().list(sourceUri);
  state.entriesSeen += entries.length;
  if (state.entriesSeen > _maxPluginSafEntries) {
    throw const FormatException('Plugin contains too many entries');
  }

  await destination.create(recursive: true);
  for (final entry in entries) {
    if (entry.name == '.' ||
        entry.name == '..' ||
        entry.name.contains('/') ||
        entry.name.contains(r'\')) {
      throw FormatException('Invalid plugin entry name: ${entry.name}');
    }
    final destinationPath = '${destination.path}/${entry.name}';
    if (entry.isDir) {
      await _copyPluginDirectoryFromSaf(
        entry.uri,
        Directory(destinationPath),
        depth + 1,
        state,
      );
    } else {
      await SafStream().copyToLocalFile(entry.uri, destinationPath);
    }
  }
}

// Plugins list and settings
// Shows a list of all available plugins,
// has an icon indicating which plugin is currently loaded (on the list)
// has an icon to edit plugin settings - which opens a new dialog for editing
// lists permissions for each plugin, as well as other details such as author, plugin name, version
// also has buttons for adding/installing a plugin as well as removing a specific plugin
class PluginsSettingsView extends StatefulWidget {
  const PluginsSettingsView({
    super.key,
    required this.pluginLoaderService,
    this.allowInstall = true,
  });

  static const routeName = '/plugins';

  final PluginLoaderService pluginLoaderService;
  final bool allowInstall;

  @override
  State<PluginsSettingsView> createState() => _PluginsSettingsViewState();
}

class _PluginsSettingsViewState extends State<PluginsSettingsView> {
  List<PluginManifest> _plugins = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPlugins();
  }

  Future<void> _loadPlugins() async {
    setState(() {
      _isLoading = true;
    });

    final plugins = widget.pluginLoaderService.availablePlugins;

    setState(() {
      _plugins = plugins;
      _isLoading = false;
    });
  }

  void _refreshPlugins() {
    _loadPlugins();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plugins'),
        actions: [
          IconButton(
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: _refreshPlugins,
            tooltip: 'Refresh Plugins',
          ),
          if (widget.allowInstall)
            IconButton(
              icon: const Icon(LucideIcons.plus),
              onPressed: () => _installPlugin(context),
              tooltip: 'Install Plugin',
            ),
        ],
      ),
      body: _buildPluginList(),
    );
  }

  Widget _buildPluginList() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_plugins.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(LucideIcons.puzzle, size: 64),
            const SizedBox(height: 16),
            const Text('No plugins installed', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              'Click the + button to install a plugin',
              style: TextStyle(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _plugins.length,
      itemBuilder: (context, index) {
        final plugin = _plugins[index];
        final isLoaded = widget.pluginLoaderService.isPluginLoaded(plugin.id);
        return _buildPluginCard(context, plugin, isLoaded);
      },
    );
  }

  Widget _buildPluginCard(
    BuildContext context,
    PluginManifest plugin,
    bool isLoaded,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plugin.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'by ${plugin.author} • v${plugin.version}',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                      Text(
                        plugin.description,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    Icon(
                      isLoaded ? LucideIcons.check : LucideIcons.circle,
                      color: isLoaded ? Colors.green : Colors.grey,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<String>(
                      icon: Icon(LucideIcons.ellipsisVertical),
                      onSelected: (value) =>
                          _handlePluginAction(context, value, plugin.id),
                      itemBuilder: (context) => [
                        PopupMenuItem<String>(
                          value: isLoaded ? 'unload' : 'load',
                          child: Text(isLoaded ? 'Unload' : 'Load'),
                        ),
                        const PopupMenuItem<String>(
                          value: 'settings',
                          child: Text('Settings'),
                        ),
                        const PopupMenuItem<String>(
                          value: 'reload',
                          child: Text('Reload'),
                        ),
                        const PopupMenuItem<String>(
                          value: 'remove',
                          child: Text(
                            'Remove',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (plugin.permissions.isNotEmpty)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Permissions:',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: plugin.permissions
                        .map(
                          (permission) => Chip(
                            label: Text(permission.wireName),
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.tertiary,
                            labelStyle: Theme.of(context).textTheme.labelSmall,
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            FutureBuilder<bool>(
              future: widget.pluginLoaderService.shouldAutoLoad(plugin.id),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox.shrink();
                }
                final shouldAutoLoad = snapshot.data ?? false;
                return Row(
                  children: [
                    ShadSwitch(
                      value: shouldAutoLoad,
                      onChanged: (value) async {
                        try {
                          await widget.pluginLoaderService.setPluginAutoLoad(
                            plugin.id,
                            value,
                          );
                          if (context.mounted == false) {
                            return;
                          }
                          _showSnackBar(
                            context,
                            value
                                ? 'Plugin will auto-load on startup'
                                : 'Plugin will not auto-load on startup',
                          );
                          setState(() {});
                        } catch (e, st) {
                          Logger(
                            'PluginsSettingsView',
                          ).warning('Failed to set auto-load', e, st);
                          if (mounted) {
                            _showSnackBar(
                              context,
                              'Failed to set auto-load: $e',
                              isError: true,
                            );
                          }
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    const Text('Auto-load on startup'),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ShadButton.secondary(
                  onPressed: () => _handlePluginAction(
                    context,
                    isLoaded ? 'unload' : 'load',
                    plugin.id,
                  ),
                  child: Text(isLoaded ? 'Unload' : 'Load'),
                ),
                const SizedBox(width: 8),
                ShadButton(
                  onPressed: () =>
                      _handlePluginAction(context, 'settings', plugin.id),
                  child: const Text('Settings'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handlePluginAction(
    BuildContext context,
    String action,
    String pluginId,
  ) async {
    final logger = Logger('PluginsSettingsView');
    try {
      switch (action) {
        case 'load':
          await widget.pluginLoaderService.loadPlugin(pluginId);
          if (context.mounted) {
            _showSnackBar(context, 'Plugin loaded successfully');
          }
          _refreshPlugins();
          break;
        case 'unload':
          await widget.pluginLoaderService.unloadPlugin(pluginId);
          if (context.mounted) {
            _showSnackBar(context, 'Plugin unloaded');
          }
          _refreshPlugins();
          break;
        case 'reload':
          await widget.pluginLoaderService.reloadPlugin(pluginId);
          if (context.mounted) {
            _showSnackBar(context, 'Plugin reloaded');
          }
          _refreshPlugins();
          break;
        case 'settings':
          await _showPluginSettings(context, pluginId);
          break;
        case 'remove':
          await _confirmRemovePlugin(context, pluginId);
          break;
      }
    } catch (e, st) {
      logger.warning('Failed to $action plugin $pluginId', e, st);
      if (context.mounted) {
        _showSnackBar(context, 'Failed to $action plugin: $e', isError: true);
      }
    }
  }

  // TODO: unify with PluginLoaderService _copyDirectoryRecursively - maybe as a Directory extension?
  Future<void> _copyDirectoryRecursively(
    Directory source,
    Directory destination,
  ) async {
    if (!destination.existsSync()) {
      destination.createSync(recursive: true);
    }

    final entries = source.listSync(recursive: false);

    for (final entry in entries) {
      final newPath = '${destination.path}/${entry.path.split('/').last}';

      if (entry is File) {
        await entry.copy(newPath);
      } else if (entry is Directory) {
        final newDir = Directory(newPath);
        await _copyDirectoryRecursively(entry, newDir);
      }
    }
  }

  Future<void> _installPlugin(BuildContext context) async {
    final logger = Logger('PluginsSettingsView');
    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp();
      if (Platform.isAndroid) {
        final selected = await SafUtil().pickDirectory(
          writePermission: false,
          persistablePermission: false,
        );
        if (selected == null) return;
        if (!selected.name.endsWith('.reaplugin')) {
          throw Exception('selection is not a .reaplugin');
        }
        await copyPluginDirectoryFromSaf(selected.uri, tempDir);
      } else {
        final selected = await FilePicker.getDirectoryPath();
        if (selected == null) return;
        if (!selected.endsWith('.reaplugin')) {
          throw Exception('selection is not a .reaplugin');
        }
        await _copyDirectoryRecursively(Directory(selected), tempDir);
      }

      await widget.pluginLoaderService.addPlugin(tempDir.path);

      if (context.mounted) {
        _showSnackBar(context, 'Plugin installed successfully');
      }
      _refreshPlugins();
    } catch (e, st) {
      logger.warning('Failed to install plugin', e, st);
      if (context.mounted) {
        _showSnackBar(context, 'Failed to install plugin: $e', isError: true);
      }
    } finally {
      try {
        if (await tempDir?.exists() ?? false) {
          await tempDir!.delete(recursive: true);
        }
      } catch (e, st) {
        logger.warning('Failed to clean up plugin staging directory', e, st);
      }
    }
  }

  Future<void> _confirmRemovePlugin(
    BuildContext context,
    String pluginId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Plugin'),
        content: Text('Are you sure you want to remove plugin "$pluginId"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await widget.pluginLoaderService.removePlugin(pluginId);
        if (context.mounted) {
          _showSnackBar(context, 'Plugin removed successfully');
        }
        _refreshPlugins();
      } catch (e, st) {
        Logger('PluginsSettingsView').warning('Failed to remove plugin', e, st);
        if (context.mounted) {
          _showSnackBar(context, 'Failed to remove plugin: $e', isError: true);
        }
      }
    }
  }

  Future<void> _showPluginSettings(
    BuildContext context,
    String pluginId,
  ) async {
    final manifest = widget.pluginLoaderService.getPluginManifest(pluginId);
    if (manifest == null) return;

    final settings = await widget.pluginLoaderService.pluginSettings(pluginId);
    final settingsSchema = manifest.settings;

    if (settingsSchema.isEmpty) {
      if (context.mounted) {
        _showSnackBar(context, 'This plugin has no configurable settings');
      }
      return;
    }

    final Map<String, dynamic> newSettings = Map.from(settings);
    if (context.mounted == false) {
      return;
    }

    final secureDrafts = <String, _SecureDraft>{
      for (final entry in settingsSchema.entries)
        if (entry.value is Map && entry.value['secure'] == true)
          entry.key: _SecureDraft(
            originalIsSet:
                newSettings[entry.key] is Map &&
                (newSettings[entry.key] as Map)['isSet'] == true,
            type: entry.value['type'] as String?,
          ),
    };

    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: Text('${manifest.name} Settings'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: settingsSchema.entries.map((entry) {
                  final key = entry.key;
                  final schema = entry.value;
                  final currentValue = newSettings[key];
                  final defaultValue = schema['default'];
                  final secureDraft = secureDrafts[key];
                  final secureValueIsSet =
                      secureDraft != null &&
                      secureDraft.originalIsSet &&
                      secureDraft.text.isEmpty &&
                      !secureDraft.clearRequested;

                  String getDisplayValue(dynamic value) {
                    if (value == null) return '';
                    return value.toString();
                  }

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          key,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                        if (schema['description'] != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              schema['description']!,
                              style: TextStyle(
                                color: Colors.grey[600],
                                fontSize: 12,
                              ),
                            ),
                          ),
                        const SizedBox(height: 4),
                        if (schema['secure'] == true)
                          ShadInput(
                            placeholder: Text(
                              secureValueIsSet
                                  ? 'Value saved'
                                  : 'Enter secure value...',
                            ),
                            initialValue: '',
                            keyboardType: schema['type'] == 'number'
                                ? TextInputType.number
                                : null,
                            onChanged: (value) {
                              setState(() {
                                secureDrafts[key]!.text = value;
                                secureDrafts[key]!.clearRequested = false;
                              });
                            },
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            enableIMEPersonalizedLearning: false,
                            trailing: secureValueIsSet
                                ? IconButton(
                                    icon: const Icon(
                                      LucideIcons.trash2,
                                      size: 18,
                                    ),
                                    tooltip: 'Clear saved value',
                                    onPressed: () {
                                      setState(() {
                                        secureDrafts[key]!.clearRequested =
                                            true;
                                        secureDrafts[key]!.text = '';
                                      });
                                    },
                                  )
                                : null,
                          )
                        else if (schema['type'] == 'boolean')
                          Row(
                            children: [
                              ShadSwitch(
                                value: currentValue ?? defaultValue ?? false,
                                onChanged: (value) {
                                  setState(() {
                                    newSettings[key] = value;
                                  });
                                },
                              ),
                              const SizedBox(width: 8),
                              Text(
                                currentValue ?? defaultValue ?? false
                                    ? 'Enabled'
                                    : 'Disabled',
                                style: const TextStyle(fontSize: 14),
                              ),
                            ],
                          )
                        else if (schema['type'] == 'number')
                          ShadInput(
                            placeholder: Text('Enter a number...'),
                            initialValue: getDisplayValue(
                              currentValue ?? defaultValue,
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (value) {
                              final parsedValue = parseValue(value, 'number');
                              if (parsedValue != null) {
                                setState(() {
                                  newSettings[key] = parsedValue;
                                });
                              }
                            },
                          )
                        else
                          ShadInput(
                            placeholder: Text('Enter value...'),
                            initialValue: getDisplayValue(
                              currentValue ?? defaultValue,
                            ),
                            onChanged: (value) {
                              setState(() {
                                newSettings[key] = value;
                              });
                            },
                          ),
                        const SizedBox(height: 4),
                        if (defaultValue != null)
                          Text(
                            'Default: ${getDisplayValue(defaultValue)}',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 11,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
            actions: [
              ShadButton.secondary(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              ShadButton(
                onPressed: () async {
                  try {
                    final outgoing = Map<String, dynamic>.from(newSettings);
                    for (final entry in secureDrafts.entries) {
                      final draft = entry.value;
                      if (draft.clearRequested) {
                        outgoing[entry.key] = null;
                      } else if (draft.text.isEmpty) {
                        outgoing[entry.key] = {'isSet': draft.originalIsSet};
                      } else {
                        outgoing[entry.key] =
                            parseValue(draft.text, draft.type ?? 'string') ??
                            {'isSet': draft.originalIsSet};
                      }
                    }
                    await widget.pluginLoaderService.savePluginSettings(
                      pluginId,
                      outgoing,
                    );
                    if (context.mounted == false) {
                      return;
                    }
                    _showSnackBar(context, 'Settings saved');
                    Navigator.pop(context);
                  } catch (e, st) {
                    Logger(
                      'PluginsSettingsView',
                    ).warning('Failed to save settings', e, st);
                    if (context.mounted) {
                      _showSnackBar(
                        context,
                        'Failed to save settings: $e',
                        isError: true,
                      );
                    }
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showSnackBar(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }
}
