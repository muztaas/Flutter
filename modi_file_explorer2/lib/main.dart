import 'dart:ui' show ImageFilter;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers/settings_provider.dart';
import 'core/theme/app_theme.dart';
import 'presentation/shell/top_level_shell.dart';
import 'presentation/startup/startup_permission_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _navigationModeChannel = MethodChannel(
  'modi_file_explorer2/navigation_mode',
);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/apache-2.0.txt');
    yield LicenseEntryWithLineBreaks(
      const [
        'AndroidX Media3 ExoPlayer 1.9.2',
        'AndroidX Media3 Common 1.9.2',
        'AndroidX Media3 Container 1.9.2',
        'AndroidX Media3 Database 1.9.2',
        'AndroidX Media3 DataSource 1.9.2',
        'AndroidX Media3 Decoder 1.9.2',
        'AndroidX Media3 Extractor 1.9.2',
        'AndroidX Annotation 1.8.1',
        'AndroidX Annotation JVM 1.8.1',
        'AndroidX Annotation Experimental 1.4.0',
        'AndroidX Collection 1.2.0',
        'AndroidX Core 1.13.1',
        'AndroidX Concurrent Futures 1.1.0',
        'AndroidX Interpolator 1.0.0',
        'AndroidX Lifecycle Runtime and Common 2.7.0',
        'AndroidX Arch Core Common and Runtime 2.2.0',
        'AndroidX ExifInterface 1.4.1',
        'AndroidX ProfileInstaller 1.3.1',
        'AndroidX Startup Runtime 1.1.1',
        'AndroidX Tracing 1.2.0',
        'AndroidX VersionedParcelable 1.1.1',
        'Google Guava Android 33.3.1-android',
        'Google FailureAccess 1.0.2',
        'Google ListenableFuture compatibility artifact',
        'Kotlin Standard Library 2.3.20',
        'Kotlin Standard Library JDK 7 and JDK 8 1.8.20',
        'kotlinx.coroutines 1.7.3',
        'JetBrains Annotations 23.0.0',
        'JSpecify 1.0.0',
      ],
      'Copyright 2022 The Android Open Source Project; AndroidX components '
      'are Copyright The Android Open Source Project; Guava is Copyright '
      'The Guava Authors; Kotlin and kotlinx.coroutines are Copyright '
      'JetBrains s.r.o. and contributors; JetBrains Annotations are '
      'Copyright JetBrains s.r.o.; JSpecify is Copyright The JSpecify '
      'Authors.\n\n$license',
    );
  });
  runApp(const ProviderScope(child: _AppBootstrap()));
}

class _AppBootstrap extends ConsumerStatefulWidget {
  const _AppBootstrap();

  @override
  ConsumerState<_AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends ConsumerState<_AppBootstrap> {
  bool _buttonNavigationEnabled = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
    unawaited(_loadNavigationMode());
  }

  Future<void> _loadSettings() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      if (!mounted) return;
      await ref
          .read(appSettingsProvider.notifier)
          .loadFromPreferences(preferences);
    } catch (error) {
      debugPrint('Could not load saved app settings: $error');
    }
  }

  Future<void> _loadNavigationMode() async {
    try {
      final enabled = await _navigationModeChannel.invokeMethod<bool>(
        'isButtonNavigationEnabled',
      );
      if (enabled != null && mounted) {
        setState(() => _buttonNavigationEnabled = enabled);
      }
    } on PlatformException catch (error) {
      debugPrint('Could not read Android navigation mode: $error');
    } on MissingPluginException catch (error) {
      debugPrint('Android navigation mode is unavailable: $error');
    }
  }

  @override
  Widget build(BuildContext context) =>
      MyApp(buttonNavigationEnabled: _buttonNavigationEnabled);
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key, required this.buttonNavigationEnabled});

  final bool buttonNavigationEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return MaterialApp(
      title: 'Modi File Explorer',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: settings.darkTheme ? ThemeMode.dark : ThemeMode.light,
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final colorScheme = Theme.of(context).colorScheme;
        final navigationBarHeight = media.viewPadding.bottom > 24
            ? media.viewPadding.bottom
            : 24.0;
        final blurHeight = (navigationBarHeight + 24) * 0.6;
        final hasButtonNavigation =
            buttonNavigationEnabled && media.viewPadding.bottom > 0;
        final baseVisualDensity = Theme.of(context).visualDensity;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: settings.darkTheme
                ? Brightness.light
                : Brightness.dark,
            statusBarBrightness: settings.darkTheme
                ? Brightness.dark
                : Brightness.light,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarIconBrightness: settings.darkTheme
                ? Brightness.light
                : Brightness.dark,
            systemNavigationBarContrastEnforced: false,
          ),
          child: Theme(
            data: Theme.of(context).copyWith(
              visualDensity: VisualDensity(
                horizontal: baseVisualDensity.horizontal,
                vertical:
                    baseVisualDensity.vertical +
                    (settings.textSizeOffset - 1) * 0.25,
              ),
            ),
            child: MediaQuery(
              data: media.copyWith(
                textScaler: _OffsetTextScaler(settings.textSizeOffset),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  child ?? const SizedBox.shrink(),
                  if (hasButtonNavigation)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: blurHeight,
                      child: IgnorePointer(
                        child: ClipRect(
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                            child: ColoredBox(
                              color: colorScheme.surface.withValues(
                                alpha: 0.3,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
      home: const StartupPermissionGate(child: TopLevelShell()),
    );
  }
}

class _OffsetTextScaler extends TextScaler {
  const _OffsetTextScaler(this.offset);

  final double offset;

  @override
  double scale(double fontSize) =>
      (fontSize + offset).clamp(1, double.infinity).toDouble();

  @override
  double get textScaleFactor => 1;
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
