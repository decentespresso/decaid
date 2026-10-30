import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/util/remote_error.dart';

class UpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;
  final String currentVersion;
  final Future<String> Function(UpdateInfo, void Function(double)) onDownload;
  final Future<bool> Function(String) onInstall;
  final VoidCallback onViewReleaseNotes;

  const UpdateDialog({
    super.key,
    required this.updateInfo,
    required this.currentVersion,
    required this.onDownload,
    required this.onInstall,
    required this.onViewReleaseNotes,
  });

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  bool _isInstalling = false;
  String? _downloadedPath;
  String? _error;
  double? _downloadProgress;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Update Available'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Version ${widget.updateInfo.version}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SizedBox(height: 8),
            Text(
              'Current version: ${widget.currentVersion}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (widget.updateInfo.isPrerelease) ...[
              SizedBox(height: 8),
              Chip(
                label: Text('Pre-release'),
                backgroundColor: Colors.orange.withValues(alpha: 0.2),
              ),
            ],
            SizedBox(height: 16),
            TextButton.icon(
              onPressed: widget.onViewReleaseNotes,
              icon: const Icon(Icons.open_in_new),
              label: const Text("What's new"),
            ),
            if (_error != null) ...[
              SizedBox(height: 16),
              Container(
                padding: EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_error!, style: TextStyle(color: Colors.red)),
              ),
            ],
            if (_isDownloading) ...[
              SizedBox(height: 16),
              LinearProgressIndicator(value: _downloadProgress),
              SizedBox(height: 8),
              Text(
                _downloadProgress == null
                    ? 'Downloading update…'
                    : 'Downloading update… ${(_downloadProgress! * 100).round()}%',
              ),
            ],
            if (_isInstalling) ...[
              SizedBox(height: 16),
              LinearProgressIndicator(),
              SizedBox(height: 8),
              Text('Installing update...'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isDownloading || _isInstalling
              ? null
              : () => Navigator.of(context).pop(),
          child: Text('Cancel'),
        ),
        if (_downloadedPath == null)
          ElevatedButton(
            onPressed: _isDownloading ? null : _handleDownload,
            child: Text(_error == null ? 'Download' : 'Retry'),
          )
        else
          ElevatedButton(
            onPressed: _isInstalling ? null : _handleInstall,
            child: Text(_error == null ? 'Install' : 'Retry'),
          ),
      ],
    );
  }

  Future<void> _handleDownload() async {
    if (!mounted || _isDownloading || _isInstalling) return;
    setState(() {
      _isDownloading = true;
      _error = null;
      _downloadProgress = null;
    });

    try {
      final path = await widget.onDownload(widget.updateInfo, (progress) {
        if (mounted) setState(() => _downloadProgress = progress);
      });
      if (!mounted) return;
      setState(() {
        _downloadedPath = path;
        _isDownloading = false;
      });
    } catch (e, st) {
      Logger('UpdateDialog').warning('App update download failed', e, st);
      if (!mounted) return;
      setState(() {
        _error = remoteErrorMessage(e, action: 'download the app update');
        _isDownloading = false;
      });
    }
  }

  Future<void> _handleInstall() async {
    if (!mounted ||
        _downloadedPath == null ||
        _isDownloading ||
        _isInstalling) {
      return;
    }

    setState(() {
      _isInstalling = true;
      _error = null;
    });

    try {
      final success = await widget.onInstall(_downloadedPath!);
      if (!mounted) return;
      if (success) {
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Update installation started. Please follow the on-screen prompts.',
              ),
            ),
          );
        }
      } else {
        setState(() {
          _error =
              'Installation permission required. Please grant permission and try again.';
          _isInstalling = false;
        });
      }
    } catch (e, st) {
      Logger('UpdateDialog').warning('App update installation failed', e, st);
      if (!mounted) return;
      setState(() {
        _error = remoteErrorMessage(e, action: 'install the app update');
        _isInstalling = false;
      });
    }
  }
}

class AndroidQuickUpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;
  final Future<String> Function(UpdateInfo, void Function(double)) onDownload;
  final Future<bool> Function(String) onInstall;

  const AndroidQuickUpdateDialog({
    super.key,
    required this.updateInfo,
    required this.onDownload,
    required this.onInstall,
  });

  @override
  State<AndroidQuickUpdateDialog> createState() =>
      _AndroidQuickUpdateDialogState();
}

class _AndroidQuickUpdateDialogState extends State<AndroidQuickUpdateDialog> {
  bool _isDownloading = true;
  bool _isInstalling = false;
  String? _error;
  double? _downloadProgress;
  bool _inProgress = false;
  String? _downloadedPath;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    if (!mounted || _inProgress) return;
    _inProgress = true;
    var action = 'download the app update';
    try {
      final path =
          _downloadedPath ??
          await widget.onDownload(widget.updateInfo, (progress) {
            if (mounted) setState(() => _downloadProgress = progress);
          });
      if (!mounted) return;
      _downloadedPath = path;
      setState(() {
        _isDownloading = false;
        _isInstalling = true;
      });
      action = 'install the app update';
      final success = await widget.onInstall(path);
      if (!mounted) return;
      if (success) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Update installation started. Follow the on-screen prompts.',
            ),
          ),
        );
      } else {
        setState(() {
          _isInstalling = false;
          _error =
              'Install permission required. Grant permission and try again.';
        });
      }
    } catch (e, st) {
      Logger('AndroidQuickUpdateDialog').warning('App update failed', e, st);
      if (!mounted) return;
      setState(() {
        _error = remoteErrorMessage(e, action: action);
        _isDownloading = false;
        _isInstalling = false;
      });
    } finally {
      _inProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Update ${widget.updateInfo.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isDownloading) ...[
            LinearProgressIndicator(value: _downloadProgress),
            const SizedBox(height: 12),
            Text(
              _downloadProgress == null
                  ? 'Downloading update…'
                  : 'Downloading update… ${(_downloadProgress! * 100).round()}%',
            ),
          ],
          if (_isInstalling) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            const Text('Installing update…'),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isDownloading ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (_error != null)
          ElevatedButton(
            onPressed: () {
              setState(() {
                _error = null;
                _isDownloading = true;
                _downloadProgress = null;
              });
              _startDownload();
            },
            child: const Text('Retry'),
          ),
      ],
    );
  }
}
