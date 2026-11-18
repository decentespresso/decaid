import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:rxdart/rxdart.dart';

typedef StepWidgetBuilder = Widget Function(OnboardingController controller);
typedef StepEntryHook = FutureOr<void> Function(OnboardingStep step);

class OnboardingStep {
  final String id;
  final Future<bool> Function() shouldShow;
  final StepWidgetBuilder builder;

  const OnboardingStep({
    required this.id,
    required this.shouldShow,
    required this.builder,
  });
}

class OnboardingController {
  final List<OnboardingStep> _allSteps;
  final StepEntryHook? onStepEntered;
  List<OnboardingStep> _activeSteps = [];
  int _currentIndex = 0;
  bool _disposed = false;
  bool _enteringStep = false;

  final _currentStepSubject = BehaviorSubject<OnboardingStep>();
  final _completedSubject = PublishSubject<bool>();

  Stream<OnboardingStep> get currentStepStream => _currentStepSubject.stream;
  Stream<bool> get completedStream => _completedSubject.stream;
  OnboardingStep get currentStep => _activeSteps[_currentIndex];
  List<OnboardingStep> get activeSteps => List.unmodifiable(_activeSteps);

  OnboardingController({
    required List<OnboardingStep> steps,
    this.onStepEntered,
  }) : _allSteps = steps;

  Future<void> initialize() async {
    if (_disposed) return;
    _activeSteps = [];
    for (final step in _allSteps) {
      final shouldShow = await step.shouldShow();
      if (_disposed) return;
      if (shouldShow) {
        _activeSteps.add(step);
      }
    }
    _currentIndex = 0;
    if (_activeSteps.isNotEmpty) {
      await _enterStep(0);
    }
  }

  void advance() {
    if (_disposed || _enteringStep) return;
    if (_currentIndex >= _activeSteps.length - 1) {
      _completedSubject.add(true);
      return;
    }
    unawaited(_enterStep(_currentIndex + 1));
  }

  Future<void> _enterStep(int index) async {
    _enteringStep = true;
    try {
      final step = _activeSteps[index];
      final hook = onStepEntered;
      if (hook != null) {
        final entry = hook(step);
        if (entry is Future) await entry;
      }
      if (_disposed) return;
      _currentIndex = index;
      _currentStepSubject.add(step);
    } finally {
      _enteringStep = false;
    }
  }

  void dispose() {
    _disposed = true;
    _currentStepSubject.close();
    _completedSubject.close();
  }
}
