import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Shared chrome for onboarding steps.
///
/// Centers content in a constrained column matching the launcher's visual
/// language (ShadTheme typography, generous spacing, a primary call-to-action
/// and an optional secondary action). Steps supply their own [title], [body]
/// content, and actions; the scaffold owns the layout, padding, and the
/// [Semantics] wrapper so every step is consistent and accessible.
class OnboardingScaffold extends StatelessWidget {
  const OnboardingScaffold({
    super.key,
    this.title,
    required this.semanticsLabel,
    this.body = const [],
    this.primaryAction,
    this.secondaryAction,
    this.maxWidth = 440,
  });

  /// Heading shown at the top of the step. Omit for progress/spinner steps
  /// that only need the shared chrome.
  final String? title;

  /// Accessibility label for the whole step (e.g. 'Welcome screen').
  final String semanticsLabel;

  /// Step content rendered between the title and the actions.
  final List<Widget> body;

  /// Primary call-to-action, rendered full-width below the body.
  final Widget? primaryAction;

  /// Optional secondary action rendered below the primary one.
  final Widget? secondaryAction;

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Scaffold(
      body: Semantics(
        explicitChildNodes: true,
        label: semanticsLabel,
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (title != null) ...[
                      Text(
                        title!,
                        style: theme.textTheme.h3,
                        textAlign: TextAlign.center,
                      ),
                      if (body.isNotEmpty) const SizedBox(height: 16),
                    ],
                    ...body,
                    if (primaryAction != null) ...[
                      const SizedBox(height: 32),
                      primaryAction!,
                    ],
                    if (secondaryAction != null) ...[
                      const SizedBox(height: 12),
                      secondaryAction!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

@Preview(name: 'Onboarding Scaffold', group: 'Onboarding')
Widget onboardingScaffoldPreview() {
  return ShadApp(
    home: Builder(
      builder: (context) {
        final theme = ShadTheme.of(context);
        return OnboardingScaffold(
          title: 'Welcome to Decaid',
          semanticsLabel: 'Welcome screen',
          body: [
            Text(
              'Control your Decent espresso machine, manage profiles, and '
              'track your shots.',
              style: theme.textTheme.p,
              textAlign: TextAlign.center,
            ),
          ],
          primaryAction: AccessibleButton(
            label: 'Get Started',
            onTap: () {},
            child: ShadButton(
              onPressed: () {},
              child: const Text('Get Started'),
            ),
          ),
        );
      },
    ),
  );
}
