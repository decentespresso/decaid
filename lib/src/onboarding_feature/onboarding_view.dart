import 'dart:async';

import 'package:flutter/material.dart';

import 'onboarding_controller.dart';

class OnboardingView extends StatefulWidget {
  final OnboardingController controller;
  final VoidCallback? onComplete;

  const OnboardingView({super.key, required this.controller, this.onComplete});

  static const routeName = '/onboarding';

  @override
  State<OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<OnboardingView> {
  late StreamSubscription<dynamic> _stepSub;
  late StreamSubscription<dynamic> _completeSub;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _stepSub = widget.controller.currentStepStream.listen((_) {
      if (mounted) {
        setState(() {
          _initialized = true;
        });
      }
    });
    _completeSub = widget.controller.completedStream.listen((_) {
      widget.onComplete?.call();
    });
  }

  @override
  void dispose() {
    _stepSub.cancel();
    _completeSub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return PopScope(
      canPop: false,
      child: widget.controller.currentStep.builder(widget.controller),
    );
  }
}
