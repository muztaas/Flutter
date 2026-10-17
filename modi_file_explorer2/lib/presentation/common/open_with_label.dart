String shortenOpenWithAppName(String value) {
  if (value.length <= 50) return value;
  return '${value.substring(0, 40)}...${value.substring(value.length - 10)}';
}

String shortenOpenWithHeading(String value) {
  if (value.length <= 85) return value;
  return '${value.substring(0, 70)}...${value.substring(value.length - 15)}';
}

String openAsFileHeading(String fileName) {
  final heading = 'Open ${shortenOpenWithAppName(fileName)} as';
  return shortenOpenWithHeading(heading);
}
