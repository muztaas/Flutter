import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modi_file_explorer2/presentation/shell/top_level_shell.dart';
import 'package:modi_file_explorer2/core/tabs/tabs_manager.dart';

void main() {
  testWidgets('header highlights programmatically opened tab', (WidgetTester tester) async {
    final theme = ThemeData.from(colorScheme: const ColorScheme.light()).copyWith();
    await tester.pumpWidget(MaterialApp(theme: theme, home: const TopLevelShell()));

    // open a storage tab programmatically
    TabsManager.instance.openStorageTab('/tmp/my-downloads');

    // let post-frame callbacks and animations settle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final tabs = TabsManager.instance;
    final title = tabs.tabs[tabs.selectedIndex].title;

    // Find the Text widget in the header for the selected tab
    final textFinder = find.text(title);
    expect(textFinder, findsOneWidget);

    // Access the Text widget's style color and ensure it equals the onSecondaryContainer color
    final BuildContext shellContext = tester.element(find.byType(TopLevelShell));
    final expectedColor = Theme.of(shellContext).colorScheme.onSecondaryContainer;
    final textWidget = tester.widget<Text>(textFinder);
    expect(textWidget.style?.color, equals(expectedColor));
  });
}
