class ExtensionParseResult {
  const ExtensionParseResult({required this.extensions, required this.errors});

  final List<String> extensions;
  final List<String> errors;
}

ExtensionParseResult parseExtensions(String input, {bool allowSemicolon = false}) {
  final errors = <String>[];
  if (input.trim().isEmpty) {
    return const ExtensionParseResult(
      extensions: [],
      errors: ['Rejected empty input: enter at least one extension.'],
    );
  }
  if (RegExp(r'(^\s*,|,\s*,|,\s*$)').hasMatch(input)) {
    errors.add('Rejected an empty extension entry around a comma.');
  }

  final extensions = <String>{};
  final separators = allowSemicolon ? r'[;,\s]+' : r'[,\s]+';
  for (final token in input.split(RegExp(separators))) {
    if (token.isEmpty) continue;
    final body = token.toLowerCase().replaceFirst(RegExp(r'^\.+'), '');
    if (body.isEmpty) {
      errors.add('Rejected "$token": it does not contain an extension name.');
    } else if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(body)) {
      errors.add(
        'Rejected "$token": use only letters, numbers, hyphens, and underscores.',
      );
    } else {
      extensions.add('.$body');
    }
  }
  final normalized = extensions.toList()..sort();
  if (normalized.isEmpty && errors.isEmpty) {
    errors.add('Rejected empty input: enter at least one extension.');
  }
  return ExtensionParseResult(extensions: normalized, errors: errors);
}
