import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../presentation/home/home_page.dart';
import '../../presentation/apps/apps_tab.dart';
import '../../presentation/storage/storage_tab.dart';
import '../../presentation/text_editor/text_editor_tab.dart';

class TabEntry {
  final String id;
  final String title;
  // builder used to create the page widget when requested by the UI
  final Widget Function() pageBuilder;
  final Widget? Function()? bottomPanelBuilder;
  final double Function()? bottomPanelHeightBuilder;
  // optional handler that should return true if it handled the back action (i.e., consumed it)
  final Future<bool> Function()? onWillPop;
  final bool Function()? hasUnsavedChanges;
  final Future<bool> Function(BuildContext context)? onCloseRequest;
  final Future<bool> Function()? saveChanges;
  TabEntry({
    required this.id,
    required this.title,
    required this.pageBuilder,
    this.bottomPanelBuilder,
    this.bottomPanelHeightBuilder,
    this.onWillPop,
    this.hasUnsavedChanges,
    this.onCloseRequest,
    this.saveChanges,
  });
}

class TabsManager extends ChangeNotifier {
  static const int maxOpenTabs = 22;
  final ChangeNotifier copyPanelNotifier = ChangeNotifier();
  late final StorageCopySession copySession = StorageCopySession(
    onChanged: copyPanelNotifier.notifyListeners,
  );

  TabsManager._internal() {
    _pageController = PageController(initialPage: 0);
    _tabs = [
      TabEntry(id: 'home', title: 'Home', pageBuilder: () => const HomePage()),
    ];
    _selected = 0;
  }

  static final TabsManager _instance = TabsManager._internal();
  static TabsManager get instance => _instance;

  late PageController _pageController;
  late List<TabEntry> _tabs;
  late int _selected;
  int? _pendingProgrammaticPage;
  bool _restoreAttempted = false;
  bool _restoring = false;

  PageController get pageController => _pageController;
  List<TabEntry> get tabs => List.unmodifiable(_tabs);
  int get selectedIndex => _selected;

