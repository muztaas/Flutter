import 'package:flutter/material.dart';

class AnimatedBarVisibility extends StatelessWidget {
  const AnimatedBarVisibility({
    super.key,
    required this.visible,
    required this.height,
    required this.child,
  });

  final bool visible;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(0, -0.25),
          duration: const Duration(milliseconds: 180),
          child: child,
        ),
      ),
    ),
  );
}