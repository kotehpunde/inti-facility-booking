/// Date and time helpers that always use campus time (Malaysia, UTC+8),
/// even if the phone or emulator is set to another time zone.
/// Supabase uses the same clock (Asia/Kuala_Lumpur) when it checks bookings.
class CampusTime {
  CampusTime._();

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Current campus date and time. Malaysia has no daylight saving.
  static DateTime now() => DateTime.now().toUtc().add(const Duration(hours: 8));

  /// Today's campus date at midnight.
  static DateTime today() {
    final n = now();
    return DateTime(n.year, n.month, n.day);
  }

  static bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// "2026-10-15", the format Supabase expects for a `date`.
  static String isoDate(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}';

  /// "Wed, 15 Oct 2026"
  static String dateLabel(DateTime d) =>
      '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]} ${d.year}';

  /// "15 Oct"
  static String shortDate(DateTime d) => '${d.day} ${_months[d.month - 1]}';

  /// Converts a timestamp from Supabase (e.g. "2026-10-15T02:42:00+00:00")
  /// to campus wall-clock time.
  static DateTime fromServer(String iso) =>
      DateTime.parse(iso).toUtc().add(const Duration(hours: 8));

  /// "10:42 AM" for any campus time.
  static String clockLabel(DateTime t) {
    final suffix = t.hour < 12 ? 'AM' : 'PM';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${_two(t.minute)} $suffix';
  }

  /// "Today, 10:42 AM" or "14 Oct, 10:42 AM".
  static String dayAndClock(DateTime t) {
    final day = isSameDay(t, today()) ? 'Today' : shortDate(t);
    return '$day, ${clockLabel(t)}';
  }

  /// "10:00 – 11:00" for a 1-hour slot starting at [hour].
  static String slotLabel(int hour) => '${_two(hour)}:00 – ${_two(hour + 1)}:00';

  /// "10:00 – 12:00" for a range of hours.
  static String rangeLabel(int startHour, int endHour) =>
      '${_two(startHour)}:00 – ${_two(endHour)}:00';

  /// "8 AM", "12 PM", "2 PM"
  static String hourLabel(int hour) {
    final suffix = hour < 12 ? 'AM' : 'PM';
    final h = hour % 12 == 0 ? 12 : hour % 12;
    return '$h $suffix';
  }

  /// "10:00 AM", "2:00 PM"
  static String timeLabel(int hour) {
    final suffix = hour < 12 ? 'AM' : 'PM';
    final h = hour % 12 == 0 ? 12 : hour % 12;
    return '$h:00 $suffix';
  }

  /// Compact chart label: "8a", "12p", "2p"
  static String shortHour(int hour) {
    final h = hour % 12 == 0 ? 12 : hour % 12;
    return '$h${hour < 12 ? 'a' : 'p'}';
  }
}
