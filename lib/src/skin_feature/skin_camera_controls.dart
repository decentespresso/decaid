import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaprime/src/skin_feature/skin_camera_permission.dart';

Future<bool?> promptForSkinCamera(BuildContext context, String skinName) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Camera access'),
      content: Text('Allow "$skinName" to receive images from your camera?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Deny'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  final result = navigator.push(route);
  final timer = Timer(const Duration(seconds: 30), () {
    if (navigator.mounted && route.isActive) navigator.removeRoute(route);
  });
  return result.whenComplete(timer.cancel);
}

class SkinCameraConsentSetting extends StatefulWidget {
  final String skinId;
  final SkinCameraConsentStore store;

  const SkinCameraConsentSetting({
    super.key,
    required this.skinId,
    this.store = const SkinCameraConsentStore(),
  });

  @override
  State<SkinCameraConsentSetting> createState() =>
      _SkinCameraConsentSettingState();
}

class _SkinCameraConsentSettingState extends State<SkinCameraConsentSetting> {
  late Future<bool?> _decision = widget.store.read(widget.skinId);
  bool _saving = false;

  @override
  void didUpdateWidget(covariant SkinCameraConsentSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.skinId != widget.skinId || oldWidget.store != widget.store) {
      _decision = widget.store.read(widget.skinId);
    }
  }

  Future<void> _save(String? value) async {
    if (value == null) return;
    final id = widget.skinId;
    setState(() => _saving = true);
    try {
      await widget.store.write(id, switch (value) {
        'allow' => true,
        'deny' => false,
        _ => null,
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Camera permission could not be saved.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _decision = widget.store.read(widget.skinId);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool?>(
    future: _decision,
    builder: (context, snapshot) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.camera_alt_outlined, size: 20),
            const SizedBox(width: 8),
            const Expanded(child: Text('Camera access')),
            DropdownButton<String>(
              value: switch (snapshot.data) {
                true => 'allow',
                false => 'deny',
                null => 'ask',
              },
              onChanged:
                  _saving ||
                      snapshot.hasError ||
                      snapshot.connectionState != ConnectionState.done
                  ? null
                  : _save,
              items: const [
                DropdownMenuItem(value: 'ask', child: Text('Ask')),
                DropdownMenuItem(value: 'allow', child: Text('Allow')),
                DropdownMenuItem(value: 'deny', child: Text('Deny')),
              ],
            ),
          ],
        ),
        if (snapshot.hasError)
          const Text('Camera permission could not be loaded.'),
      ],
    ),
  );
}
