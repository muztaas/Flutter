import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/tabs/tabs_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../settings/settings_panel.dart';
import '../../core/providers/settings_provider.dart';

class TopLevelShell extends StatefulWidget {
  const TopLevelShell({super.key});

  @override
  State<TopLevelShell> createState() => _TopLevelShellState();
}

class _TopLevelShellState extends State<TopLevelShell> {
  final TabsManager tabs = TabsManager.instance;
  DateTime? _lastBackPress;
  // Storage paths can intentionally occur in multiple tabs, so tab ids are
  // not unique enough to identify header widgets.
  final Map<TabEntry, GlobalKey> _tabKeys = {};

  @override
  void initState() {
    super.initState();
    tabs.addListener(_onTabsChanged);
  }

  @override
  void dispose() {
    tabs.removeListener(_onTabsChanged);
    super.dispose();
  }

  void _onTabsChanged() {
    setState(() {});
    debugPrint(
      '[TopLevelShell] _onTabsChanged selected=${tabs.selectedIndex} tabs=${tabs.tabs.map((t) => t.id).toList()}',
    );
    // After the header rebuilds, ensure the selected tab is visible in the
    // horizontal ListView. Use the tab entry to find the per-item key.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (tabs.tabs.isEmpty) return;
      final entry = tabs.tabs[tabs.selectedIndex];
      final key = _tabKeys[entry];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(
          key!.currentContext!,
          duration: const Duration(milliseconds: 200),
          alignment: 0.5,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) {
        final open = ref.watch(settingsPanelProvider);
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            // If settings panel is open, close it first.
            if (open) {
              ref.read(settingsPanelProvider.notifier).close();
              return;
            }
            // Ask the current tab to handle back first.
            final handled = await tabs.handleSelectedTabWillPop();
            if (!context.mounted || handled) return; // consumed by tab

            // Not handled by tab: require double-back within 1 second to exit
            final now = DateTime.now();
            if (_lastBackPress == null ||
                now.difference(_lastBackPress!) > const Duration(seconds: 1)) {
              _lastBackPress = now;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Press back again to exit')),
              );
              return; // don't pop
            }
            if (context.mounted) {
              _lastBackPress = null;
              unawaited(SystemNavigator.pop(animated: false));
            }
          },
          child: Stack(
            children: [
              Scaffold(
                appBar: PreferredSize(
                  preferredSize: const Size.fromHeight(44),
                  child: SafeArea(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      color: Colors.lightBlue,
                      child: Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 38,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: tabs.tabs.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final t = tabs.tabs[index];
                                  final selected = index == tabs.selectedIndex;
                                  final key = _tabKeys.putIfAbsent(
                                    t,
                                    () => GlobalKey(),
                                  );
                                  return GestureDetector(
                                    onTap: () => tabs.goTo(index),
                                    child: Container(
                                      key: key,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: selected
                                            ? Theme.of(
                                                context,
                                              ).colorScheme.secondaryContainer
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        children: [
                                          Text(
                                            t.title,
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleSmall
                                                ?.copyWith(
                                                  fontSize: 14,
                                                  color: selected
                                                      ? Theme.of(context)
                                                            .colorScheme
                                                            .onSecondaryContainer
                                                      : null,
                                                ),
                                          ),
                                          if (index != 0) ...[
                                            const SizedBox(width: 8),
                                            GestureDetector(
                                              onTap: () =>
                                                  tabs.closeTabAt(index),
                                              child: Icon(
                                                Icons.close,
                                                size: 16,
                                                color: selected
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .onSecondaryContainer
                                                    : null,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                body: PageView.builder(
                  controller: tabs.pageController,
                  itemCount: tabs.tabs.length,
                  // When PageView reports a page change, update the selected index
                  // without asking the PageController to jump again (prevents a
                  // feedback loop that could revert the selection).
                  onPageChanged: (i) => tabs.setSelectedFromPage(i),
                  itemBuilder: (context, index) =>
                      tabs.tabs[index].pageBuilder(),
                ),
              ),
              // Settings panel overlay
              const SettingsPanel(),
            ],
          ),
        );
      },
    );
  }
}
