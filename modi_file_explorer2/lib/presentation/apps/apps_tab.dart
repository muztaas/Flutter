import 'package:flutter/material.dart';

import '../../core/providers/installed_apps_providers.dart';
import '../../core/providers/settings_provider.dart';
import '../../domain/entities/installed_app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppsTab extends StatefulWidget {
  const AppsTab({super.key});

  @override
  State<AppsTab> createState() => _AppsTabState();
}

class _AppsTabState extends State<AppsTab> with AutomaticKeepAliveClientMixin {
  late Future<List<InstalledApp>> _appsFuture;

  @override
  void initState() {
    super.initState();
    _appsFuture = getInstalledAppsRepository().listInstalledApps();
  }

  void _reload() {
    setState(() {
      _appsFuture = getInstalledAppsRepository().listInstalledApps();
    });
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
            onPressed: _reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<InstalledApp>>(
        future: _appsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Unable to load installed apps: ${snapshot.error}'));
          }
          final apps = snapshot.data ?? const <InstalledApp>[];
          if (apps.isEmpty) {
            return const Center(child: Text('No installed apps found'));
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: apps.length,
            separatorBuilder: (_, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final app = apps[index];
              return ListTile(
                leading: const CircleAvatar(child: Icon(Icons.apps)),
                title: Text(app.name),
                subtitle: Text('${app.packageName} - ${app.version}'),
              );
            },
          );
        },
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
