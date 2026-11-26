/// Message display only; never changes stored timestamps or elapsed time.
class MessageTime {
  static String time(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    return '${hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')} ${value.hour < 12 ? 'ص' : 'م'}';
  }

  static String dateTime(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')} ${time(value)}';
}
