import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/feedback_feature/feedback_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  testWidgets('discloses the public account-linked contact id', (tester) async {
    await tester.pumpWidget(
      ShadApp(
        home: Scaffold(
          body: FeedbackDialog(
            githubToken: '',
            serialNumbers: () => const [],
            accountService: null,
          ),
        ),
      ),
    );

    expect(find.textContaining('associated with that account'), findsOneWidget);
    expect(find.textContaining('added to the public issue'), findsOneWidget);
  });
}
