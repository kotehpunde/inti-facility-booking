import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/my_booking.dart';
import '../models/schedule_entry.dart';
import '../utils/campus_time.dart';

/// A booking error with a stable code from bookings.sql.
class BookingFailure implements Exception {
  const BookingFailure(this.code, this.message);

  final String code;
  final String message;

  static const dailyLimit = 'INT20'; // over 2 hours/day
  static const slotTaken = 'INT21'; // someone else booked it first
  static const invalidSlot = 'INT22'; // past, outside hours, not back-to-back
  static const invalidUnit = 'INT23';
  static const cannotCancel = 'INT24'; // already started or already cancelled
  static const closedForMaintenance = 'INT25';
  static const sessionExpired = '28000';
  static const network = 'NETWORK';

  @override
  String toString() => 'BookingFailure($code): $message';
}

/// Which slots of one unit on one date are taken.
class SlotAvailability {
  const SlotAvailability({
    required this.booked,
    required this.mine,
    required this.myHoursToday,
  });

  /// Start hours booked by anyone (includes [mine]).
  final Set<int> booked;

  /// Start hours booked by the current student on this unit.
  final Set<int> mine;

  /// Hours the student already has on this date for this facility (all units).
  final int myHoursToday;

  static const empty = SlotAvailability(booked: {}, mine: {}, myHoursToday: 0);

  factory SlotAvailability.fromJson(Map<String, dynamic> json) {
    Set<int> hours(Object? list) =>
        {for (final h in (list as List<dynamic>? ?? const [])) (h as num).toInt()};
    return SlotAvailability(
      booked: hours(json['booked']),
      mine: hours(json['mine']),
      myHoursToday: (json['my_hours_today'] as num?)?.toInt() ?? 0,
    );
  }
}

/// What rpc/create_booking returns.
class BookingResult {
  const BookingResult({
    required this.bookingRef,
    required this.unitName,
    required this.startHour,
    required this.endHour,
  });

  final String bookingRef;
  final String unitName;
  final int startHour;
  final int endHour;

  factory BookingResult.fromJson(Map<String, dynamic> json) => BookingResult(
        bookingRef: json['booking_ref'] as String,
        unitName: json['unit_name'] as String,
        startHour: (json['start_hour'] as num).toInt(),
        endHour: (json['end_hour'] as num).toInt(),
      );
}

/// Calls the booking functions in Supabase (see bookings.sql).
class BookingService {
  BookingService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<SlotAvailability> getAvailability({
    required String token,
    required String facilityType,
    required String unitName,
    required DateTime date,
  }) async {
    final data = await _call(() => _client.rpc('get_slot_availability', params: {
          'p_token': token,
          'p_facility_type': facilityType,
          'p_unit_name': unitName,
          'p_date': CampusTime.isoDate(date),
        }));
    return SlotAvailability.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<BookingResult> createBooking({
    required String token,
    required String facilityType,
    required String unitName,
    required DateTime date,
    required List<int> startHours,
  }) async {
    final data = await _call(() => _client.rpc('create_booking', params: {
          'p_token': token,
          'p_facility_type': facilityType,
          'p_unit_name': unitName,
          'p_date': CampusTime.isoDate(date),
          'p_start_hours': startHours,
        }));
    return BookingResult.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// The student's bookings: everything upcoming plus the last 60 days.
  Future<List<MyBooking>> getMyBookings(String token) async {
    final data = await _call(
        () => _client.rpc('get_my_bookings', params: {'p_token': token}));
    return [
      for (final row in (data as List<dynamic>? ?? const []))
        MyBooking.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  /// Every confirmed booking on campus from today to 14 days ahead,
  /// in date and time order. Bookers are identified by first name only.
  Future<List<ScheduleEntry>> getMasterSchedule(String token) async {
    final data = await _call(
        () => _client.rpc('get_master_schedule', params: {'p_token': token}));
    return [
      for (final row in (data as List<dynamic>? ?? const []))
        ScheduleEntry.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  /// Cancels a whole booking (both hours of a 2-hour booking).
  Future<void> cancelBooking({
    required String token,
    required String bookingRef,
  }) async {
    await _call(() => _client.rpc('cancel_booking', params: {
          'p_token': token,
          'p_booking_ref': bookingRef,
        }));
  }

  /// Which units of a facility are open: {'Room 1': true, 'Room 3': false}.
  /// Returns an empty map on error (the screen then treats all as open;
  /// the database still blocks bookings on closed units).
  Future<Map<String, bool>> getUnitStatus(String facilityType) async {
    try {
      final rows = await _client
          .from('facility_units')
          .select('unit_name, is_active')
          .eq('facility_type', facilityType);
      return {
        for (final r in rows)
          r['unit_name'] as String: (r['is_active'] as bool?) ?? true,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Confirmed bookings per hour (8 AM … 5 PM start) over the last 8 weeks.
  /// Returns an empty list if it can't be loaded; the chart then shows
  /// typical campus busyness instead.
  Future<List<int>> getHourlyBusyness(String facilityType) async {
    try {
      final data = await _client
          .rpc('get_hourly_busyness', params: {'p_facility_type': facilityType});
      return [for (final n in (data as List<dynamic>? ?? const [])) (n as num).toInt()];
    } catch (_) {
      return const [];
    }
  }

  Future<dynamic> _call(Future<dynamic> Function() request) async {
    try {
      return await request();
    } on PostgrestException catch (e) {
      throw BookingFailure(e.code ?? '', e.message);
    } catch (_) {
      throw const BookingFailure(
        BookingFailure.network,
        "Can't reach the server. Check your connection and try again.",
      );
    }
  }
}
