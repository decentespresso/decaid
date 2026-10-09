import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class PageActionMenu extends StatefulWidget {
  const PageActionMenu({
    super.key,
    required this.tooltip,
    required this.checkingLabel,
    required this.onCheckForUpdates,
    required this.installLabel,
    required this.onInstall,
    this.enabled = true,
    this.showInstall = true,
    this.includeFolder = false,
    this.leadingAction,
  });

  final String tooltip;
  final String checkingLabel;
  final Future<void> Function()? onCheckForUpdates;
  final String installLabel;
  final ValueChanged<String>? onInstall;
  final bool enabled;
  final bool showInstall;
  final bool includeFolder;
  final Widget? leadingAction;

  @override
  State<PageActionMenu> createState() => _PageActionMenuState();
}

class _PageActionMenuState extends State<PageActionMenu> {
  bool _isCheckingUpdates = false;

  Future<void> _checkForUpdates() async {
    final checkForUpdates = widget.onCheckForUpdates;
    if (!mounted ||
        !widget.enabled ||
        _isCheckingUpdates ||
        checkForUpdates == null) {
      return;
    }
    setState(() => _isCheckingUpdates = true);
    try {
      await checkForUpdates();
    } finally {
      if (mounted) setState(() => _isCheckingUpdates = false);
    }
  }

  MenuItemButton _installSource(String action, String label) {
    return MenuItemButton(
      onPressed: () => widget.onInstall?.call(action),
      child: Text(label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryColor = ShadTheme.of(context).colorScheme.primary;
    return MenuAnchor(
      consumeOutsideTap: true,
      builder: (context, controller, child) => IconButton(
        icon: _isCheckingUpdates
            ? SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: primaryColor,
                  semanticsLabel: widget.checkingLabel,
                ),
              )
            : const Icon(LucideIcons.settings),
        iconSize: 28,
        color: primaryColor,
        tooltip: widget.tooltip,
        onPressed: widget.enabled
            ? () => controller.isOpen ? controller.close() : controller.open()
            : null,
      ),
      menuChildren: [
        if (widget.leadingAction != null) widget.leadingAction!,
        MenuItemButton(
          leadingIcon: const Icon(LucideIcons.cloudDownload),
          onPressed:
              widget.enabled &&
                  !_isCheckingUpdates &&
                  widget.onCheckForUpdates != null
              ? _checkForUpdates
              : null,
          child: const Text('Check for updates'),
        ),
        if (widget.showInstall)
          SubmenuButton(
            leadingIcon: const Icon(LucideIcons.plus),
            menuChildren: widget.enabled && widget.onInstall != null
                ? [
                    _installSource('github-release', 'GitHub Release'),
                    _installSource('github-branch', 'GitHub Branch'),
                    _installSource('zip', 'ZIP file'),
                    if (widget.includeFolder)
                      _installSource('folder', 'Folder snapshot'),
                  ]
                : const [],
            child: Text(widget.installLabel),
          ),
      ],
    );
  }
}