  Future<void> restorePersistedTabs() async {
    if (_restoreAttempted) return;
    _restoreAttempted = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('tabs.open');
      if (saved == null) return;
      final data = Map<String, dynamic>.from(jsonDecode(saved) as Map);
      final items = data['items'] as List<dynamic>? ?? const [];
      _restoring = true;
      for (final raw in items) {
        final item = Map<String, dynamic>.from(raw as Map);
        if (item['type'] == 'storage' && item['path'] is String) {
          openStorageTab(
            item['path'] as String,
            title: item['title'] as String?,
            allowDuplicate: true,
          );
        } else if (item['type'] == 'textEditor' && item['path'] is String) {
          openTextEditor(item['path'] as String, allowDuplicate: true);
        } else if (item['type'] == 'apps') {
          openAppsTab();
        }
      }
      _restoring = false;
      final selected = data['selectedIndex'] as int? ?? 0;
      if (selected > 0 && selected < _tabs.length) goTo(selected);
      await _persistTabs();
    } catch (_) {
      _restoring = false;
    }
  }

  Future<void> _persistTabs() async {
    if (_restoring) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final items = _tabs.skip(1).map((tab) {
        if (tab.id == 'apps') return {'type': 'apps'};
        if (tab.id.startsWith('textEditor:')) {
          return {'type': 'textEditor', 'path': tab.id.substring(11)};
        }
        return {'type': 'storage', 'path': tab.id, 'title': tab.title};
      }).toList();
      await prefs.setString(
        'tabs.open',
        jsonEncode({'selectedIndex': _selected, 'items': items}),
      );
    } catch (_) {}
  }

  void openStorageTab(
    String path, {
    String? title,
    bool allowDuplicate = false,
  }) {
    // Existing callers retain focus-existing-tab behavior. Only an explicit
    // duplicate request, such as an Available Storage card tap, skips this.
    if (!allowDuplicate) {
      final exist = _tabs.indexWhere((t) => t.id == path);
      if (exist != -1) {
        goTo(exist);
        return;
      }
    }

    if (_tabs.length >= maxOpenTabs) return;
    final key = GlobalKey<StorageTabState>();
    final entry = TabEntry(
      id: path,
      title:
          title ??
          (path.split('/').where((s) => s.isNotEmpty).isEmpty
              ? 'Storage'
              : path.split('/').last),
      pageBuilder: () => StorageTab(
        key: key,
        initialPath: path,
        displayName: title,
        copySession: copySession,
      ),
      bottomPanelBuilder: () => key.currentState?.buildCopyPanel(),
      bottomPanelHeightBuilder: () => copySession.panelHeight,
      onWillPop: () async {
        try {
          final state = key.currentState;
          if (state != null) {
            final dyn = state as dynamic;
            final handler = dyn.handleWillPop;
            if (handler is Function) {
              final res = await handler();
              return res == true;
            }
          }
        } catch (_) {}
        return false;
      },
    );
    _tabs.add(entry);
    final target = _tabs.length - 1;
    // set selection first so listeners rebuild for the new selected index
    _selected = target;
    debugPrint(
      '[TabsManager] openStorageTab -> added tab "$path" target=$target selected=$_selected',
    );
    notifyListeners();
    unawaited(_persistTabs());

    _schedulePageJump(target);
  }

  void openAppsTab() {
    const id = 'apps';
    final existing = _tabs.indexWhere((tab) => tab.id == id);
    if (existing != -1) {
      goTo(existing);
      return;
    }

    _tabs.add(
      TabEntry(id: id, title: 'Apps', pageBuilder: () => const AppsTab()),
    );
    final target = _tabs.length - 1;
    _selected = target;
    notifyListeners();
    unawaited(_persistTabs());
    _schedulePageJump(target);
  }

  void openTextEditor(String path, {bool allowDuplicate = false}) {
    final id = 'textEditor:$path';
    if (!allowDuplicate) {
      final existing = _tabs.indexWhere((tab) => tab.id == id);
      if (existing != -1) {
        goTo(existing);
        return;
      }
    }
    if (_tabs.length >= maxOpenTabs) return;

    final title = path.split(RegExp(r'[/\\]')).last;
    final key = GlobalKey<TextEditorTabState>();
    _tabs.add(
      TabEntry(
        id: id,
        title: title.isEmpty ? 'Text Editor' : title,
        pageBuilder: () => TextEditorTab(key: key, path: path),
        hasUnsavedChanges: () => key.currentState?.hasUnsavedChanges ?? false,
        onCloseRequest: (context) =>
            key.currentState?.confirmClose(context) ?? Future.value(true),
        saveChanges: () =>
            key.currentState?.saveFromClosePrompt() ?? Future.value(false),
      ),
    );
    final target = _tabs.length - 1;
    _selected = target;
    notifyListeners();
    unawaited(_persistTabs());
    _schedulePageJump(target);
  }

  /// Ask the selected tab to handle a back press. Returns true if the tab
  /// handled (consumed) the back action.
  Future<bool> handleSelectedTabWillPop() async {
    if (_selected < 0 || _selected >= _tabs.length) return false;
    final handler = _tabs[_selected].onWillPop;
    if (handler == null) return false;
    try {
      return await handler();
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestCloseTab(BuildContext context, int idx) async {
    if (idx <= 0 || idx >= _tabs.length) return false;
    final closeRequest = _tabs[idx].onCloseRequest;
    final shouldClose = closeRequest == null || await closeRequest(context);
    if (!shouldClose || idx >= _tabs.length) return false;
    closeTabAt(idx);
    return true;
  }

  void closeTabAt(int idx) {
    if (idx <= 0 || idx >= _tabs.length) return; // never close home
    final closingSelectedTab = idx == _selected;
    _tabs.removeAt(idx);
    if (closingSelectedTab) {
      _selected = idx - 1;
    } else if (idx < _selected) {
      _selected--;
    }
    debugPrint(
      '[TabsManager] closeTabAt -> removed idx=$idx newSelected=$_selected',
    );
    notifyListeners();
    unawaited(_persistTabs());
    _schedulePageJump(_selected);
  }

  void goTo(int idx) {
    if (idx < 0 || idx >= _tabs.length) return;
    _selected = idx;
    debugPrint('[TabsManager] goTo -> idx=$idx selected=$_selected');
    notifyListeners();
    _schedulePageJump(idx);
  }

  void _schedulePageJump(int target) {
    _pendingProgrammaticPage = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pendingProgrammaticPage != target) return;
      if (target >= 0 && target < _tabs.length && _pageController.hasClients) {
        debugPrint('[TabsManager] jumping to page $target');
        _pageController.jumpToPage(target);
      }
      // jumpToPage may not emit onPageChanged when already at this page or
      // when the PageView is not attached. Do not leave a stale guard that
      // suppresses later user-driven page changes.
      if (_pendingProgrammaticPage == target) {
        _pendingProgrammaticPage = null;
      }
    });
  }

  /// Called by the PageView when the visible page changes. This updates the
  /// internal selected index without attempting to move the PageController
  /// (avoids feedback loops where PageView->goTo->PageView causes reversion).
  void setSelectedFromPage(int idx) {
    if (idx < 0 || idx >= _tabs.length) return;
    // Ignore intermediate callbacks until the scheduled programmatic jump
    // reaches its target. The pending guard is cleared immediately after the
    // jump too, since jumping to the current page may not emit a callback.
    if (_pendingProgrammaticPage != null) {
      debugPrint(
        '[TabsManager] setSelectedFromPage -> pending=$_pendingProgrammaticPage idx=$idx',
      );
      if (_pendingProgrammaticPage == idx) {
        _pendingProgrammaticPage = null;
        if (_selected == idx) return;
        _selected = idx;
        notifyListeners();
        unawaited(_persistTabs());
      }
      return;
    }
    if (_selected == idx) return;
    debugPrint(
      '[TabsManager] setSelectedFromPage -> idx=$idx previousSelected=$_selected',
    );
    _selected = idx;
    notifyListeners();
    unawaited(_persistTabs());
  }

  void disposeManager() {
    _pageController.dispose();
  }
}
