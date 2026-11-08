 import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/android/hive_pdf_reading_progress_repository.dart';
import '../../domain/repositories/pdf_reading_progress_repository.dart';

final pdfReadingProgressRepositoryProvider =
    Provider<PdfReadingProgressRepository>(
      (ref) => HivePdfReadingProgressRepository(),
    );
