import 'package:flutter/widgets.dart';
import 'package:rxdart/rxdart.dart';

typedef StepWidgetBuilder = Widget Function(OnboardingController controller);

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
  List<OnboardingStep> _activeSteps = [];
  int _currentIndex = 0;
  bool _disposed = false;

  final _currentStepSubject = BehaviorSubject<OnboardingStep>();
  final _completedSubject = PublishSubject<bool>();

  Stream<OnboardingStep> get currentStepStream => _currentStepSubject.stream;
  Stream<bool> get completedStream => _completedSubject.stream;
  OnboardingStep get currentStep => _activeSteps[_currentIndex];
  List<OnboardingStep> get activeSteps => List.unmodifiable(_activeSteps);

  OnboardingController({required List<OnboardingStep> steps})
    : _allSteps = steps;

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
      _currentStepSubject.add(_activeSteps[_currentIndex]);
    }
  }

  void advance() {
    if (_disposed) return;
    if (_currentIndex >= _activeSteps.length - 1) {
      _completedSubject.add(true);
      return;
    }
    _currentIndex++;
    _currentStepSubject.add(_activeSteps[_currentIndex]);
  }

  void dispose() {
    _disposed = true;
    _currentStepSubject.close();
    _completedSubject.close();
  }
}
