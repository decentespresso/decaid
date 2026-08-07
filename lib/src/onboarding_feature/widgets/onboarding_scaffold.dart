import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';
import 'package:reaprime/src/widgets/accessible_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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

  final String? title;

  final String semanticsLabel;

  final List<Widget> body;

  final Widget? primaryAction;

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
