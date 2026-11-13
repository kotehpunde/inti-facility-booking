import '../utils/campus_time.dart';
import 'booking_rules.dart';

/// Live status of a booking on the Master Schedule.
enum ScheduleStatus { inProgress, upcoming, completed }

/// One booking on the campus-wide schedule (rpc/get_master_schedule).
/// Only the booker's first name is ever sent by the database.
class ScheduleEntry {
  const ScheduleEntry({
    required this.bookingRef,
    required this.facilityType,
    required this.unitName,
    required this.date,
    required this.startHour,
    required this.endHour,
    required this.firstName,
    required this.isMine,
  });

  final String bookingRef;
  final String facilityType; // 'music' | 'pool' | 'library'
  final String unitName;
  final DateTime date; // campus date, midnight
  final int startHour;
  final int endHour;
  final String firstName;
  final bool isMine; // booked by the student viewing the schedule

  factory ScheduleEntry.fromJson(Map<String, dynamic> json) {
    final d = DateTime.parse(json['booking_date'] as String);
    return ScheduleEntry(
      bookingRef: json['booking_ref'] as String,
      facilityType: json['facility_type'] as String,
      unitName: json['unit_name'] as String,
      date: DateTime(d.year, d.month, d.day),
      startHour: (json['start_hour'] as num).toInt(),
      endHour: (json['end_hour'] as num).toInt(),
      firstName: (json['first_name'] as String?)?.trim().isNotEmpty == true
          ? json['first_name'] as String
          : 'a student',
      isMine: json['is_mine'] == true,
    );
  }

  String get facilityName => FacilityRules.forType(facilityType).displayName;

  DateTime get startsAt => DateTime(date.year, date.month, date.day, startHour);
  DateTime get endsAt => DateTime(date.year, date.month, date.day, endHour);

  /// IN PROGRESS / UPCOMING / COMPLETED, compared with campus time now.
  ScheduleStatus get status {
    final n = CampusTime.now();
    final now = DateTime(n.year, n.month, n.day, n.hour, n.minute);
    if (!endsAt.isAfter(now)) return ScheduleStatus.completed;
    if (!startsAt.isAfter(now)) return ScheduleStatus.inProgress;
    return ScheduleStatus.upcoming;
  }
}
