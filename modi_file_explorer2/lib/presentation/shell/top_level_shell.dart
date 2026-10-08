import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/tabs/tabs_manager.dart';
import '../text_editor/text_editor_tab.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../settings/settings_panel.dart';
import '../../core/providers/settings_provider.dart';
import '../common/marquee_text.dart';

class TopLevelShell extends StatefulWidget {
  const TopLevelShell({super.key});

  @override
  State<TopLevelShell> createState() => _TopLevelShellState();
}

class _TopLevelShellState extends State<TopLevelShell> {
  final TabsManager tabs = TabsManager.instance;
  DateTime? _lastBackPress;
  bool _exitConfirmationInProgress = false;
  TabEntry? _fullscreenViewer;
  Timer? _statusBarTimer;
  // Storage paths can intentionally occur in multiple tabs, so tab ids are
  // not unique enough to identify header widgets.
  final Map<TabEntry, GlobalKey> _tabKeys = {};

  @override
  void initState() {
    super.initState();
    tabs.addListener(_onTabsChanged);
    unawaited(tabs.restorePersistedTabs());
  }

  @override
  void dispose() {
    _statusBarTimer?.cancel();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    tabs.removeListener(_onTabsChanged);
    super.dispose();
  }

  void _onTabsChanged() {
    setState(() {});
    _syncFullscreenSystemUi();
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

  void _syncFullscreenSystemUi() {
    final index = tabs.selectedIndex;
    final selectedTab = index >= 0 && index < tabs.tabs.length
        ? tabs.tabs[index]
        : null;
    final viewer =
        selectedTab?.isImageViewer == true && selectedTab?.isFullscreen == true
        ? selectedTab
        : null;
    if (identical(viewer, _fullscreenViewer)) return;

    _statusBarTimer?.cancel();
    _fullscreenViewer = viewer;
    if (viewer == null) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      return;
    }

    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: const [SystemUiOverlay.top, SystemUiOverlay.bottom],
      ),
    );
    _statusBarTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted ||
          !identical(_fullscreenViewer, viewer) ||
          tabs.selectedIndex >= tabs.tabs.length ||
          !identical(tabs.tabs[tabs.selectedIndex], viewer)) {
        return;
      }
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: const [SystemUiOverlay.bottom],
        ),
      );
    });
  }

  Future<void> _confirmExitWithUnsavedEditors() async {
    if (_exitConfirmationInProgress) return;
    _exitConfirmationInProgress = true;
    try {
      final unsavedTabs = tabs.tabs
          .where((tab) => tab.hasUnsavedChanges?.call() == true)
          .toList();
      if (unsavedTabs.isEmpty) return;

      final decision = await TextEditorTabState.showUnsavedChangesDialog(
        context,
        fileCount: unsavedTabs.length,
        fileName: unsavedTabs.first.title,
        isExit: true,
      );
      if (!mounted ||
          decision == null ||
          decision == TextEditorCloseDecision.cancel) {
        return;
      }
      if (decision == TextEditorCloseDecision.save) {
        for (final tab in unsavedTabs) {
          final saveChanges = tab.saveChanges;
          if (saveChanges == null || !await saveChanges()) return;
        }
      }
      if (mounted) unawaited(SystemNavigator.pop(animated: false));
    } finally {
      _exitConfirmationInProgress = false;
    }
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

            final hasUnsavedEditors = tabs.tabs.any(
              (tab) => tab.hasUnsavedChanges?.call() == true,
            );
            if (hasUnsavedEditors) {
              _lastBackPress = null;
              await _confirmExitWithUnsavedEditors();
              return;
            }

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
                appBar:
                    tabs.tabs[tabs.selectedIndex].isImageViewer &&
                        tabs.tabs[tabs.selectedIndex].isFullscreen
                    ? null
                    : PreferredSize(
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
                                        final selected =
                                            index == tabs.selectedIndex;
                                        final key = _tabKeys.putIfAbsent(
                                          t,
                                          () => GlobalKey(),
                                        );
                                        return GestureDetector(
                                          onTap: () => tabs.goTo(index),
                                          child: SizedBox(
                                            key: ObjectKey(t),
                                            width: index == 0 ? 60 : 100,
                                            child: Container(
                                              key: key,
                                              padding: EdgeInsets.symmetric(
                                                horizontal: index == 0 ? 0 : 8,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                color: selected
                                                    ? Theme.of(context)
                                                          .colorScheme
                                                          .secondaryContainer
                                                    : Colors.transparent,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: MarqueeText(
                                                      t.title,
                                                      style: Theme.of(context)
                                                          .textTheme
                                                          .titleSmall
                                                          ?.copyWith(
                                                            fontSize: 14,
                                                            color: selected
                                                                ? Theme.of(
                                                                        context,
                                                                      )
                                                                      .colorScheme
                                                                      .onSecondaryContainer
                                                                : null,
                                                          ),
                                                      textAlign:
                                                          TextAlign.center,
                                                      styleMode: MarqueeStyle
                                                          .pauseAndLoop,
                                                      isActive: selected,
                                                    ),
                                                  ),
                                                  if (index != 0) ...[
                                                    const SizedBox(width: 4),
                                                    GestureDetector(
                                                      onTap: () => unawaited(
                                                        tabs.requestCloseTab(
                                                          context,
                                                          index,
                                                        ),
                                                      ),
                                                      child: SizedBox(
                                                        width: 24,
                                                        height: 24,
                                                        child: Icon(
                                                          Icons.close,
                                                          size: 16,
                                                          color: selected
                                                              ? Theme.of(
                                                                      context,
                                                                    )
                                                                    .colorScheme
                                                                    .onSecondaryContainer
                                                              : null,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
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
                body: AnimatedBuilder(
                  animation: tabs.copyPanelNotifier,
                  builder: (context, _) {
                    final selectedTab = tabs.tabs[tabs.selectedIndex];
                    final panel = selectedTab.bottomPanelBuilder?.call();
                    final panelHeight = panel == null
                        ? 0.0
                        : selectedTab.bottomPanelHeightBuilder?.call() ?? 72;
                    final bottomInset = MediaQuery.viewPaddingOf(
                      context,
                    ).bottom;
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            bottom: panel == null
                                ? 0
                                : panelHeight + bottomInset,
                          ),
                          child: PageView.builder(
                            controller: tabs.pageController,
                            itemCount: tabs.tabs.length,
                            // When PageView reports a page change, update the selected index
                            // without asking the PageController to jump again (prevents a
                            // feedback loop that could revert the selection).
                            onPageChanged: (i) => tabs.setSelectedFromPage(i),
                            itemBuilder: (context, index) => MarqueeVisibility(
                              isVisible: index == tabs.selectedIndex,
                              child: tabs.tabs[index].pageBuilder(),
                            ),
                          ),
                        ),
                        if (panel != null)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: SizedBox(
                              width: double.infinity,
                              child: panel,
                            ),
                          ),
                      ],
                    );
                  },
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
