import 'package:flutter/widgets.dart';

Rect shareOriginFor(BuildContext context) {
  if (!context.mounted) {
    throw StateError('The share action must still be mounted.');
  }
  final renderBox = context.findRenderObject();
  if (renderBox is! RenderBox || !renderBox.hasSize) {
    throw StateError('The share action must have rendered bounds.');
  }
  final view = View.of(context);
  final viewBounds = Offset.zero & (view.physicalSize / view.devicePixelRatio);
  final origin = (renderBox.localToGlobal(Offset.zero) & renderBox.size)
      .intersect(viewBounds);
  if (!origin.isFinite || origin.isEmpty) {
    throw StateError('The share action must be visible within the view.');
  }
  return origin;
}
