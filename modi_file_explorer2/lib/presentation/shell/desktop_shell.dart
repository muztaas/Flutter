import 'package:flutter/material.dart';

class DesktopShell extends StatelessWidget {
  final Widget child;
  const DesktopShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 280, child: Container(color: Theme.of(context).colorScheme.surface, child: const Center(child: Text('Home Panel')))),
        Expanded(child: child),
        SizedBox(width: 320, child: Container(color: Theme.of(context).colorScheme.surface, child: const Center(child: Text('Open Tabs')))),
      ],
    );
  }
}
