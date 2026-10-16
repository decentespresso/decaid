import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> openShotUploadSupport() async {
  try {
    await launchUrl(
      Uri.parse('https://decentespresso.com/support/'),
      mode: LaunchMode.externalApplication,
    );
  } catch (error, stackTrace) {
    Logger(
      'ShotUploadNotifications',
    ).warning('Could not open Decent support', error, stackTrace);
  }
}

class ShotUploadNotifications extends StatefulWidget {
  const ShotUploadNotifications({
    super.key,
    required this.events,
    required this.onSignIn,
    required this.onSupport,
    required this.refreshOwnership,
    this.refreshAccount,
    required this.child,
  });

  final Stream<Map<String, dynamic>> events;
  final VoidCallback onSignIn;
  final VoidCallback onSupport;
  final VoidCallback refreshOwnership;
  final Future<void> Function()? refreshAccount;
  final Widget child;

  @override
  State<ShotUploadNotifications> createState() =>
      _ShotUploadNotificationsState();
}

class _ShotUploadNotificationsState extends State<ShotUploadNotifications>
    with WidgetsBindingObserver {
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  bool _refreshOnReturn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = widget.events.listen(_onEvent);
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['pluginId'] != 'shot-upload.reaplugin' ||
        event['event'] != 'uploadPaused') {
      return;
    }
    final payload = event['payload'];
    if (payload is! Map) return;
    final authentication = payload['reason'] == 'authentication';
    final serial = payload['serialNumber'];
    if (!authentication &&
        (payload['reason'] != 'unlinked_serial' ||
            serial is! String ||
            serial.isEmpty ||
            serial.length > 128)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            authentication
                ? 'Shot uploads are paused. Please sign in to your Decent account again.'
                : "Shot uploads are paused: your machine (serial $serial) isn't linked to your Decent account yet. Your shots will upload automatically once the machine is linked and ownership is checked again.",
          ),
          duration: const Duration(seconds: 15),
          showCloseIcon: true,
          action: SnackBarAction(
            label: authentication ? 'Sign In' : 'Support',
            onPressed: authentication
                ? widget.onSignIn
                : () {
                    _refreshOnReturn = true;
                    widget.onSupport();
                  },
          ),
        ),
      );
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _refreshOnReturn) {
      _refreshOnReturn = false;
      unawaited(_refreshAccount());
    }
  }

  Future<void> _refreshAccount() async {
    try {
      widget.refreshOwnership();
      await widget.refreshAccount?.call();
    } catch (error, stackTrace) {
      Logger(
        'ShotUploadNotifications',
      ).warning('Account machine refresh failed', error, stackTrace);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
