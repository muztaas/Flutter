import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/storage_providers.dart';
import '../../core/tabs/tabs_manager.dart';
import '../../domain/entities/storage_device.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with AutomaticKeepAliveClientMixin<HomePage> {
  final _categoryKey = GlobalKey<_CategoryCardsState>();
  final _storageKey = GlobalKey<_AvailableStorageSectionState>();

  @override
  bool get wantKeepAlive => true;

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
                child: _AvailableStorageSection(key: _storageKey),
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
    // For now, show an empty state
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Recent', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: Text(
                'No favourites',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AvailableStorageSection extends StatefulWidget {
  const _AvailableStorageSection({super.key});

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
                      .map((d) => _StorageCard(device: d))
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
  const _StorageCard({required this.device});

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
                    _AutoScrollingText(
                      device.name,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    _AutoScrollingText(
                      usageText,
                      style: Theme.of(context).textTheme.labelSmall,
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

class _AutoScrollingText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const _AutoScrollingText(this.text, {this.style});

  @override
  State<_AutoScrollingText> createState() => _AutoScrollingTextState();
}

class _AutoScrollingTextState extends State<_AutoScrollingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _wasScrolling = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    );
  }

  @override
  void didUpdateWidget(covariant _AutoScrollingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _controller.reset();
      _controller.stop();
      _wasScrolling = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = widget.style ?? Theme.of(context).textTheme.titleSmall;

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: textStyle),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout(minWidth: 0, maxWidth: double.infinity);

        final shouldScroll = painter.width > constraints.maxWidth;
        if (!shouldScroll) {
          if (_wasScrolling) {
            _controller.stop();
            _controller.reset();
            _wasScrolling = false;
          }
          return Text(
            widget.text,
            style: textStyle,
            maxLines: 1,
            overflow: TextOverflow.visible,
            softWrap: false,
          );
        }

        if (!_controller.isAnimating && !_wasScrolling) {
          _wasScrolling = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _wasScrolling && !_controller.isAnimating) {
              _controller.repeat();
            }
          });
        }

        const gap = 32.0;
        final cycleWidth = painter.width + gap;
        // Reduce the scrolling speed by 50% for both labels.
        _controller.duration = Duration(
          milliseconds: (cycleWidth / (25 * 0.54) * 1000).round(),
        );
        return ClipRect(
          child: SizedBox(
            width: constraints.maxWidth,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final offset = -cycleWidth * _controller.value;
                return SizedBox(
                  width: constraints.maxWidth,
                  height: painter.height,
                  child: ClipRect(
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      children: [
                        Positioned(
                          left: offset,
                          top: 0,
                          child: _buildText(painter.width, textStyle),
                        ),
                        Positioned(
                          left: offset + cycleWidth,
                          top: 0,
                          child: _buildText(painter.width, textStyle),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _buildText(double width, TextStyle? style) {
    return SizedBox(
      width: width,
      child: Text(
        widget.text,
        style: style,
        maxLines: 1,
        overflow: TextOverflow.visible,
        softWrap: false,
      ),
    );
  }
}
