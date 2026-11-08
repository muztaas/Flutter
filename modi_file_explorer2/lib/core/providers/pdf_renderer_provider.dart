import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/android_pdf_renderer_repository.dart';
import '../../domain/repositories/pdf_renderer_repository.dart';

final pdfRendererRepositoryProvider = Provider<PdfRendererRepository>(
  (ref) => AndroidPdfRendererRepository(),
);
