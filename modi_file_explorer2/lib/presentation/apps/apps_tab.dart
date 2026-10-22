import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/providers/installed_apps_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/utils/format_bytes.dart';
import '../../domain/entities/installed_app.dart';
import '../../domain/entities/installed_app_size.dart';

class AppsTab extends StatefulWidget {
  const AppsTab({super.key});

  @override
  State<AppsTab> createState() => _AppsTabState();
}

class _AppsTabState extends State<AppsTab>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  List<InstalledApp> _apps = const [];
  List<InstalledApp>? _pendingApps;
  Object? _loadError;
  bool _hasLoaded = false;
  bool _isLoading = true;
  bool _isScrolling = false;
  bool _usagePromptStarted = false;
  bool? _hadUsageAccess;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadApps());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_refreshUsageAccessState());
  }

  Future<void> _refreshUsageAccessState() async {
    try {
      final repository = getInstalledAppsRepository();
      repository.clearAppSizeCache();
      final hasAccess = await repository.hasUsageAccess();
      final previouslyHadAccess = _hadUsageAccess;
      _hadUsageAccess = hasAccess;
      if (previouslyHadAccess != null &&
          previouslyHadAccess != hasAccess &&
          mounted) {
        setState(() {});
      }
    } catch (error) {
      if (mounted) {
        setState(() => _loadError = 'Could not check Usage access: $error');
      }
    }
  }

  void _reload() {
    getInstalledAppsRepository().clearAppSizeCache();
    unawaited(_loadApps());
  }

  Future<void> _loadApps() async {
    final generation = ++_loadGeneration;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final apps = await getInstalledAppsRepository().listInstalledApps();
      if (!mounted || generation != _loadGeneration) return;
      final hadLoaded = _hasLoaded;
      setState(() {
        _hasLoaded = true;
        _isLoading = false;
        if (_isScrolling && hadLoaded) {
          _pendingApps = apps;
        } else if (!_sameApps(_apps, apps)) {
          _apps = apps;
          _pendingApps = null;
        } else {
          _pendingApps = null;
        }
      });
      if (!hadLoaded) unawaited(_offerUsageAccess());
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _isLoading = false;
        _loadError = error;
      });
    }
  }

  Future<void> _offerUsageAccess() async {
    if (_usagePromptStarted || !mounted) return;
    _usagePromptStarted = true;
    final repository = getInstalledAppsRepository();
    late final SharedPreferences preferences;
    late final bool wasPrompted;
    late final bool hasAccess;
    try {
      preferences = await SharedPreferences.getInstance();
      wasPrompted =
          preferences.getBool('settings.apps.usageAccessPrompted') ?? false;
      hasAccess = await repository.hasUsageAccess();
      if (!wasPrompted && !hasAccess) {
        await preferences.setBool('settings.apps.usageAccessPrompted', true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _loadError = 'Could not check Usage access: $error');
      }
      return;
    }
    _hadUsageAccess = hasAccess;
    if (wasPrompted || hasAccess || !mounted) return;

    final openSettings = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Show total app sizes?'),
        content: const Text(
          'Usage access lets the Apps page show app data and cache sizes in '
          'addition to APK size. Without it, only APK size is shown.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Not now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Open Usage access'),
          ),
        ],
      ),
    );
    if (openSettings != true || !mounted) return;
    try {
      await repository.openUsageAccessSettings();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open Usage access settings: $error'),
          ),
        );
      }
    }
  }

  void _applyPendingApps() {
    final pending = _pendingApps;
    if (pending == null) return;
    setState(() {
      if (!_sameApps(_apps, pending)) _apps = pending;
      _pendingApps = null;
    });
  }

  bool _sameApps(List<InstalledApp> current, List<InstalledApp> next) {
    if (current.length != next.length) return false;
    for (var index = 0; index < current.length; index++) {
      final oldApp = current[index];
      final newApp = next[index];
      if (oldApp.packageName != newApp.packageName ||
          oldApp.name != newApp.name ||
          oldApp.version != newApp.version) {
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        leading: Consumer(
          builder: (context, ref, _) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => ref.read(settingsPanelProvider.notifier).toggle(),
          ),
        ),
        title: const Text('Apps'),
        actions: [
          IconButton(
            tooltip: 'Refresh apps',
            onPressed: _isLoading ? null : _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (!_hasLoaded && _isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_hasLoaded && _loadError != null) {
      return Center(child: Text('Unable to load installed apps: $_loadError'));
    }

    final apps = _apps;
    if (apps.isEmpty) {
      return Column(
        children: [
          if (_loadError != null) _buildErrorBanner(),
          const Expanded(child: Center(child: Text('No installed apps found'))),
        ],
      );
    }

    return Column(
      children: [
        if (_loadError != null) _buildErrorBanner(),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollStartNotification) {
                _isScrolling = true;
              } else if (notification is ScrollEndNotification) {
                _isScrolling = false;
                _applyPendingApps();
              }
              return false;
            },
            child: Scrollbar(
              thumbVisibility: true,
              interactive: true,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: apps.length,
                separatorBuilder: (_, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final app = apps[index];
                  return ListTile(
                    key: ValueKey(app.packageName),
                    leading: _InstalledAppIcon(packageName: app.packageName),
                    title: Text(app.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${app.packageName} - ${app.version}'),
                        _InstalledAppSize(packageName: app.packageName),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBanner() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        'Unable to refresh installed apps: $_loadError',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _InstalledAppSize extends StatelessWidget {
  const _InstalledAppSize({required this.packageName});

  final String packageName;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<InstalledAppSize>(
      future: getInstalledAppsRepository().getAppSize(packageName),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Text('Size unavailable');
        }
        final size = snapshot.data;
        if (size == null) return const Text('Calculating size...');
        final apkSize = formatBytes(size.apkBytes);
        final totalSize = size.totalBytes;
        return Text(
          totalSize == null
              ? 'App size: $apkSize'
              : 'App size: $apkSize · Total: ${formatBytes(totalSize)}',
        );
      },
    );
  }
}

class _InstalledAppIcon extends StatelessWidget {
  const _InstalledAppIcon({required this.packageName});

  final String packageName;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: getInstalledAppsRepository().getAppIcon(packageName),
      builder: (context, snapshot) {
        final icon = snapshot.data;
        if (icon == null || icon.isEmpty) {
          return const CircleAvatar(child: Icon(Icons.apps));
        }
        return CircleAvatar(
          backgroundColor: Colors.transparent,
          child: ClipOval(
            child: Image.memory(
              icon,
              width: 40,
              height: 40,
              fit: BoxFit.cover,
              cacheWidth: 80,
              cacheHeight: 80,
            ),
          ),
        );
      },
    );
  }
}
