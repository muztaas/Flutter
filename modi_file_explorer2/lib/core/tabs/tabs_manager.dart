import 'package:flutter/material.dart';
import '../../presentation/home/home_page.dart';
import '../../presentation/apps/apps_tab.dart';
import '../../presentation/storage/storage_tab.dart';

class TabEntry {
  final String id;
  final String title;
  // builder used to create the page widget when requested by the UI
  final Widget Function() pageBuilder;
  // optional handler that should return true if it handled the back action (i.e., consumed it)
  final Future<bool> Function()? onWillPop;
  TabEntry({
    required this.id,
    required this.title,
    required this.pageBuilder,
    this.onWillPop,
  });
}

class TabsManager extends ChangeNotifier {
  static const int maxOpenTabs = 22;

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

  PageController get pageController => _pageController;
  List<TabEntry> get tabs => List.unmodifiable(_tabs);
  int get selectedIndex => _selected;

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
    final key = GlobalKey<State>();
    final entry = TabEntry(
      id: path,
      title:
          title ??
          (path.split('/').where((s) => s.isNotEmpty).isEmpty
              ? 'Storage'
              : path.split('/').last),
      pageBuilder: () =>
          StorageTab(key: key, initialPath: path, displayName: title),
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

    // Schedule navigation to the new tab after the next frame so the
    // PageView has rebuilt with the new item. Mark the target as pending
    // so transient PageView callbacks don't revert our selection.
    _pendingProgrammaticPage = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pendingProgrammaticPage != target) return; // cancelled/replaced
      if (target >= 0 && target < _tabs.length && _pageController.hasClients) {
        debugPrint(
          '[TabsManager] openStorageTab -> jumping to page $target (hasClients)',
        );
        _pageController.jumpToPage(target);
      }
    });
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
    _pendingProgrammaticPage = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pendingProgrammaticPage != target) return;
      if (target >= 0 && target < _tabs.length && _pageController.hasClients) {
        _pageController.jumpToPage(target);
      }
    });
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

  void closeTabAt(int idx) {
    if (idx <= 0 || idx >= _tabs.length) return; // never close home
    _tabs.removeAt(idx);
    if (_selected >= _tabs.length) _selected = _tabs.length - 1;
    debugPrint(
      '[TabsManager] closeTabAt -> removed idx=$idx newSelected=$_selected',
    );
    notifyListeners();
    // schedule programmatic jump to new selected
    _pendingProgrammaticPage = _selected;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _pendingProgrammaticPage;
      if (target == null) return;
      if (target >= 0 && target < _tabs.length && _pageController.hasClients) {
        debugPrint(
          '[TabsManager] closeTabAt -> jumping to page $_selected (hasClients)',
        );
        _pageController.jumpToPage(_selected);
      }
    });
  }

  void goTo(int idx) {
    if (idx < 0 || idx >= _tabs.length) return;
    _selected = idx;
    debugPrint('[TabsManager] goTo -> idx=$idx selected=$_selected');
    notifyListeners();
    // schedule programmatic jump
    _pendingProgrammaticPage = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pendingProgrammaticPage != idx) return; // cancelled/replaced
      if (idx >= 0 && idx < _tabs.length && _pageController.hasClients) {
        debugPrint('[TabsManager] goTo -> jumping to page $idx');
        _pageController.jumpToPage(idx);
      }
    });
  }

  /// Called by the PageView when the visible page changes. This updates the
  /// internal selected index without attempting to move the PageController
  /// (avoids feedback loops where PageView->goTo->PageView causes reversion).
  void setSelectedFromPage(int idx) {
    if (idx < 0 || idx >= _tabs.length) return;
    // If a programmatic page jump is pending, only accept the PageView's
    // report if it matches the pending target; otherwise ignore to avoid
    // reverting the selection to a stale index.
    if (_pendingProgrammaticPage != null) {
      debugPrint(
        '[TabsManager] setSelectedFromPage -> pending=$_pendingProgrammaticPage idx=$idx',
      );
      if (_pendingProgrammaticPage == idx) {
        _pendingProgrammaticPage = null;
        if (_selected == idx) return;
        _selected = idx;
        notifyListeners();
      }
      return;
    }
    if (_selected == idx) return;
    debugPrint(
      '[TabsManager] setSelectedFromPage -> idx=$idx previousSelected=$_selected',
    );
    _selected = idx;
    notifyListeners();
  }

  void disposeManager() {
    _pageController.dispose();
  }
}
