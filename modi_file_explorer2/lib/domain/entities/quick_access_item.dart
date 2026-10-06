class QuickAccessItem {
  const QuickAccessItem({
    required this.path,
    required this.name,
    required this.isDirectory,
  });

  final String path;
  final String name;
  final bool isDirectory;

  Map<String, Object?> toJson() => {
    'path': path,
    'name': name,
    'isDirectory': isDirectory,
  };

  factory QuickAccessItem.fromJson(Map<String, dynamic> json) =>
      QuickAccessItem(
        path: json['path'] as String,
        name: json['name'] as String,
        isDirectory: json['isDirectory'] as bool,
      );
}
