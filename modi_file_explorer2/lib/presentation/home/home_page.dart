import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../domain/entities/storage_device.dart';
import '../common/marquee_text.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with AutomaticKeepAliveClientMixin<HomePage> {
  final _categoryKey = GlobalKey<_CategoryCardsState>();
  final _storageKey = GlobalKey<_AvailableStorageSectionState>();
  final TabsManager _tabs = TabsManager.instance;
  bool _isHomeVisible = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _isHomeVisible = _tabs.selectedIndex == 0;
    _tabs.addListener(_onTabsChanged);
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabsChanged);
    super.dispose();
  }

  void _onTabsChanged() {
    final isHomeVisible = _tabs.selectedIndex == 0;
    if (_isHomeVisible == isHomeVisible || !mounted) return;
    setState(() => _isHomeVisible = isHomeVisible);
  }

  void _refresh() {
    _categoryKey.currentState?.refresh();
    _storageKey.currentState?.refresh();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 900) {
          // desktop layout stub
          return Center(
            child: Text(
              'Desktop Home (stub)',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          );
        }

        // mobile layout
        return Scaffold(
          appBar: AppBar(
            leading: Consumer(
              builder: (context, ref, _) {
                return IconButton(
                  icon: const Icon(Icons.menu),
                  onPressed: () =>
                      ref.read(settingsPanelProvider.notifier).toggle(),
                );
              },
            ),
            title: const Text('Home', style: TextStyle(fontSize: 19)),
            actions: [
              IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh)),
              IconButton(onPressed: () {}, icon: const Icon(Icons.search)),
            ],
          ),
          body: Column(
            children: [
              SizedBox(height: 145, child: _CategoryCards(key: _categoryKey)),
              Expanded(child: _QuickAccessSection()),
              SizedBox(
                height: 215,
                child: _AvailableStorageSection(
                  key: _storageKey,
                  isActive: _isHomeVisible,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CategoryCards extends StatefulWidget {
  const _CategoryCards({super.key});

  @override
  State<_CategoryCards> createState() => _CategoryCardsState();
}

class _CategoryCardsState extends State<_CategoryCards> {
  final List<Map<String, dynamic>> categories = const [
    {'name': 'Downloads', 'icon': Icons.download},
    {'name': 'Documents', 'icon': Icons.description},
    {'name': 'Images', 'icon': Icons.image},
    {'name': 'Videos', 'icon': Icons.movie},
    {'name': 'Audio', 'icon': Icons.audiotrack},
    {'name': 'Apps', 'icon': Icons.apps},
  ];

  final Map<String, Future<String?>> _categorySizes = {};

  void refresh() {
    setState(_categorySizes.clear);
  }

  Future<String?> _getCategorySize(String category) async {
    try {
      final devices = await getStorageRepository().listStorageDevices();
      if (devices.isEmpty) return null;

      final device = devices.firstWhere(
        (candidate) => candidate.id == 'internal',
        orElse: () => devices.firstWhere(
          (candidate) => candidate.id == 'external',
          orElse: () => devices.first,
        ),
      );

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
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          try {
            bytes += await entity.length();
          } catch (_) {
            // Ignore files that cannot be accessed.
          }
        }
      }
      if (bytes <= 0) {
        return '0 MB';
      }
      final mb = bytes / (1024 * 1024);
      if (mb >= 1024 * 1024) {
        return '${(mb / (1024 * 1024)).toStringAsFixed(1)} TB';
      }
      if (mb >= 1024) {
        return '${(mb / 1024).toStringAsFixed(1)} GB';
      }
      return '${mb.toStringAsFixed(1)} MB';
    } on FileSystemException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 145,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          primary: false,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemBuilder: (context, index) {
            final c = categories[index];
            return SizedBox(
              width: MediaQuery.of(context).size.width * 0.4,
              height: 137,
              child: InkWell(
                onTap: () async {
                  if (c['name'] == 'Apps') {
                    TabsManager.instance.openAppsTab();
                    return;
                  }

                  // Resolve a sensible base path (prefer internal storage, then external, then app docs)
                  final repo = getStorageRepository();
                  final devices = await repo.listStorageDevices();
                  if (!context.mounted) return;
                  final base = devices.isEmpty
                      ? null
                      : devices
                            .firstWhere(
                              (d) => d.id == 'internal',
                              orElse: () => devices.firstWhere(
                                (d) => d.id == 'external',
                                orElse: () => devices.first,
                              ),
                            )
                            .path;

                  if (base == null) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('No storage available')),
                      );
                    }
                    return;
                  }

                  final name = (c['name'] as String).toLowerCase();
                  String folder;
                  if (name.contains('download')) {
                    folder = 'Download';
                  } else if (name.contains('document')) {
                    folder = 'Documents';
                  } else if (name.contains('image')) {
                    folder = 'Pictures';
                  } else if (name.contains('video')) {
                    folder = 'Movies';
                  } else if (name.contains('audio')) {
                    folder = 'Music';
                  } else {
                    folder = '';
                  }

                  final target = folder.isEmpty ? base : '$base/$folder';
                  TabsManager.instance.openStorageTab(target);
                },
                child: Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(c['icon'] as IconData, size: 36),
                        const SizedBox(height: 12),
                        Text(
                          c['name'] as String,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        _CategorySize(
                          category: c['name'] as String,
                          loader: (category) => _categorySizes.putIfAbsent(
                            category,
                            () => _getCategorySize(category),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
          separatorBuilder: (_, _) => const SizedBox(width: 12),
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
          return Text(
            'Calculating…',
            style: Theme.of(context).textTheme.bodySmall,
          );
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recent', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'No favourites',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _AvailableStorageSection extends StatefulWidget {
  final bool isActive;

  const _AvailableStorageSection({super.key, required this.isActive});

  @override
  State<_AvailableStorageSection> createState() =>
      _AvailableStorageSectionState();
}

class _AvailableStorageSectionState extends State<_AvailableStorageSection> {
  late Future<List<StorageDevice>> _devices;

  @override
  void initState() {
    super.initState();
    _devices = getStorageRepository().listStorageDevices();
  }

  void refresh() {
    setState(() {
      _devices = getStorageRepository().listStorageDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Available Storage',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<StorageDevice>>(
              future: _devices,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final devices = snap.data ?? [];
                if (devices.isEmpty) {
                  return const Center(child: Text('No storage devices found'));
                }
                return GridView.count(
                  crossAxisCount: 2,
                  childAspectRatio: 1.7,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  shrinkWrap: true,
                  children: devices
                      .map(
                        (d) =>
                            _StorageCard(device: d, isActive: widget.isActive),
                      )
                      .toList(),
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
  final bool isActive;

  const _StorageCard({required this.device, required this.isActive});

  String _formatBytes(int? value) {
    if (value == null || value <= 0) {
      return '0 MB';
    }
    final mb = value / (1024 * 1024);
    if (mb >= 1024 * 1024) {
      return '${(mb / (1024 * 1024)).toStringAsFixed(1)} TB';
    }
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final occupied = _formatBytes(device.usedBytes);
    final total = _formatBytes(device.totalBytes);
    final totalBytes = device.totalBytes;
    final usedBytes = device.usedBytes ?? 0;
    final freePercent = totalBytes != null && totalBytes > 0
        ? (((totalBytes - usedBytes) / totalBytes) * 100).clamp(0, 100)
        : null;
    final usageText = freePercent == null
        ? 'Storage info unavailable'
        : '$occupied / $total used - ${freePercent.toStringAsFixed(1)}% free';

    return InkWell(
      onTap: () {
        TabsManager.instance.openStorageTab(
          device.path,
          title: device.name,
          allowDuplicate: true,
        );
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
                    MarqueeText(
                      device.name,
                      style: Theme.of(context).textTheme.titleSmall,
                      styleMode: MarqueeStyle.pauseAndLoop,
                      isActive: isActive,
                    ),
                    const SizedBox(height: 4),
                    MarqueeText(
                      usageText,
                      style: Theme.of(context).textTheme.labelSmall,
                      styleMode: MarqueeStyle.pauseAndLoop,
                      isActive: isActive,
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
