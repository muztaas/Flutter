import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers/settings_provider.dart';
import '../about/about_page.dart';

class SettingsPanel extends ConsumerStatefulWidget {
  /// The key attached to the tab header row. Its rendered height is used as
  /// the overlay's top edge so the header remains visible above the panel.
  const SettingsPanel({super.key, this.tabHeaderKey});

  final GlobalKey? tabHeaderKey;

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  double _tabHeaderHeight = 0;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.tabHeaderKey == null) return;
      final renderObject = widget.tabHeaderKey!.currentContext?.findRenderObject();
      if (renderObject is RenderBox && renderObject.hasSize && renderObject.size.height != _tabHeaderHeight) {
        setState(() => _tabHeaderHeight = renderObject.size.height);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(settingsPanelProvider);
    // drive animation
    if (open) {
      _anim.forward();
    } else {
      _anim.reverse();
    }

    final width = MediaQuery.of(context).size.width * 0.8;
    final topInset = MediaQuery.of(context).padding.top;

    return IgnorePointer(
      ignoring: !open,
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, child) {
          final slide = Tween<Offset>(begin: const Offset(-1, 0), end: Offset.zero).evaluate(_anim);
          return Stack(
            children: [
              Positioned(
                // The overlay is positioned in the screen-level Stack, so
                // include the status-bar inset before placing it below the
                // tab header.
                top: topInset + _tabHeaderHeight,
                left: 0,
                right: 0,
                // Cover the complete screen, including the system gesture or
                // navigation-bar area. SafeArea below keeps panel content
                // clear of that area without leaving the underlying screen
                // exposed or hit-testable.
                bottom: 0,
                child: Stack(
                  children: [
              // scrim + dismiss area (right 20%)
              GestureDetector(
                onTap: () => ref.read(settingsPanelProvider.notifier).close(),
                  child: Container(
                  width: MediaQuery.of(context).size.width,
                  height: MediaQuery.of(context).size.height,
                  color: Theme.of(context).colorScheme.onBackground.withOpacity(0.6 * _anim.value),
                ),
              ),
              // panel
              Transform.translate(
                offset: Offset(slide.dx * width, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Material(
                    color: Theme.of(context).colorScheme.surface.withOpacity(0.75),
                    child: SizedBox(
                      width: width,
                      height: double.infinity,
                      child: SafeArea(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
                                const SizedBox(height: 16),
                                ExpansionTile(
                                  title: const Text('Appearance'),
                                  children: [
                                    ListTile(
                                      title: const Text('Theme'),
                                      trailing: Switch.adaptive(value: Theme.of(context).brightness == Brightness.dark, onChanged: null),
                                    ),
                                    ListTile(
                                      title: const Text('Accent Color'),
                                      subtitle: const Text('Coming soon'),
                                      enabled: false,
                                    ),
                                  ],
                                ),
                                ExpansionTile(
                                  title: const Text('Files'),
                                  children: [
                                    ListTile(title: const Text('Show hidden files'), trailing: const Switch.adaptive(value: false, onChanged: null)),
                                    ListTile(title: const Text('Default view'), subtitle: const Text('List (default)')),
                                    ListTile(title: const Text('Font size'), subtitle: const Text('Medium')),
                                  ],
                                ),
                                ExpansionTile(
                                  title: const Text('Storage'),
                                  children: [
                                    ListTile(title: const Text('Default startup drive'), subtitle: const Text('Internal Storage')),
                                    ListTile(
                                      title: const Text('About'),
                                      onTap: () {
                                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AboutPage()));
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
