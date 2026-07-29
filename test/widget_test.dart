// Basic smoke test for the JW Fusion dashboard.
//
// Verifies the app boots into its idle state - no files selected yet, one
// obvious "add files" affordance, and the merge button disabled until two
// backups are added.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jw_fusion/main.dart';

void main() {
  testWidgets('Dashboard boots into the idle state', (WidgetTester tester) async {
    await tester.pumpWidget(const JwFusionApp());

    // The app bar title and the idle screen headline both read "JW Fusion".
    expect(find.text('JW Fusion'), findsNWidgets(2));

    // No files selected yet, so the empty-state hint is showing ...
    expect(
      find.text('Add two or more backups to get started.'),
      findsOneWidget,
    );

    // ... and the merge button says how many more files are needed.
    expect(find.text('Merge Backups (add 2 more)'), findsOneWidget);

    // Settings is reachable from the dashboard.
    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
  });
}
