import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/security_scoped_file.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';
import 'package:reaprime/src/util/rot13.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/feedback_feature/feedback_view.dart';
import 'package:reaprime/src/import/de1app_importer.dart';
import 'package:reaprime/src/import/saf_folder_copier.dart';
import 'package:reaprime/src/import/de1app_scanner.dart';
import 'package:reaprime/src/import/import_result.dart';
import 'package:reaprime/src/import/widgets/import_progress_view.dart';
import 'package:reaprime/src/import/widgets/import_result_view.dart';
import 'package:reaprime/src/import/widgets/import_summary_view.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/settings/backup_import_response.dart';
import 'package:reaprime/src/services/webserver/data_export/backup_transfer_service.dart';
import 'package:reaprime/src/util/temp_archive_files.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/util/shot_exporter.dart';
import 'package:reaprime/src/util/shot_importer.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:share_plus/share_plus.dart';

final Logger _log = Logger("DataManagement");

Uint8List _zipFiles(Map<String, Uint8List> files) {
  final archive = Archive();
  files.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class DataManagementPage extends StatefulWidget {
  const DataManagementPage({
    super.key,
    required this.controller,
    required this.persistenceController,
    required this.de1Controller,
    required this.decentAccountService,
    this.profileStorageService,
    this.beanStorageService,
    this.grinderStorageService,
    this.workflowController,
  });

  static const routeName = '/data';

  final SettingsController controller;
  final PersistenceController persistenceController;
  final De1Controller de1Controller;
  final DecentAccountService? decentAccountService;
  final ProfileStorageService? profileStorageService;
  final BeanStorageService? beanStorageService;
  final GrinderStorageService? grinderStorageService;
  final WorkflowController? workflowController;

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage> {
  bool _progressDialogOpen = false;
  NavigatorState? _progressNavigator;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Data Management')),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          return SafeArea(
            top: false,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 16,
                children: [
                  _buildExportBackupSection(),
                  _buildImportRestoreSection(),
                  _buildPrivacyFeedbackSection(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildExportBackupSection() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_download_outlined, size: 20),
              const SizedBox(width: 8),
              Text(
                'Export & Backup',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Create backups of your data or export specific items',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ShadButton.outline(
                onPressed: _exportFullBackup,
                child: const Text('Export Full Backup'),
              ),
              ShadButton.outline(
                onPressed: _exportLogs,
                child: const Text('Export Logs'),
              ),
              ShadButton.outline(
                onPressed: _exportShots,
                child: const Text('Export Shots'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImportRestoreSection() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_upload_outlined, size: 20),
              const SizedBox(width: 8),
              Text(
                'Import & Restore',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Restore data from a previous backup',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              ShadButton.outline(
                onPressed: _importFullBackup,
                child: const Text('Import Full Backup'),
              ),
              ShadButton.outline(
                onPressed: _importLegacyShots,
                child: const Text('Import Shots (JSON)'),
              ),
              if (_canImportFromDe1app)
                ShadButton.outline(
                  onPressed: _importFromDe1app,
                  child: const Text('Import from DE1 app'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Use "Import Shots (JSON)" for legacy shot exports — single JSON files or arrays of shot records.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacyFeedbackSection() {
    return ShadCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, size: 20),
              const SizedBox(width: 8),
              Text(
                'Privacy & Feedback',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Control data sharing and send feedback',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),
          ShadSwitch(
            value: widget.controller.telemetryConsent,
            onChanged: (v) async {
              await widget.controller.setTelemetryConsent(v);
            },
            label: const Text("Anonymous crash reporting"),
            sublabel: const Text(
              "Share anonymized crash reports and diagnostics to help fix connectivity issues",
            ),
          ),
          const SizedBox(height: 12),
          ShadButton.outline(
            onPressed: () => showFeedbackDialog(
              context,
              githubToken: rot13(
                const String.fromEnvironment(
                  'GITHUB_FEEDBACK_TOKEN',
                  defaultValue: '',
                ),
              ),
              serialNumbers: () => widget.de1Controller.seenSerials,
              accountService: widget.decentAccountService,
            ),
            child: const Text("Send Feedback"),
          ),
        ],
      ),
    );
  }

  bool get _canImportFromDe1app =>
      widget.profileStorageService != null &&
      widget.beanStorageService != null &&
      widget.grinderStorageService != null;

  Future<void> _exportFullBackup() async {
    if (!mounted) return;
    _showProgressDialog(context, 'Preparing full backup...');

    final tempDir = await TempArchiveDir.create('reaprime-native-export-');
    final transfer = BackupTransferService();
    late final File zipFile;
    try {
      zipFile = await transfer.downloadExportZip(
        'http://localhost:8080/api/v1/data/export',
        tempDir.directory,
      );
    } catch (e) {
      _log.severe("Failed to export full backup", e);
      _dismissProgressDialog();
      await tempDir.dispose();
      if (mounted) {
        final message = e is BackupTransferException ? e.message : '$e';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export full backup: $message')),
        );
      }
      return;
    } finally {
      transfer.close();
    }

    if (!mounted) {
      await tempDir.dispose();
      return;
    }
    _dismissProgressDialog();

    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final fileName = 'decent_export_$timestamp.zip';

    if (Platform.isIOS || Platform.isAndroid) {
      try {
        final result = await SharePlus.instance.share(
          ShareParams(
            files: [XFile(zipFile.path, mimeType: 'application/zip')],
            subject: 'Decent backup',
          ),
        );
        if (result.status == ShareResultStatus.dismissed) {
          await tempDir.dispose();
          return;
        }
        Timer(const Duration(minutes: 5), () => tempDir.dispose());
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Full backup exported successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        _log.severe("Failed to export full backup", e);
        await tempDir.dispose();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to export full backup: $e')),
          );
        }
      }
    } else {
      try {
        final outputFile = await FilePicker.saveFile(
          fileName: fileName,
          dialogTitle: 'Choose where to save backup',
        );
        if (outputFile != null) {
          await zipFile.copy(outputFile);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Full backup exported successfully'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      } catch (e) {
        _log.severe("Failed to export full backup", e);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to export full backup: $e')),
          );
        }
      } finally {
        await tempDir.dispose();
      }
    }
  }

  Future<void> _exportLogs() async {
    if (!mounted) return;
    _showProgressDialog(context, 'Preparing logs...');

    final Uint8List zipBytes;
    try {
      final logDir = await AppDirectories.logs;
      final logFile = File('$logDir/log.txt');
      final webviewLogFile = File('$logDir/webview_console.log');

      final hasAppLog = await logFile.exists();
      final hasWebviewLog =
          await webviewLogFile.exists() && (await webviewLogFile.length()) > 0;

      if (!hasAppLog && !hasWebviewLog) {
        _dismissProgressDialog();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('No log files found')));
        }
        return;
      }

      final files = <String, Uint8List>{};
      if (hasAppLog) {
        files['log.txt'] = await logFile.readAsBytes();
      }
      if (hasWebviewLog) {
        files['webview_console.log'] = await webviewLogFile.readAsBytes();
      }
      zipBytes = await compute(_zipFiles, files);
    } catch (e) {
      _log.severe("Failed to export logs", e);
      _dismissProgressDialog();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to export logs: $e')));
      }
      return;
    }

    if (!mounted) return;
    _dismissProgressDialog();

    try {
      final outputFile = await FilePicker.saveFile(
        fileName: "R1-logs.zip",
        dialogTitle: "Choose where to save logs",
        bytes: zipBytes,
      );
      if (outputFile != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Logs exported successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      _log.severe("Failed to export logs", e);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to export logs: $e')));
      }
    }
  }

  Future<void> _exportShots() async {
    if (!mounted) return;
    _showProgressDialog(context, 'Preparing shots export...');

    final Uint8List zipBytes;
    try {
      final exporter = ShotExporter(
        storage: widget.persistenceController.storageService,
      );
      final jsonData = await exporter.exportJson();
      final jsonBytes = Uint8List.fromList(utf8.encode(jsonData));
      zipBytes = await compute(_zipFiles, {'shots.json': jsonBytes});
    } catch (e, st) {
      _log.severe("Failed to export shots", e, st);
      _dismissProgressDialog();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to export shots: $e')));
      }
      return;
    }

    if (!mounted) return;
    _dismissProgressDialog();

    try {
      final outputFile = await FilePicker.saveFile(
        fileName: "R1_shots.zip",
        dialogTitle: "Choose where to save shots",
        bytes: zipBytes,
      );
      if (outputFile != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Shots exported successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e, st) {
      _log.severe("Failed to export shots", e, st);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to export shots: $e')));
      }
    }
  }

  Future<void> _importFullBackup() async {
    final strategy = await showShadDialog<String>(
      context: context,
      builder: (context) => ShadDialog(
        title: const Text('Import Backup'),
        description: const Text(
          'Choose how to handle data that already exists',
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                ShadButton(
                  onPressed: () => Navigator.of(context).pop('skip'),
                  child: const Text('Skip existing'),
                ),
                const SizedBox(width: 8),
                ShadButton.secondary(
                  onPressed: () => Navigator.of(context).pop('overwrite'),
                  child: const Text('Overwrite existing'),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (strategy == null) return;

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withReadStream: true,
    );
    if (result == null || result.files.isEmpty) return;

    if (!mounted) return;

    _showProgressDialog(context, 'Importing backup...');

    final transfer = BackupTransferService();
    try {
      final file = result.files.first;
      final filePath = file.path;
      Stream<List<int>>? readStream = file.readStream;
      final int? length;
      if (filePath != null) {
        length = await File(filePath).length();
      } else if (readStream != null) {
        length = null;
      } else if (file.bytes != null) {
        readStream = Stream.fromIterable([file.bytes!]);
        length = file.bytes!.length;
      } else {
        throw const BackupImportException(
          'Could not access the selected file.',
        );
      }

      final importResponse = await transfer.uploadZip(
        'http://localhost:8080/api/v1/data/import',
        strategy,
        filePath: filePath,
        readStream: readStream,
        contentLength: length,
      );

      if (!mounted) return;

      Navigator.of(context).pop();

      if (!mounted) return;

      await _showImportResultDialog(importResponse);

      if (importResponse.shouldNotifyShotsChanged) {
        widget.persistenceController.notifyShotsChanged();
      }
    } on BackupImportException catch (e) {
      _log.severe("Failed to import backup", e);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      _log.severe("Failed to import backup", e);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to import backup: $e')));
      }
    } finally {
      transfer.close();
    }
  }

  Future<void> _importLegacyShots() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Select shots JSON file',
    );

    if (result == null || result.files.isEmpty) return;

    final filePath = result.files.single.path;
    if (filePath == null) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to access file')));
      }
      return;
    }

    if (!mounted) return;
    _showProgressDialog(context, 'Importing shots...');

    try {
      final importer = ShotImporter(
        storage: widget.persistenceController.storageService,
      );
      final file = File(filePath);
      final content = await file.readAsString();
      final decoded = jsonDecode(content);

      int count = 0;
      if (decoded is List) {
        count = await importer.importShotsJson(content);
      } else {
        await importer.importShotJson(content);
        count = 1;
      }

      if (!mounted) return;
      Navigator.of(context).pop();

      widget.persistenceController.notifyShotsChanged();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Successfully imported $count shot${count == 1 ? '' : 's'}',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e, st) {
      _log.severe("Legacy shot import failed", e, st);
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _importFromDe1app() async {
    String? folderPath;
    if (Platform.isAndroid) {
      final copier = SafFolderCopier();
      final picked = await copier.pickDirectory();
      if (picked == null) return;
      if (!mounted) return;

      int filesCopied = 0;
      int filesToCopy = 0;
      StateSetter? setCopyState;

      showShadDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) {
            setCopyState = setState;
            final isMilestone =
                filesToCopy == 0 ||
                filesCopied == filesToCopy ||
                (filesToCopy > 0 &&
                    filesCopied % (filesToCopy ~/ 4).clamp(1, filesToCopy) ==
                        0);
            return ShadDialog(
              title: const Text('Copying files...'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 16),
                  if (filesToCopy > 0)
                    Semantics(
                      label: 'Copying files from selected folder',
                      child: LinearProgressIndicator(
                        value: filesCopied / filesToCopy,
                      ),
                    )
                  else
                    Semantics(
                      label: 'Preparing import',
                      child: const CircularProgressIndicator(),
                    ),
                  const SizedBox(height: 8),
                  Semantics(
                    liveRegion: isMilestone,
                    child: Text(
                      filesToCopy > 0
                          ? 'Copying files... $filesCopied / $filesToCopy'
                          : 'Preparing import...',
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );

      folderPath = await copier.copyFromUri(
        picked,
        onProgress: (copied, total) {
          setCopyState?.call(() {
            filesCopied = copied;
            filesToCopy = total;
          });
        },
      );

      if (!mounted) return;
      Navigator.of(context).pop();

      if (folderPath == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No DE1 app data found')),
          );
        }
        return;
      }
    } else {
      folderPath = await FilePicker.getDirectoryPath(
        dialogTitle: 'Select the DE1 app folder',
      );
    }
    if (folderPath == null) return;

    if (Platform.isIOS) {
      await SecurityScopedFileService.startAccessing(folderPath);
    }
    if (!mounted) return;

    try {
      _showProgressDialog(context, 'Scanning folder...');

      final ScanResult scanResult;
      try {
        scanResult = await De1appScanner.scan(folderPath);
      } catch (e) {
        _log.severe('De1app scan failed', e);
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Scan failed: $e')));
        }
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pop();

      if (scanResult.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No DE1 app data found in this folder'),
            ),
          );
        }
        return;
      }

      if (!mounted) return;
      final confirmed = await showShadDialog<bool>(
        context: context,
        builder: (ctx) => ShadDialog(
          title: const Text('Import from Decent app'),
          child: ImportSummaryView(
            scanResult: scanResult,
            onImportAll: () => Navigator.of(ctx).pop(true),
            onCancel: () => Navigator.of(ctx).pop(false),
          ),
        ),
      );

      if (confirmed != true) return;
      if (!mounted) return;

      ImportResult? importResult;
      ImportProgress progress = const ImportProgress(
        current: 0,
        total: 0,
        phase: '',
      );
      int shotsImported = 0;
      int profilesImported = 0;

      StateSetter? setDialogState;

      showShadDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) {
            setDialogState = setState;
            return ShadDialog(
              title: const Text('Importing...'),
              child: ImportProgressView(
                progress: progress,
                shotsImported: shotsImported,
                profilesImported: profilesImported,
              ),
            );
          },
        ),
      );

      try {
        final importer = De1appImporter(
          storageService: widget.persistenceController.storageService,
          profileStorageService: widget.profileStorageService!,
          beanStorageService: widget.beanStorageService!,
          grinderStorageService: widget.grinderStorageService!,
          settingsController: widget.controller,
          workflowController: widget.workflowController,
        );

        importResult = await importer.import(
          scanResult,
          onProgress: (p) {
            if (!mounted) return;
            setDialogState?.call(() {
              progress = p;
              if (p.phase == 'shots') shotsImported = p.current;
              if (p.phase == 'profiles') profilesImported = p.current;
            });
          },
        );
      } catch (e) {
        _log.severe('De1app import failed', e);
        if (mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
        }
        return;
      }

      if (!mounted) return;
      Navigator.of(context).pop();

      await showShadDialog(
        context: context,
        builder: (ctx) => ShadDialog(
          title: const Text('Import Complete'),
          child: ImportResultView(
            result: importResult!,
            onContinue: () => Navigator.of(ctx).pop(),
          ),
        ),
      );

      widget.persistenceController.notifyShotsChanged();
    } finally {
      if (Platform.isAndroid) {
        await SafFolderCopier().cleanup();
      }
    }
  }

  void _showProgressDialog(BuildContext context, String message) {
    _progressNavigator = Navigator.of(context);
    _progressDialogOpen = true;
    showShadDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ShadDialog(
        title: Text(message),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 16),
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Please wait...'),
          ],
        ),
      ),
    ).then((_) => _progressDialogOpen = false);
  }

  void _dismissProgressDialog() {
    if (_progressDialogOpen && _progressNavigator != null) {
      _progressNavigator!.pop();
      _progressDialogOpen = false;
    }
  }

  Future<void> _showImportResultDialog(BackupImportResponse response) async {
    final sections = <Widget>[];

    for (final entry in response.sections.entries) {
      if (entry.value is Map<String, dynamic>) {
        final data = entry.value as Map<String, dynamic>;
        final imported = data['imported'] ?? 0;
        final skipped = data['skipped'] ?? 0;
        final errors = data['errors'] is List
            ? data['errors'] as List<dynamic>
            : const <dynamic>[];
        final warnings = data['warnings'] is List
            ? data['warnings'] as List<dynamic>
            : const <dynamic>[];

        sections.add(
          Text(
            '${entry.key}: $imported imported, $skipped skipped',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        );

        for (final error in errors) {
          sections.add(
            Text(
              '  Error: $error',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          );
        }

        for (final warning in warnings) {
          sections.add(Text('  Warning: $warning'));
        }
      }
    }

    await showShadDialog(
      context: context,
      builder: (context) => ShadDialog(
        title: Text(backupImportDialogTitle(response.status)),
        actions: [
          ShadButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [const SizedBox(height: 8), ...sections],
        ),
      ),
    );
  }
}
