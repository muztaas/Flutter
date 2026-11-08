import 'dart:convert';
import 'dart:typed_data';

import '../entities/detected_file_content.dart';

class FileContentSniffer {
  const FileContentSniffer();

  DetectedFileContent sniff(Uint8List bytes) {
    if (_startsWith(bytes, const [
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ])) {
      return _image('PNG', 'image/png');
    }
    if (_startsWith(bytes, const [0xff, 0xd8, 0xff])) {
      return _image('JPEG', 'image/jpeg');
    }
    if (_asciiAt(bytes, 0, 'GIF87a') || _asciiAt(bytes, 0, 'GIF89a')) {
      return _image('GIF', 'image/gif');
    }
    if (_asciiAt(bytes, 0, 'RIFF') && _asciiAt(bytes, 8, 'WEBP')) {
      return _image('WebP', 'image/webp');
    }
    if (_asciiAt(bytes, 0, 'BM')) return _image('BMP', 'image/bmp');

    if (_asciiAt(bytes, 0, '%PDF-')) {
      return const DetectedFileContent(
        name: 'PDF document',
        category: 'Documents',
        mimeType: 'application/pdf',
      );
    }
    if (_isDocxZip(bytes)) {
      return const DetectedFileContent(
        name: 'DOCX document',
        category: 'Documents',
        mimeType:
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
    }
    if (_isXlsxZip(bytes)) {
      return const DetectedFileContent(
        name: 'XLSX spreadsheet',
        category: 'Documents',
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      );
    }
    if (_isPptxZip(bytes)) {
      return const DetectedFileContent(
        name: 'PPTX presentation',
        category: 'Documents',
        mimeType:
            'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      );
    }
    if (_startsWith(bytes, const [0x50, 0x4b, 0x03, 0x04]) ||
        _startsWith(bytes, const [0x50, 0x4b, 0x05, 0x06]) ||
        _startsWith(bytes, const [0x50, 0x4b, 0x07, 0x08])) {
      return const DetectedFileContent(
        name: 'ZIP archive',
        category: 'Archives',
        mimeType: 'application/zip',
      );
    }
    if (_startsWith(bytes, const [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c])) {
      return const DetectedFileContent(
        name: '7z archive',
        category: 'Archives',
        mimeType: 'application/x-7z-compressed',
      );
    }
    if (_asciiAt(bytes, 0, 'Rar!\x1a\x07')) {
      return const DetectedFileContent(
        name: 'RAR archive',
        category: 'Archives',
        mimeType: 'application/vnd.rar',
      );
    }
    if (_startsWith(bytes, const [0x1f, 0x8b])) {
      return const DetectedFileContent(
        name: 'gzip archive',
        category: 'Archives',
        mimeType: 'application/gzip',
      );
    }

    final isoBrand = _isoBrand(bytes);
    if (isoBrand != null) {
      if (const {'avif', 'avis'}.contains(isoBrand)) {
        return _image('AVIF', 'image/avif');
      }
      if (const {
        'heic',
        'heix',
        'hevc',
        'hevx',
        'mif1',
        'msf1',
      }.contains(isoBrand)) {
        return _image('HEIC', 'image/heic');
      }
      if (const {'M4A ', 'M4B ', 'M4P ', 'F4A ', 'F4B '}.contains(isoBrand)) {
        return const DetectedFileContent(
          name: 'MPEG-4 audio',
          category: 'Audio',
          mimeType: 'audio/mp4',
        );
      }
      if (const {
        'isom',
        'iso2',
        'mp41',
        'mp42',
        'avc1',
        'mp4v',
        'M4VH',
        'M4VP',
        'MSNV',
        'F4V ',
      }.contains(isoBrand)) {
        return const DetectedFileContent(
          name: 'MPEG-4 video',
          category: 'Video',
          mimeType: 'video/mp4',
        );
      }
      if (isoBrand == 'qt  ' || isoBrand.startsWith('M4V')) {
        final isQuickTime = isoBrand == 'qt  ';
        return DetectedFileContent(
          name: isQuickTime ? 'QuickTime video' : 'M4V video',
          category: 'Video',
          mimeType: isQuickTime ? 'video/quicktime' : 'video/x-m4v',
        );
      }
      if (isoBrand.startsWith('3gp') || isoBrand.startsWith('3g2')) {
        final isThreeGpp2 = isoBrand.startsWith('3g2');
        return DetectedFileContent(
          name: isThreeGpp2 ? '3GPP2 video' : '3GPP video',
          category: 'Video',
          mimeType: isThreeGpp2 ? 'video/3gpp2' : 'video/3gpp',
        );
      }
    }

    if (_startsWith(bytes, const [0x1a, 0x45, 0xdf, 0xa3])) {
      final isWebm = _containsAscii(bytes, 'webm');
      return DetectedFileContent(
        name: isWebm ? 'WebM video' : 'Matroska media',
        category: 'Video',
        mimeType: isWebm ? 'video/webm' : 'video/x-matroska',
      );
    }
    if (_asciiAt(bytes, 0, 'RIFF') && _asciiAt(bytes, 8, 'AVI ')) {
      return const DetectedFileContent(
        name: 'AVI video',
        category: 'Video',
        mimeType: 'video/x-msvideo',
      );
    }
    if (_asciiAt(bytes, 0, 'RIFF') && _asciiAt(bytes, 8, 'WAVE')) {
      return const DetectedFileContent(
        name: 'WAV audio',
        category: 'Audio',
        mimeType: 'audio/wav',
      );
    }
    if (_asciiAt(bytes, 0, 'fLaC')) return _audio('FLAC', 'audio/flac');
    if (_asciiAt(bytes, 0, 'OggS')) {
      return _audio('Ogg audio', 'audio/ogg');
    }
    if (_asciiAt(bytes, 0, 'ID3') ||
        (bytes.length >= 2 && bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0)) {
      return _audio('MPEG audio', 'audio/mpeg');
    }
    if (_asciiAt(bytes, 0, 'ADIF') ||
        (bytes.length >= 2 && bytes[0] == 0xff && (bytes[1] & 0xf6) == 0xf0)) {
      return _audio('AAC audio', 'audio/aac');
    }
    if (_asciiAt(bytes, 0, 'FORM') && _asciiAt(bytes, 8, 'AIFF')) {
      return _audio('AIFF audio', 'audio/aiff');
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0 &&
        bytes[1] == 0 &&
        bytes[2] == 1 &&
        (bytes[3] == 0xba || bytes[3] == 0xb3)) {
      return const DetectedFileContent(
        name: 'MPEG video',
        category: 'Video',
        mimeType: 'video/mpeg',
      );
    }

    final delimitedTextMimeType = _delimitedTextMimeType(bytes);
    if (delimitedTextMimeType != null) {
      return DetectedFileContent(
        name: 'CSV spreadsheet',
        category: 'Documents',
        mimeType: delimitedTextMimeType,
      );
    }

    if (bytes.contains(0)) {
      return DetectedFileContent.unknown;
    }
    final decoded = utf8.decode(bytes, allowMalformed: true);
    if (decoded.isEmpty) {
      return const DetectedFileContent(
        name: 'text',
        category: 'Text',
        mimeType: 'text/plain',
      );
    }
    final runes = decoded.runes.toList(growable: false);
    final replacements = runes.where((rune) => rune == 0xfffd).length;
    final invalidRatio = replacements / runes.length;
    final controls = runes
        .where(
          (rune) =>
              rune < 0x20 &&
              rune != 0x09 &&
              rune != 0x0a &&
              rune != 0x0c &&
              rune != 0x0d,
        )
        .length;
    if (invalidRatio > 0.1 || controls / runes.length > 0.1) {
      return DetectedFileContent.unknown;
    }
    return const DetectedFileContent(
      name: 'text',
      category: 'Text',
      mimeType: 'text/plain',
    );
  }

  DetectedFileContent _image(String name, String mimeType) =>
      DetectedFileContent(
        name: '$name image',
        category: 'Image',
        mimeType: mimeType,
      );

  DetectedFileContent _audio(String name, String mimeType) =>
      DetectedFileContent(name: name, category: 'Audio', mimeType: mimeType);

  String? _isoBrand(Uint8List bytes) {
    if (bytes.length < 12 || !_asciiAt(bytes, 4, 'ftyp')) return null;
    return String.fromCharCodes(bytes.sublist(8, 12));
  }

  bool _startsWith(Uint8List bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[index] != prefix[index]) return false;
    }
    return true;
  }

