import 'dart:async';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/onboarding_feature/widgets/onboarding_scaffold.dart';
import 'package:reaprime/src/onboarding_feature/widgets/startup_discovery_recovery.dart';
import 'package:reaprime/src/services/app_startup_coordinator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../onboarding_controller.dart';

OnboardingController createStartupOnboardingController({
  required List<OnboardingStep> steps,
  required AppStartupCoordinator startupCoordinator,
}) {
  return OnboardingController(
    onStepEntered: _startupStepEntryHook(startupCoordinator),
    steps: steps
        .map(
          (step) => const {'import', 'scan'}.contains(step.id)
              ? _guardStartupStep(step, startupCoordinator)
              : step,
        )
        .toList(),
  );
}

StepEntryHook _startupStepEntryHook(AppStartupCoordinator coordinator) {
  return (step) {
    if (const {'initialization', 'import', 'scan'}.contains(step.id)) {
      unawaited(
        coordinator.ensureInitialized().catchError((
          Object error,
          StackTrace stack,
        ) {
          Logger('InitializationStep')
              .warning('Startup failed at onboarding boundary', error, stack);
        }),
      );
    }
  };
}

OnboardingStep _guardStartupStep(
  OnboardingStep step,
  AppStartupCoordinator coordinator,
) {
  return OnboardingStep(
    id: step.id,
    shouldShow: step.shouldShow,
    builder: (controller) => _InitializationStepView(
      key: ValueKey('startup-${step.id}'),
      startupCoordinator: coordinator,
      readyBuilder: (_) => step.builder(controller),
    ),
  );
}

OnboardingStep createInitializationStep({
  required AppStartupCoordinator startupCoordinator,
}) {
  final coordinator = startupCoordinator;
  return OnboardingStep(
    id: 'initialization',
    shouldShow: () async => true,
    builder: (controller) => _InitializationStepView(
      key: const ValueKey('initialization'),
      onboardingController: controller,
      startupCoordinator: coordinator,
    ),
  );
}

class _InitializationStepView extends StatefulWidget {
  final OnboardingController? onboardingController;
  final AppStartupCoordinator startupCoordinator;
  final WidgetBuilder? readyBuilder;

  const _InitializationStepView({
    super.key,
    this.onboardingController,
    required this.startupCoordinator,
    this.readyBuilder,
  });

  @override
  State<_InitializationStepView> createState() =>
      _InitializationStepViewState();
}

class _InitializationStepViewState extends State<_InitializationStepView> {
  late Future<void> _initFuture;
  bool _advanced = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initFuture = widget.startupCoordinator.ensureInitialized();
    unawaited(_observeInitialization(_initFuture));
  }

  Future<void> _observeInitialization(Future<void> future) async {
    try {
      await future;
      if (!mounted || _advanced) return;
      if (widget.readyBuilder != null) {
        setState(() => _ready = true);
        return;
      }
      final controller = widget.onboardingController!;
      if (controller.activeSteps.isEmpty ||
          controller.currentStep.id != 'initialization') {
        return;
      }
      _advanced = true;
      controller.advance();
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  void _retry() {
    setState(() {
      _initFuture = widget.startupCoordinator.retry();
    });
    unawaited(_observeInitialization(_initFuture));
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      return StartupDiscoveryRecovery(
        startupCoordinator: widget.startupCoordinator,
        child: widget.readyBuilder!(context),
      );
    }
    return OnboardingScaffold(
      semanticsLabel: 'Starting Decaid',
      body: [
        FutureBuilder<void>(
          future: _initFuture,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Column(
                spacing: 16,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text('Error: ${snapshot.error}'),
                  ),
                  TextButton(onPressed: _retry, child: const Text('Retry')),
                ],
              );
            }
            return Column(
              spacing: 16,
              children: [
                SizedBox(
                  width: 200,
                  child: Semantics(
                    label: 'Starting Decaid',
                    child: ShadProgress(),
                  ),
                ),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Decaid is starting...',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
