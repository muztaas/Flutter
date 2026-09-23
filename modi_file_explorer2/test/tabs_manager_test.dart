import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modi_file_explorer2/presentation/shell/top_level_shell.dart';
import 'package:modi_file_explorer2/core/tabs/tabs_manager.dart';

void main() {
  testWidgets('opening a new storage tab keeps it selected after frames settle', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: TopLevelShell()));

    // Ensure initial state
    expect(TabsManager.instance.tabs.length, greaterThanOrEqualTo(1));
    final initialCount = TabsManager.instance.tabs.length;

    // Open a new storage tab (path can be any string)
    TabsManager.instance.openStorageTab('/tmp/test-path');

    // Allow post-frame callbacks and any scheduled jumps to run
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    // After settling, the selected index should point to the newly opened tab
    expect(TabsManager.instance.tabs.length, initialCount + 1);
    expect(TabsManager.instance.selectedIndex, equals(TabsManager.instance.tabs.length - 1));
  });
}