  bool _asciiAt(Uint8List bytes, int offset, String value) {
    if (bytes.length < offset + value.length) return false;
    for (var index = 0; index < value.length; index++) {
      if (bytes[offset + index] != value.codeUnitAt(index)) return false;
    }
    return true;
  }

  bool _containsAscii(Uint8List bytes, String value) {
    for (var offset = 0; offset <= bytes.length - value.length; offset++) {
      if (_asciiAt(bytes, offset, value)) return true;
    }
    return false;
  }

  bool _isXlsxZip(Uint8List bytes) {
    return _hasZipEntries(bytes, '[Content_Types].xml', 'xl/workbook.xml');
  }

  bool _isDocxZip(Uint8List bytes) {
    return _hasZipEntries(bytes, '[Content_Types].xml', 'word/document.xml');
  }

  bool _isPptxZip(Uint8List bytes) {
    return _hasZipEntries(
      bytes,
      '[Content_Types].xml',
      'ppt/presentation.xml',
    );
  }

  bool _hasZipEntries(
    Uint8List bytes,
    String requiredFirst,
    String requiredSecond,
  ) {
    var hasFirst = false;
    var hasSecond = false;
    for (var offset = 0; offset + 30 <= bytes.length; offset++) {
      if (!_startsWithAt(bytes, offset, const [0x50, 0x4b, 0x03, 0x04])) {
        continue;
      }
      final nameLength = bytes[offset + 26] | (bytes[offset + 27] << 8);
      final extraLength = bytes[offset + 28] | (bytes[offset + 29] << 8);
      final nameStart = offset + 30;
      final nameEnd = nameStart + nameLength;
      if (nameEnd > bytes.length) continue;
      final name = String.fromCharCodes(bytes.sublist(nameStart, nameEnd));
      hasFirst |= name == requiredFirst;
      hasSecond |= name == requiredSecond;
      if (hasFirst && hasSecond) return true;
      final compressedSizeOffset = offset + 18;
      final compressedSize = bytes[compressedSizeOffset] |
          (bytes[compressedSizeOffset + 1] << 8) |
          (bytes[compressedSizeOffset + 2] << 16) |
          (bytes[compressedSizeOffset + 3] << 24);
      final nextEntry = nameEnd + extraLength + compressedSize;
      if (compressedSize > 0 && nextEntry > offset && nextEntry < bytes.length) {
        offset = nextEntry - 1;
      }
    }
    return false;
  }

