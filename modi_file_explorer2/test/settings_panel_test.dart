import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:modi_file_explorer2/presentation/shell/top_level_shell.dart';

void main() {
  testWidgets('Open and close settings via hamburger and scrim', (tester) async {
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: const TopLevelShell())));

    // Initially no Settings header
    expect(find.text('Settings'), findsNothing);

    // Tap hamburger
    final menu = find.byIcon(Icons.menu);
    expect(menu, findsOneWidget);
    await tester.tap(menu);
    await tester.pumpAndSettle();

    expect(find.text('Settings'), findsOneWidget);
    // Now tap scrim area (outside panel) to dismiss
    await tester.tapAt(const Offset(500, 10));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
  });

  testWidgets('Back button closes settings panel first', (tester) async {
    await tester.pumpWidget(ProviderScope(child: MaterialApp(home: const TopLevelShell())));

    // Open panel
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);

    // Simulate system back
    await tester.binding.handlePopRoute();
    // handlePopRoute returns true when pop handled; our WillPopScope should consume and return false to not pop app.
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsNothing);
  });
}
