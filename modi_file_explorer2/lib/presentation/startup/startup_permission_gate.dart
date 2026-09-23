import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

class StartupPermissionGate extends StatefulWidget {
  final Widget child;

  const StartupPermissionGate({super.key, required this.child});

  @override
  State<StartupPermissionGate> createState() => _StartupPermissionGateState();
}

class _StartupPermissionGateState extends State<StartupPermissionGate> with WidgetsBindingObserver {
  static const _storageChannel = MethodChannel('modi_file_explorer2/storage_volumes');
  bool _checking = true;
  bool _dialogVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
  }

  Future<bool> _hasStorageAccess() async {
    if (!Platform.isAndroid) return true;
    final storage = await Permission.storage.status;
    if (storage.isGranted || storage.isLimited) return true;
    return (await Permission.manageExternalStorage.status).isGranted;
  }

  Future<void> _checkPermissions() async {
    final allowed = await _hasStorageAccess();
    if (!mounted) return;

    if (allowed && _dialogVisible) {
      // The settings activity resumes this widget while the permission dialog
      // can still be mounted. Close that route immediately after access is
      // granted instead of waiting for another back press.
      _dialogVisible = false;
      Navigator.of(context, rootNavigator: true).pop();
    }

    setState(() => _checking = false);
    if (!allowed && !_dialogVisible) {
      _showPermissionDialog();
    }
  }

  Future<void> _showPermissionDialog() async {
    _dialogVisible = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Storage access required'),
        content: const Text(
          'Allow storage access so the app can show Internal Storage, SD cards, USB drives, and their files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await _storageChannel.invokeMethod<bool>('openStorageAccessSettings');
              } on PlatformException {
                await openAppSettings();
              }
            },
            child: const Text('Open settings'),
          ),
        ],
      ),
    );
    _dialogVisible = false;
    if (mounted) _checkPermissions();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return widget.child;
  }
}
