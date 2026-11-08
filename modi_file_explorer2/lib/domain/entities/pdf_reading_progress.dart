class PdfReadingProgress {
  const PdfReadingProgress({
    required this.pageNumber,
    required this.pageFraction,
    required this.pageCount,
    required this.fileSize,
    required this.modifiedTimeMilliseconds,
    required this.lastOpenedTimeMilliseconds,
  });

  final int pageNumber;
  final double pageFraction;
  final int pageCount;
  final int fileSize;
  final int modifiedTimeMilliseconds;
  final int lastOpenedTimeMilliseconds;

  Map<String, Object?> toJson() => {
    'pageNumber': pageNumber,
    'pageFraction': pageFraction,
    'pageCount': pageCount,
    'fileSize': fileSize,
    'modifiedTimeMilliseconds': modifiedTimeMilliseconds,
    'lastOpenedTimeMilliseconds': lastOpenedTimeMilliseconds,
  };

  factory PdfReadingProgress.fromJson(Map<dynamic, dynamic> json) =>
      PdfReadingProgress(
        pageNumber: json['pageNumber'] as int,
        pageFraction: (json['pageFraction'] as num).toDouble(),
        pageCount: json['pageCount'] as int,
        fileSize: json['fileSize'] as int,
        modifiedTimeMilliseconds: json['modifiedTimeMilliseconds'] as int,
        lastOpenedTimeMilliseconds: json['lastOpenedTimeMilliseconds'] as int,
      );
}
