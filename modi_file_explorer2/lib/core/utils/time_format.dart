String formatClockTime(DateTime dateTime, {required bool use24HourTime}) {
  final minute = dateTime.minute.toString().padLeft(2, '0');
  if (use24HourTime) {
    return '${dateTime.hour.toString().padLeft(2, '0')}:$minute';
  }

  final hour = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
  final period = dateTime.hour < 12 ? 'am' : 'pm';
  return '$hour:$minute $period';
}
