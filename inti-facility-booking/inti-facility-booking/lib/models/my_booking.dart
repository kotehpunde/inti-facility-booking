import '../utils/campus_time.dart';
import 'booking_rules.dart';

/// Badge shown on a booking ticket.
enum BookingBadge { today, upcoming, completed, cancelled }

/// One of the student's bookings, as returned by rpc/get_my_bookings.
/// A 2-hour booking is one [MyBooking] covering both slots.
class MyBooking {
  const MyBooking({
    required this.bookingRef,
    required this.facilityType,
    required this.unitName,
    required this.date,
    required this.startHour,
    required this.endHour,
    required this.isCancelled,
  });

  final String bookingRef;
  final String facilityType; // 'music' | 'pool' | 'library'
  final String unitName;
  final DateTime date; // campus date, midnight
  final int startHour; // e.g. 10
  final int endHour; // e.g. 12
  final bool isCancelled;

  factory MyBooking.fromJson(Map<String, dynamic> json) {
    final date = DateTime.parse(json['booking_date'] as String); // "2026-10-15"
    return MyBooking(
      bookingRef: json['booking_ref'] as String,
      facilityType: json['facility_type'] as String,
      unitName: json['unit_name'] as String,
      date: DateTime(date.year, date.month, date.day),
      startHour: (json['start_hour'] as num).toInt(),
      endHour: (json['end_hour'] as num).toInt(),
      isCancelled: json['status'] == 'cancelled',
    );
  }

  FacilityRules get rules => FacilityRules.forType(facilityType);

  /// "Pool Table"
  String get facilityName => rules.displayName;

  /// Start and end as campus wall-clock times.
  DateTime get startsAt => DateTime(date.year, date.month, date.day, startHour);
  DateTime get endsAt => DateTime(date.year, date.month, date.day, endHour);

  int get hours => endHour - startHour;

  /// TODAY / UPCOMING / COMPLETED / CANCELLED, compared with campus time now.
  BookingBadge get badge {
    if (isCancelled) return BookingBadge.cancelled;
    final n = CampusTime.now();
    final now = DateTime(n.year, n.month, n.day, n.hour, n.minute);
    if (!endsAt.isAfter(now)) return BookingBadge.completed;
    if (CampusTime.isSameDay(date, now)) return BookingBadge.today;
    return BookingBadge.upcoming;
  }

  bool get isActive =>
      badge == BookingBadge.today || badge == BookingBadge.upcoming;

  /// Can still be cancelled: confirmed and the first hour hasn't started.
  bool get canCancel {
    if (isCancelled) return false;
    final n = CampusTime.now();
    final now = DateTime(n.year, n.month, n.day, n.hour, n.minute);
    return startsAt.isAfter(now);
  }
}
