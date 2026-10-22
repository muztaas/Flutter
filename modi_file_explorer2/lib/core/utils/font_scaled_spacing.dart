import 'package:flutter/material.dart';

double fontScaledSpacing(
  BuildContext context,
  double spacing, {
  double referenceFontSize = 14,
}) {
  final textScaler = MediaQuery.textScalerOf(context);
  return spacing * textScaler.scale(referenceFontSize) / referenceFontSize;
}
