import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/app_update_state.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/util/remote_error.dart';

class UpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;
  final String currentVersion;
  final UpdateCheckService service;
  final VoidCallback onViewReleaseNotes;

  const UpdateDialog({
    super.key,
    required this.updateInfo,
    required this.currentVersion,
    required this.service,
    required this.onViewReleaseNotes,
  });

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  String? _actionError;
  (String, String)? _actionRelease;
  (String, String)? _permissionRelease;
  bool _ownsInstallAttempt = false;

  @override
  void dispose() {
    if (_ownsInstallAttempt) widget.service.cancelInstallAttempt();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AppUpdateState>(
      stream: widget.service.updateState,
      initialData: widget.service.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data!;
        final checking = state.phase == AppUpdatePhase.checking;
        final downloading = state.phase == AppUpdatePhase.downloading;
        final installing =
            state.phase == AppUpdatePhase.installing &&
            !widget.service.installationStarted;
        final busy = downloading || installing;
        final update = widget.service.availableUpdate;
        final error =
            state.error ??
            (update == null ||
                    _actionRelease == (update.version, update.downloadUrl)
                ? _actionError
                : null);
        final permissionRequired =
            error == null &&
            update != null &&
            _permissionRelease == (update.version, update.downloadUrl);
        return PopScope(
          canPop: !installing,
          child: AlertDialog(
            title: Text('Update Available'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (update != null)
                    Text(
                      'Version ${update.version}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  SizedBox(height: 8),
                  Text(
                    'Current version: ${widget.currentVersion}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (update?.isPrerelease ?? false) ...[
                    SizedBox(height: 8),
                    Chip(
                      label: Text('Pre-release'),
                      backgroundColor: Colors.orange.withValues(alpha: 0.2),
                    ),
                  ],
                  SizedBox(height: 16),
                  if (update != null)
                    TextButton.icon(
                      onPressed: widget.onViewReleaseNotes,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text("What's new"),
                    )
                  else
                    const Text('This update is no longer available.'),
                  if (permissionRequired) ...[
                    SizedBox(height: 16),
                    const Text(
                      'Installation is not authorized. Allow Decaid to install apps, then retry.',
                    ),
                  ],
                  if (error != null) ...[
                    SizedBox(height: 16),
                    Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(error, style: TextStyle(color: Colors.red)),
                    ),
                  ],
                  if (downloading) ...[
                    SizedBox(height: 16),
                    LinearProgressIndicator(value: state.progress),
                    SizedBox(height: 8),
                    Text(
                      state.progress == null
                          ? 'Downloading update…'
                          : 'Downloading update… ${(state.progress! * 100).round()}%',
                    ),
                  ],
                  if (installing) ...[
                    SizedBox(height: 16),
                    LinearProgressIndicator(),
                    SizedBox(height: 8),
                    Text('Installing update...'),
                  ],
                  if (widget.service.installationStarted)
                    const Text(
                      'Update installation started. Follow the on-screen prompts.',
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: installing
                    ? null
                    : () => Navigator.of(context).pop(),
                child: Text('Cancel'),
              ),
              if (update != null && widget.service.downloadedPath == null)
                ElevatedButton(
                  onPressed: busy || checking
                      ? null
                      : () => _handleDownload(update),
                  child: Text(error == null ? 'Download' : 'Retry'),
                )
              else if (update != null && !widget.service.installationStarted)
                ElevatedButton(
                  onPressed: busy || checking
                      ? null
                      : () => _handleInstall(context, update),
                  child: Text(
                    error == null && !permissionRequired ? 'Install' : 'Retry',
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleDownload(UpdateInfo update) async {
    setState(() {
      _actionError = null;
      _permissionRelease = null;
    });
    try {
      await widget.service.downloadUpdate(update, (_) {});
    } catch (error) {
      _showActionError(error, update, action: 'download the app update');
    }
  }

  Future<void> _handleInstall(BuildContext context, UpdateInfo update) async {
    if (_ownsInstallAttempt) return;
    if (widget.service.currentState.phase == AppUpdatePhase.installing) return;
    setState(() {
      _actionError = null;
      _permissionRelease = null;
    });
    _ownsInstallAttempt = true;
    try {
      final current = widget.service.availableUpdate;
      if (current?.version != update.version ||
          current?.downloadUrl != update.downloadUrl) {
        throw StateError('The app update is no longer available');
      }
      final path = widget.service.downloadedPath;
      if (path == null) {
        throw StateError('The downloaded app update is unavailable');
      }
      final outcome = await widget.service.installUpdate(path);
      _ownsInstallAttempt = false;
      if (!context.mounted) return;
      switch (outcome) {
        case ApkInstallOutcome.installerLaunched:
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Update installation started. Please follow the on-screen prompts.',
              ),
            ),
          );
        case ApkInstallOutcome.permissionRequired:
          setState(
            () => _permissionRelease = (update.version, update.downloadUrl),
          );
        case ApkInstallOutcome.cancelled:
          setState(() {});
      }
    } catch (error) {
      _ownsInstallAttempt = false;
      _showActionError(error, update, action: 'install the app update');
    }
  }

  void _showActionError(
    Object error,
    UpdateInfo update, {
    required String action,
  }) {
    if (!mounted || widget.service.currentState.error != null) return;
    setState(() {
      _actionError = remoteErrorMessage(error, action: action);
      _actionRelease = (update.version, update.downloadUrl);
    });
  }
}

class AndroidQuickUpdateDialog extends StatefulWidget {
  final UpdateInfo updateInfo;
  final Future<String> Function(UpdateInfo, void Function(double)) onDownload;
  final Future<ApkInstallOutcome> Function(String) onInstall;

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
  bool _permissionRequired = false;

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
      final outcome = await widget.onInstall(path);
      if (!mounted) return;
      if (outcome == ApkInstallOutcome.installerLaunched) {
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
          _permissionRequired = outcome == ApkInstallOutcome.permissionRequired;
        });
      }
    } catch (e, st) {
      Logger('AndroidQuickUpdateDialog').warning('App update failed', e, st);
      if (!mounted) return;
      setState(() {
        if (e is InvalidApkException) _downloadedPath = null;
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
    return PopScope(
      canPop: !_isDownloading && !_isInstalling,
      child: AlertDialog(
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
            if (_permissionRequired)
              const Text(
                'Installation is not authorized. Allow Decaid to install apps, then retry.',
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _isDownloading || _isInstalling
                ? null
                : () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          if (_error != null || _permissionRequired)
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _error = null;
                  _permissionRequired = false;
                  _isDownloading = _downloadedPath == null;
                  _downloadProgress = null;
                });
                _startDownload();
              },
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}
