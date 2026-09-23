import 'package:flutter/material.dart';
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
  final Map<String, GlobalKey> _tabKeys = {};

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
    debugPrint('[TopLevelShell] _onTabsChanged selected=${tabs.selectedIndex} tabs=${tabs.tabs.map((t) => t.id).toList()}');
    // After the header rebuilds, ensure the selected tab is visible in the
    // horizontal ListView. Use the tab id to find the per-item key.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (tabs.tabs.isEmpty) return;
      final id = tabs.tabs[tabs.selectedIndex].id;
      final key = _tabKeys[id];
      if (key?.currentContext != null) {
        Scrollable.ensureVisible(key!.currentContext!, duration: const Duration(milliseconds: 200), alignment: 0.5);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(builder: (context, ref, _) {
      final open = ref.watch(settingsPanelProvider);
      return WillPopScope(
      onWillPop: () async {
        // If settings panel is open, close it first.
        if (open) {
          ref.read(settingsPanelProvider.notifier).close();
          return false;
        }
        // Ask the current tab to handle back first.
        final handled = await tabs.handleSelectedTabWillPop();
        if (handled) return false; // consumed by tab

        // Not handled by tab: require double-back within 1 second to exit
        final now = DateTime.now();
        if (_lastBackPress == null || now.difference(_lastBackPress!) > const Duration(seconds: 1)) {
          _lastBackPress = now;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Press back again to exit')));
          return false; // don't pop
        }
        return true; // allow pop (exit)
      },
      child: Stack(
        children: [
          Scaffold(
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: Theme.of(context).appBarTheme.backgroundColor ?? Theme.of(context).colorScheme.primary,
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: tabs.tabs.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final t = tabs.tabs[index];
                          final selected = index == tabs.selectedIndex;
                          final key = _tabKeys.putIfAbsent(t.id, () => GlobalKey());
                          return GestureDetector(
                            onTap: () => tabs.goTo(index),
                            child: Container(
                              key: key,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: selected ? Theme.of(context).colorScheme.secondaryContainer : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(children: [
                                Text(t.title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: selected ? Theme.of(context).colorScheme.onSecondaryContainer : null)),
                                if (index != 0) ...[
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: () => tabs.closeTabAt(index),
                                    child: Icon(Icons.close, size: 16, color: selected ? Theme.of(context).colorScheme.onSecondaryContainer : null),
                                  )
                                ]
                              ]),
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
          itemBuilder: (context, index) => tabs.tabs[index].pageBuilder(),
          ),
          ),
          // Settings panel overlay
          const SettingsPanel(),
        ],
      ),
    );
    });
  }
}
