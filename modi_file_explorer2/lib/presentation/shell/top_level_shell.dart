import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/tabs/tabs_manager.dart';
import '../text_editor/text_editor_tab.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../settings/settings_panel.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/search_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../common/marquee_text.dart';
import '../search/search_overlay.dart';

class TopLevelShell extends StatefulWidget {
  const TopLevelShell({super.key});

  @override
  State<TopLevelShell> createState() => _TopLevelShellState();
}

class _TopLevelShellState extends State<TopLevelShell>
    with WidgetsBindingObserver {
  final TabsManager tabs = TabsManager.instance;
  DateTime? _lastBackPress;
  bool _exitConfirmationInProgress = false;
  bool _startupReady = false;
  bool _restoreInProgress = false;
  TabEntry? _fullscreenViewer;
  Timer? _statusBarTimer;
  // Storage paths can intentionally occur in multiple tabs, so tab ids are
  // not unique enough to identify header widgets.
  final Map<TabEntry, GlobalKey> _tabKeys = {};
  Set<String> _knownSearchSessionIds = {'home'};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tabs.addListener(_onTabsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_restoreSessionWhenReady());
    });
  }

  @override
  void dispose() {
    _statusBarTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    tabs.removeListener(_onTabsChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(tabs.flushPersistedTabs());
    } else if (state == AppLifecycleState.resumed && !tabs.restoreAttempted) {
      unawaited(_restoreSessionWhenReady());
    }
  }

  Future<void> _restoreSessionWhenReady() async {
    if (_restoreInProgress || tabs.restoreAttempted) return;
    _restoreInProgress = true;
    try {
      if (Platform.isAndroid) {
        final storage = await Permission.storage.status;
        final manage = await Permission.manageExternalStorage.status;
        if (!storage.isGranted && !storage.isLimited && !manage.isGranted) {
          if (mounted) setState(() => _startupReady = true);
          return;
        }
      }
      if (!mounted) return;
      final container = ProviderScope.containerOf(context, listen: false);
      final devices = await container
          .read(storageRepositoryProvider)
          .listStorageDevices();
      final settings = container.read(appSettingsProvider);
      final failures = await tabs.restorePersistedTabs(
        devices: devices,
        closeAllTabsOnExit: settings.closeAllTabsOnExit,
      );
      if (!mounted) return;
      setState(() => _startupReady = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSelectedTabVisible();
      });
      if (failures.isNotEmpty) {
        final summary = failures.take(3).join(' ');
        final more = failures.length > 3
            ? ' ${failures.length - 3} more tab(s) could not be restored.'
            : '';
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('$summary$more')));
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _startupReady = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not restore the previous session: $error'),
          ),
        );
      });
    } finally {
      _restoreInProgress = false;
    }
  }

  void _onTabsChanged() {
    final currentSearchSessionIds = tabs.tabs
        .where(_canSearch)
        .map((tab) => tab.sessionId)
        .toSet();
    final removedSearchSessionIds = _knownSearchSessionIds.difference(
      currentSearchSessionIds,
    );
    _knownSearchSessionIds = currentSearchSessionIds;
    setState(() {});
    _syncFullscreenSystemUi();
    final notice = tabs.takePendingNotice();
    debugPrint(
      '[TopLevelShell] _onTabsChanged selected=${tabs.selectedIndex} tabs=${tabs.tabs.map((t) => t.id).toList()}',
    );
    // After the header rebuilds, ensure the selected tab is visible in the
    // horizontal ListView. Use the tab entry to find the per-item key.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && removedSearchSessionIds.isNotEmpty) {
        final container = ProviderScope.containerOf(context, listen: false);
        for (final sessionId in removedSearchSessionIds) {
          container.invalidate(fileSearchProvider(sessionId));
        }
      }
      if (notice != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(notice)));
      }
      _ensureSelectedTabVisible();
    });
  }

  bool _canSearch(TabEntry tab) =>
      tab.id == 'home' || (!tab.isImageViewer && tab.storagePath != null);

  void _ensureSelectedTabVisible() {
    if (tabs.tabs.isEmpty) return;
    final entry = tabs.tabs[tabs.selectedIndex];
    final key = _tabKeys[entry];
    if (key?.currentContext == null) return;
    Scrollable.ensureVisible(
      key!.currentContext!,
      duration: const Duration(milliseconds: 200),
      alignment: 0.5,
    );
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
        if (!_startupReady) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final selectedTab = tabs.tabs[tabs.selectedIndex];
        final open = ref.watch(settingsPanelProvider);
        final searchOpen =
            _canSearch(selectedTab) &&
            ref.watch(fileSearchProvider(selectedTab.sessionId)).isOpen;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) async {
            if (didPop) return;
            if (searchOpen) {
              ref
                  .read(fileSearchProvider(selectedTab.sessionId).notifier)
                  .close();
              return;
            }
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
                        tabs.tabs[tabs.selectedIndex].isFullscreen &&
                        !searchOpen
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
                                  child: Builder(
                                    builder: (context) {
                                      Widget buildTabChip(
                                        TabEntry tab, {
                                        required int tabIndex,
                                        required bool isHome,
                                      }) {
                                        final selected =
                                            tabIndex == tabs.selectedIndex;
                                        final key = _tabKeys.putIfAbsent(
                                          tab,
                                          () => GlobalKey(),
                                        );
                                        return GestureDetector(
                                          onTap: () => tabs.goTo(tabIndex),
                                          child: SizedBox(
                                            width: isHome ? 60 : 100,
                                            child: Container(
                                              key: key,
                                              padding: EdgeInsets.symmetric(
                                                horizontal: isHome ? 0 : 8,
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
                                                      tab.title,
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
                                                  if (!isHome) ...[
                                                    const SizedBox(width: 4),
                                                    GestureDetector(
                                                      onTap: () => unawaited(
                                                        tabs.requestCloseTab(
                                                          context,
                                                          tabs.tabs.indexOf(
                                                            tab,
                                                          ),
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
                                      }

                                      final homeTab = tabs.tabs.first;
                                      return Row(
                                        children: [
                                          buildTabChip(
                                            homeTab,
                                            tabIndex: 0,
                                            isHome: true,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: SizedBox(
                                              height: 38,
                                              child: DragBoundary(
                                                child: ReorderableListView.builder(
                                                  scrollDirection:
                                                      Axis.horizontal,
                                                  padding: EdgeInsets.zero,
                                                  buildDefaultDragHandles:
                                                      false,
                                                  dragBoundaryProvider:
                                                      (context) =>
                                                          DragBoundary.forRectOf(
                                                            context,
                                                          ),
                                                  itemCount:
                                                      tabs.tabs.length - 1,
                                                  onReorderItem:
                                                      (oldIndex, newIndex) {
                                                        tabs.reorderTab(
                                                          oldIndex + 1,
                                                          newIndex + 1,
                                                        );
                                                      },
                                                  itemBuilder: (context, index) {
                                                    final tabIndex = index + 1;
                                                    final tab =
                                                        tabs.tabs[tabIndex];
                                                    return ReorderableDelayedDragStartListener(
                                                      key: ObjectKey(tab),
                                                      index: index,
                                                      child: buildTabChip(
                                                        tab,
                                                        tabIndex: tabIndex,
                                                        isHome: false,
                                                      ),
                                                    );
                                                  },
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
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
                            physics:
                                selectedTab.isImageViewer &&
                                    selectedTab.isImageZoomed
                                ? const NeverScrollableScrollPhysics()
                                : null,
                            itemCount: tabs.tabs.length,
                            findChildIndexCallback: (key) {
                              if (key is! ObjectKey) return null;
                              final index = tabs.tabs.indexWhere(
                                (tab) => identical(tab, key.value),
                              );
                              return index < 0 ? null : index;
                            },
                            // When PageView reports a page change, update the selected index
                            // without asking the PageController to jump again (prevents a
                            // feedback loop that could revert the selection).
                            onPageChanged: (i) => tabs.setSelectedFromPage(i),
                            itemBuilder: (context, index) {
                              final tab = tabs.tabs[index];
                              return KeyedSubtree(
                                key: ObjectKey(tab),
                                child: MarqueeVisibility(
                                  isVisible: index == tabs.selectedIndex,
                                  child: tab.pageBuilder(),
                                ),
                              );
                            },
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
                        for (final tab in tabs.tabs.where(
                          (tab) =>
                              _canSearch(tab) && !identical(tab, selectedTab),
                        ))
                          SearchOverlay(
                            key: ValueKey(tab.sessionId),
                            sessionId: tab.sessionId,
                            isActive: false,
                          ),
                        if (_canSearch(selectedTab))
                          SearchOverlay(
                            key: ValueKey(selectedTab.sessionId),
                            sessionId: selectedTab.sessionId,
                            isActive: true,
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