  bool _startsWithAt(Uint8List bytes, int offset, List<int> prefix) {
    if (offset + prefix.length > bytes.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[offset + index] != prefix[index]) return false;
    }
    return true;
  }

  String? _delimitedTextMimeType(Uint8List bytes) {
    final isUtf16 =
        _startsWith(bytes, const [0xff, 0xfe]) ||
        _startsWith(bytes, const [0xfe, 0xff]);
    if (!isUtf16 && bytes.contains(0)) return null;

    var offset = 0;
    var utf16LittleEndian = false;
    var utf16BigEndian = false;
    if (_startsWith(bytes, const [0xef, 0xbb, 0xbf])) {
      offset = 3;
    } else if (_startsWith(bytes, const [0xff, 0xfe])) {
      offset = 2;
      utf16LittleEndian = true;
    } else if (_startsWith(bytes, const [0xfe, 0xff])) {
      offset = 2;
      utf16BigEndian = true;
    }

    const delimiters = [0x2c, 0x3b, 0x09, 0x7c];
    final recordCounts = <int, List<int>>{
      for (final delimiter in delimiters) delimiter: <int>[],
    };
    var counts = <int, int>{for (final delimiter in delimiters) delimiter: 0};
    var inQuotes = false;
    var atFieldStart = true;
    var foundMultipleDelimitersInRecord = false;
    var unitIndex = offset;
    while (unitIndex < bytes.length) {
      final unit = utf16LittleEndian
          ? (unitIndex + 1 < bytes.length
                ? bytes[unitIndex] | (bytes[unitIndex + 1] << 8)
                : -1)
          : utf16BigEndian
          ? (unitIndex + 1 < bytes.length
                ? (bytes[unitIndex] << 8) | bytes[unitIndex + 1]
                : -1)
          : bytes[unitIndex];
      final width = utf16LittleEndian || utf16BigEndian ? 2 : 1;
      unitIndex += width;
      if (unit < 0) break;
      if (unit == 0x22) {
        if (inQuotes &&
            unitIndex + width <= bytes.length &&
            _readSniffCodeUnit(
                  bytes,
                  unitIndex,
                  utf16LittleEndian: utf16LittleEndian,
                  utf16BigEndian: utf16BigEndian,
                ) ==
                0x22) {
          unitIndex += width;
        } else if (atFieldStart || inQuotes) {
          inQuotes = !inQuotes;
          atFieldStart = false;
        }
      } else if (!inQuotes && delimiters.contains(unit)) {
        counts[unit] = counts[unit]! + 1;
        foundMultipleDelimitersInRecord |= counts[unit]! >= 2;
        atFieldStart = true;
      } else if (!inQuotes && (unit == 0x0a || unit == 0x0d)) {
        for (final delimiter in delimiters) {
          recordCounts[delimiter]!.add(counts[delimiter]!);
          counts[delimiter] = 0;
        }
        atFieldStart = true;
      } else if (!inQuotes) {
        atFieldStart = false;
      }
    }
    for (final delimiter in delimiters) {
      if (counts[delimiter] != 0) {
        recordCounts[delimiter]!.add(counts[delimiter]!);
      }
    }
    if (!foundMultipleDelimitersInRecord) {
      for (final delimiter in delimiters) {
        final nonEmpty = recordCounts[delimiter]!
            .where((count) => count > 0)
            .toList();
        if (nonEmpty.length < 2) continue;
        final firstCount = nonEmpty.first;
        if (nonEmpty.every((count) => count == firstCount)) {
          foundMultipleDelimitersInRecord = true;
          break;
        }
      }
    }
    if (!foundMultipleDelimitersInRecord) return null;

    final tabCount = recordCounts[0x09]!.fold<int>(0, (a, b) => a + b);
    return tabCount > 0 ? 'text/tab-separated-values' : 'text/csv';
  }

  int _readSniffCodeUnit(
    Uint8List bytes,
    int offset, {
    required bool utf16LittleEndian,
    required bool utf16BigEndian,
  }) {
    if (utf16LittleEndian) return bytes[offset] | (bytes[offset + 1] << 8);
    if (utf16BigEndian) return (bytes[offset] << 8) | bytes[offset + 1];
    return bytes[offset];
  }
}
