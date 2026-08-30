import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/feedback_controller.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:url_launcher/url_launcher.dart';

const _maxScreenshots = 2;

void showFeedbackDialog(
  BuildContext context, {
  required String githubToken,
  required List<String> Function() serialNumbers,
  required DecentAccountService? accountService,
}) {
  showShadDialog(
    context: context,
    builder: (context) => FeedbackDialog(
      githubToken: githubToken,
      serialNumbers: serialNumbers,
      accountService: accountService,
    ),
  );
}

class FeedbackDialog extends StatefulWidget {
  final String githubToken;
  final List<String> Function() serialNumbers;
  final DecentAccountService? accountService;

  const FeedbackDialog({
    super.key,
    required this.githubToken,
    required this.serialNumbers,
    required this.accountService,
  });

  @override
  State<FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<FeedbackDialog> {
  final TextEditingController _descriptionController = TextEditingController();
  late final FeedbackController _controller;
  late final FeedbackService _service;

  FeedbackType _selectedType = FeedbackType.bug;
  bool _includeLogs = true;
  bool _includeSystemInfo = true;
  final List<Uint8List> _screenshots = [];
  String? _validationMessage;
  FeedbackRequest? _lastRequest;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _service = FeedbackService(
      githubToken: widget.githubToken,
      currentSerialNumbers: widget.serialNumbers,
      accountService: widget.accountService,
    );
    _controller = FeedbackController(service: _service);
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pickScreenshots() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (result == null) return;

    for (final file in result.files) {
      if (_screenshots.length >= _maxScreenshots) break;
      final bytes =
          file.bytes ??
          (file.path != null ? await _readFile(file.path!) : null);
      if (bytes != null) {
        setState(() => _screenshots.add(bytes));
      }
    }
  }

  Future<Uint8List?> _readFile(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> _submit() async {
    setState(() => _validationMessage = null);

    if (_descriptionController.text.trim().isEmpty) {
      setState(() => _validationMessage = 'Please enter a description.');
      return;
    }

    if (!_controller.isConfigured) {
      setState(
        () => _validationMessage =
            'Feedback is not configured. Build with --dart-define=GITHUB_FEEDBACK_TOKEN=<token>.',
      );
      return;
    }

    final request = FeedbackRequest(
      description: _descriptionController.text.trim(),
      type: _selectedType,
      includeLogs: _includeLogs,
      includeSystemInfo: _includeSystemInfo,
      screenshots: _screenshots,
    );
    _lastRequest = request;

    await _controller.submitFeedback(request);
  }

  Future<void> _exportAsHtml() async {
    final request = _lastRequest;
    if (request == null) return;

    setState(() => _exporting = true);
    try {
      final html = await _service.generateHtmlReport(request);
      final bytes = utf8.encode(html);
      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final fileName = 'feedback_report_$timestamp.html';

      final result = await FilePicker.saveFile(
        dialogTitle: 'Save Feedback Report',
        fileName: fileName,
        bytes: Uint8List.fromList(bytes),
      );

      if (result != null && mounted) {
        setState(() => _validationMessage = 'Report saved to: $result');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _validationMessage = 'Failed to export report: $e');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ShadDialog(
      title: const Text('Send Feedback'),
      description: const Text(
        'Feedback will be submitted as a public GitHub issue. When a Decent '
        'account is linked, Decent Support receives the issue link, and a '
        'support contact ID associated with that account is added to the '
        'public issue.',
      ),
      actions: _buildActions(context),
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (_controller.state == FeedbackState.success) {
      return _buildSuccessContent(context);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        if (_validationMessage != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withAlpha(80),
              ),
            ),
            child: Text(
              _validationMessage!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          'Type',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
        ShadSelect<FeedbackType>(
          initialValue: _selectedType,
          enabled: !_controller.isSubmitting,
          onChanged: (value) {
            if (value != null) {
              setState(() => _selectedType = value);
            }
          },
          selectedOptionBuilder: (context, value) => Text(value.displayName),
          options: FeedbackType.values
              .map(
                (type) =>
                    ShadOption(value: type, child: Text(type.displayName)),
              )
              .toList(),
          placeholder: const Text('Select type...'),
        ),
        const SizedBox(height: 12),
        Text(
          'Description',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 4),
        ShadInput(
          controller: _descriptionController,
          placeholder: const Text('Describe your feedback...'),
          maxLines: 5,
          minLines: 3,
          enabled: !_controller.isSubmitting,
        ),
        const SizedBox(height: 12),
        ShadSwitch(
          value: _includeLogs,
          onChanged: _controller.isSubmitting
              ? null
              : (v) => setState(() => _includeLogs = v),
          label: const Text('Include application logs'),
          sublabel: const Text('Logs will be uploaded as a private Gist'),
        ),
        const SizedBox(height: 8),
        ShadSwitch(
          value: _includeSystemInfo,
          onChanged: _controller.isSubmitting
              ? null
              : (v) => setState(() => _includeSystemInfo = v),
          label: const Text('Include system information'),
          sublabel: const Text('App version, platform, and OS version'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                'Screenshots (${_screenshots.length}/$_maxScreenshots)',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            if (_screenshots.length < _maxScreenshots)
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: _controller.isSubmitting ? null : _pickScreenshots,
                child: const Text('Attach'),
              ),
          ],
        ),
        if (_screenshots.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              for (int i = 0; i < _screenshots.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        _screenshots[i],
                        width: 100,
                        height: 100,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: GestureDetector(
                        onTap: _controller.isSubmitting
                            ? null
                            : () => setState(() => _screenshots.removeAt(i)),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.all(2),
                          child: const Icon(
                            Icons.close,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ],
        if (_controller.state == FeedbackState.error &&
            _controller.lastResult?.errorMessage != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _controller.lastResult!.errorMessage!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(height: 8),
          ShadButton.outline(
            size: ShadButtonSize.sm,
            onPressed: _exporting ? null : _exportAsHtml,
            child: _exporting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Export as HTML instead'),
          ),
        ],
      ],
    );
  }

  Widget _buildSuccessContent(BuildContext context) {
    final result = _controller.lastResult!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Icon(Icons.check_circle, color: Colors.green, size: 48),
        const SizedBox(height: 16),
        Text(
          'Feedback submitted!',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Issue #${result.issueNumber}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        if (result.issueUrl != null)
          ShadButton.outline(
            onPressed: () async {
              await launchUrl(Uri.parse(result.issueUrl!));
            },
            child: const Text('View on GitHub'),
          ),
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    if (_controller.state == FeedbackState.success) {
      return [
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ];
    }

    return [
      ShadButton.outline(
        onPressed: _controller.isSubmitting
            ? null
            : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      ShadButton(
        onPressed: _controller.isSubmitting ? null : _submit,
        child: _controller.isSubmitting
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Submit'),
      ),
    ];
  }
}
