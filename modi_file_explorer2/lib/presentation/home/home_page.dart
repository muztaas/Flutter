import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../domain/entities/storage_device.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          // desktop layout stub
          return Center(child: Text('Desktop Home (stub)', style: Theme.of(context).textTheme.headlineMedium));
        }

        // mobile layout
        return Scaffold(
          appBar: AppBar(
            leading: Consumer(builder: (context, ref, _) {
              return IconButton(icon: const Icon(Icons.menu), onPressed: () => ref.read(settingsPanelProvider.notifier).toggle());
            }),
            title: const Text('Home'),
            actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.search))],
          ),
          body: Column(
            children: [
              SizedBox(height: 160, child: _CategoryCards()),
              Expanded(child: _QuickAccessSection()),
              SizedBox(height: 200, child: _AvailableStorageSection()),
            ],
          ),
        );
      },
    );
  }
}

class _CategoryCards extends StatelessWidget {
  final List<Map<String, dynamic>> categories = const [
    {'name': 'Downloads', 'icon': Icons.download},
    {'name': 'Documents', 'icon': Icons.description},
    {'name': 'Images', 'icon': Icons.image},
    {'name': 'Videos', 'icon': Icons.movie},
    {'name': 'Audio', 'icon': Icons.audiotrack},
    {'name': 'Apps', 'icon': Icons.apps},
  ];

  Future<String?> _getCategorySize(String category) async {
    final devices = await getStorageRepository().listStorageDevices();
    if (devices.isEmpty) return null;

    StorageDevice device = devices.first;
    for (final candidate in devices) {
      if (candidate.id == 'internal') {
        device = candidate;
        break;
      }
    }
    if (device.id != 'internal') {
      for (final candidate in devices) {
        if (candidate.id == 'external') {
          device = candidate;
          break;
        }
      }
    }

    const folders = {
      'Downloads': 'Download',
      'Documents': 'Documents',
      'Images': 'Pictures',
      'Videos': 'Movies',
      'Audio': 'Music',
    };
    final folder = folders[category];
    if (folder == null) return null;

    final directory = Directory('${device.path}/$folder');
    if (!await directory.exists()) return null;

    var bytes = 0;
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          bytes += await entity.length();
        } catch (_) {
          // Ignore files that cannot be accessed.
        }
      }
    }
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024 * 1024) return '${(mb / (1024 * 1024)).toStringAsFixed(1)} TB';
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 240,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemBuilder: (context, index) {
            final c = categories[index];
            return SizedBox(
              width: MediaQuery.of(context).size.width * 0.4,
              height: 216,
              child: InkWell(
              onTap: () async {
                if (c['name'] == 'Apps') {
                  TabsManager.instance.openAppsTab();
                  return;
                }

                // Resolve a sensible base path (prefer internal storage, then external, then app docs)
                final repo = getStorageRepository();
                final devices = await repo.listStorageDevices();
                String? base;
                try {
                  base = devices.firstWhere((d) => d.id == 'internal', orElse: () => devices.firstWhere((d) => d.id == 'external', orElse: () => devices.isNotEmpty ? devices.first : throw StateError('no-devices'))).path;
                } catch (_) {
                  base = devices.isNotEmpty ? devices.first.path : null;
                }

                if (base == null) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No storage available')));
                  return;
                }

                final name = (c['name'] as String).toLowerCase();
                String folder;
                if (name.contains('download')) folder = 'Download';
                else if (name.contains('document')) folder = 'Documents';
                else if (name.contains('image')) folder = 'Pictures';
                else if (name.contains('video')) folder = 'Movies';
                else if (name.contains('audio')) folder = 'Music';
                else folder = '';

                final target = folder.isEmpty ? base : '$base/$folder';
                TabsManager.instance.openStorageTab(target);
              },
              child: Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(c['icon'] as IconData, size: 36),
                      const SizedBox(height: 12),
                      Text(c['name'] as String, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      _CategorySize(
                        category: c['name'] as String,
                        loader: _getCategorySize,
                      ),
                    ],
                  ),
                ),
              ),
              ),
            );
          },
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemCount: categories.length,
        ),
      ),
    );
  }
}

class _CategorySize extends StatelessWidget {
  final String category;
  final Future<String?> Function(String category) loader;

  const _CategorySize({required this.category, required this.loader});

  @override
  Widget build(BuildContext context) {
    if (category == 'Apps') {
      return const SizedBox.shrink();
    }

    return FutureBuilder<String?>(
      future: loader(category),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Text('Calculating…', style: Theme.of(context).textTheme.bodySmall);
        }
        final size = snapshot.data;
        return Text(
          size ?? 'Unavailable',
          style: Theme.of(context).textTheme.bodySmall,
        );
      },
    );
  }
}

class _QuickAccessSection extends StatelessWidget {
  const _QuickAccessSection();

  @override
  Widget build(BuildContext context) {
    // For now, show an empty state
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recent', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Expanded(
            child: Center(child: Text('No favourites', style: Theme.of(context).textTheme.bodyMedium)),
          ),
        ],
      ),
    );
  }
}

class _AvailableStorageSection extends StatelessWidget {
  const _AvailableStorageSection();

  @override
  Widget build(BuildContext context) {
    final repo = getStorageRepository();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Available Storage', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<StorageDevice>>(
              future: repo.listStorageDevices(),
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
                final devices = snap.data ?? [];
                if (devices.isEmpty) return const Center(child: Text('No storage devices found'));
                final cross = MediaQuery.of(context).size.width >= 400 ? 2 : 1;
                return GridView.count(
                  crossAxisCount: cross,
                  childAspectRatio: 2.5,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  children: devices.map((d) => _StorageCard(device: d)).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  final StorageDevice device;
  const _StorageCard({required this.device});

  String _formatBytes(int? value) {
    if (value == null || value <= 0) return '0 MB';
    final mb = value / (1024 * 1024);
    if (mb >= 1024 * 1024) return '${(mb / (1024 * 1024)).toStringAsFixed(1)} TB';
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final used = _formatBytes(device.usedBytes);
    final total = _formatBytes(device.totalBytes);
    final usageText = device.totalBytes != null && device.totalBytes! > 0
        ? '$used / $total used'
        : 'Storage info unavailable';

    return InkWell(
      onTap: () {
        TabsManager.instance.openStorageTab(device.path, title: device.name);
      },
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.sd_storage, size: 32),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(device.name, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        usageText,
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
