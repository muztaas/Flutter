class ImageFileTypes {
  const ImageFileTypes._();

  static const extensions = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.bmp',
    '.webp',
    '.heic',
    '.svg',
    '.tif',
    '.tiff',
    '.ico',
    '.avif',
    '.jfif',
  };

  static String extensionForPath(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot).toLowerCase();
  }

  static bool isImagePath(String path) =>
      extensions.contains(extensionForPath(path));

  static bool isImageExtension(String extension) =>
      extensions.contains(extension.toLowerCase());

  static bool isSvgPath(String path) => extensionForPath(path) == '.svg';
}
