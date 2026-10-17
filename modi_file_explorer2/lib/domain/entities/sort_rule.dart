enum SortScope { all, drive, folder }

enum SortField { name, dateModified, size }

enum SortOrder { ascending, descending }

class SortRule {
  final String id;
  final SortScope scope;
  final String? targetPath;
  final String? targetDriveId;
  final bool recursive;
  final SortField field;
  final SortOrder order;
  final DateTime updatedAt;

  const SortRule({
    required this.id,
    required this.scope,
    required this.field,
    required this.order,
    required this.updatedAt,
    this.targetPath,
    this.targetDriveId,
    this.recursive = false,
  });

  factory SortRule.create({
    required SortScope scope,
    required SortField field,
    required SortOrder order,
    String? targetPath,
    String? targetDriveId,
    bool recursive = false,
    DateTime? updatedAt,
  }) {
    final normalizedTarget = targetPath == null
        ? null
        : normalizeSortPath(targetPath);
    final id = switch (scope) {
      SortScope.all => 'all',
      SortScope.drive => targetDriveId == null
          ? 'drive:$normalizedTarget'
          : 'drive-id:$targetDriveId',
      SortScope.folder => 'folder:$normalizedTarget',
    };
    return SortRule(
      id: id,
      scope: scope,
      targetPath: normalizedTarget,
      targetDriveId: scope == SortScope.drive ? targetDriveId : null,
      recursive: scope == SortScope.folder && recursive,
      field: field,
      order: order,
      updatedAt: updatedAt ?? DateTime.now().toUtc(),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'scope': scope.name,
    'targetPath': targetPath,
    'targetDriveId': targetDriveId,
    'recursive': recursive,
    'field': field.name,
    'order': order.name,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory SortRule.fromJson(Map<dynamic, dynamic> json) => SortRule(
    id: json['id'] as String,
    scope: SortScope.values.byName(json['scope'] as String),
    targetPath: json['targetPath'] as String?,
    targetDriveId: json['targetDriveId'] as String?,
    recursive: json['recursive'] as bool? ?? false,
    field: SortField.values.byName(json['field'] as String),
    order: SortOrder.values.byName(json['order'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

String normalizeSortPath(String path) {
  final normalized = path.replaceAll('\\', '/');
  if (normalized == '/') return normalized;
  return normalized.replaceFirst(RegExp(r'/+$'), '');
}
