import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/announcement.dart';
import '../models/booking_rules.dart';
import '../utils/campus_time.dart';
import 'session_manager.dart';

/// An admin request failed. [code] comes from admin_suite.sql.
class AdminFailure implements Exception {
  const AdminFailure(this.code, this.message);

  final String code;
  final String message;

  static const sessionExpired = '28000';
  static const forbidden = '42501'; // not an admin
  static const alreadyEnded = 'INT24';
  static const checkInNotAllowed = 'INT60'; // wrong day / too early / ended
  static const notConfirmed = 'INT61'; // already checked in, released or cancelled
  static const noShowNotAllowed = 'INT62'; // grace period not over / ended
  static const studentNotFound = 'INT63';
  static const network = 'NETWORK';

  /// True when the screen should send the user back to Login.
  bool get needsLogin => code == sessionExpired || code == forbidden;

  @override
  String toString() => 'AdminFailure($code): $message';
}

/// Numbers for the Admin Console.
class AdminStats {
  const AdminStats({
    required this.today,
    required this.weekStart,
    required this.bookingsToday,
    required this.pendingResets,
    required this.closedFacilities,
    required this.activeAnnouncements,
    required this.weekly,
  });

  final DateTime today;
  final DateTime weekStart; // Monday
  final int bookingsToday;
  final int pendingResets;
  final int closedFacilities; // facilities + units switched off
  final int activeAnnouncements;
  final List<int> weekly; // 7 values, Monday → Sunday

  factory AdminStats.fromJson(Map<String, dynamic> json) {
    DateTime date(String key) {
      final d = DateTime.parse(json[key] as String);
      return DateTime(d.year, d.month, d.day);
    }

    final weekly = [
      for (final n in (json['weekly'] as List<dynamic>? ?? const []))
        (n as num).toInt(),
    ];
    return AdminStats(
      today: date('today'),
      weekStart: date('week_start'),
      bookingsToday: (json['bookings_today'] as num).toInt(),
      pendingResets: (json['pending_resets'] as num).toInt(),
      closedFacilities: (json['closed_facilities'] as num).toInt(),
      activeAnnouncements: (json['active_announcements'] as num).toInt(),
      weekly: weekly.length == 7 ? weekly : List.filled(7, 0),
    );
  }
}

/// A booking with full student details (admins only).
class AdminBooking {
  const AdminBooking({
    required this.bookingRef,
    required this.facilityType,
    required this.unitName,
    required this.date,
    required this.startHour,
    required this.endHour,
    required this.status,
    required this.fullName,
    required this.studentId,
    required this.email,
    this.cancelReason,
    this.checkedInAt,
  });

  final String bookingRef;
  final String facilityType;
  final String unitName;
  final DateTime date;
  final int startHour;
  final int endHour;
  /// confirmed | checked_in | no_show | cancelled | admin_cancelled
  final String status;
  final String fullName;
  final String studentId;
  final String email;
  final String? cancelReason;

  /// When the admin handed over the keys (campus time), if checked in.
  final DateTime? checkedInAt;

  String get facilityName => FacilityRules.forType(facilityType).displayName;

  DateTime get startsAt => DateTime(date.year, date.month, date.day, startHour);
  DateTime get endsAt => DateTime(date.year, date.month, date.day, endHour);

  bool get isConfirmed => status == 'confirmed';
  bool get isCheckedIn => status == 'checked_in';
  bool get isNoShow => status == 'no_show';

  /// Today's confirmed booking that hasn't ended: show the counter buttons
  /// (Check-in / Release No-Show). The database checks the exact time
  /// windows and explains if it is too early.
  bool get canUseCounterActions {
    if (!isConfirmed) return false;
    final n = CampusTime.now();
    if (!CampusTime.isSameDay(date, n)) return false;
    return endsAt.isAfter(DateTime(n.year, n.month, n.day, n.hour, n.minute));
  }

  /// Can still be force-cancelled: confirmed and not finished yet.
  bool get canForceCancel {
    if (!isConfirmed) return false;
    final n = CampusTime.now();
    return endsAt.isAfter(DateTime(n.year, n.month, n.day, n.hour, n.minute));
  }

  factory AdminBooking.fromJson(Map<String, dynamic> json) {
    final d = DateTime.parse(json['booking_date'] as String);
    return AdminBooking(
      bookingRef: json['booking_ref'] as String,
      facilityType: json['facility_type'] as String,
      unitName: json['unit_name'] as String,
      date: DateTime(d.year, d.month, d.day),
      startHour: (json['start_hour'] as num).toInt(),
      endHour: (json['end_hour'] as num).toInt(),
      status: json['status'] as String,
      fullName: json['full_name'] as String,
      studentId: (json['student_id'] as String?) ?? '-',
      email: json['email'] as String,
      cancelReason: json['cancel_reason'] as String?,
      checkedInAt: json['checked_in_at'] == null
          ? null
          : CampusTime.fromServer(json['checked_in_at'] as String),
    );
  }
}

/// One row of the Student Directory (admins only).
class AdminStudentSummary {
  const AdminStudentSummary({
    required this.id,
    required this.studentId,
    required this.name,
    required this.email,
    required this.isSuspended,
    required this.createdAt,
    required this.bookingCount,
    required this.noShowCount,
    this.displayName,
  });

  final String id;
  final String studentId;
  final String name; // official name
  final String? displayName; // nickname, if set
  final String email;
  final bool isSuspended;
  final DateTime createdAt;
  final int bookingCount; // every booking ever made (any status)
  final int noShowCount;

  String get initial => name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

  factory AdminStudentSummary.fromJson(Map<String, dynamic> json) =>
      AdminStudentSummary(
        id: json['id'] as String,
        studentId: (json['student_id'] as String?) ?? '-',
        name: json['name'] as String,
        displayName: json['display_name'] as String?,
        email: json['email'] as String,
        isSuspended: json['is_suspended'] as bool? ?? false,
        createdAt: CampusTime.fromServer(json['created_at'] as String),
        bookingCount: (json['booking_count'] as num?)?.toInt() ?? 0,
        noShowCount: (json['no_show_count'] as num?)?.toInt() ?? 0,
      );
}

/// One facility's share of booked hours.
class FacilityShare {
  const FacilityShare({
    required this.facilityType,
    required this.hours,
    required this.percent,
  });

  final String facilityType; // music | pool | library
  final int hours;
  final double percent; // 0–100

  String get displayName => switch (facilityType) {
        'music' => 'Music Room',
        'pool' => 'Pool Tables',
        _ => 'Library Rooms',
      };
}

/// Utilization numbers for the last 30 days (admins only).
class AdminFacilityAnalytics {
  const AdminFacilityAnalytics({
    required this.totalHours,
    required this.shares,
    required this.noShowCount,
    this.topUnitName,
    this.topUnitFacilityType,
    this.topUnitHours = 0,
    this.peakStartHour,
    this.peakEndHour,
  });

  final int totalHours; // booked hours (confirmed + checked in)
  final List<FacilityShare> shares; // music, pool, library
  final int noShowCount;
  final String? topUnitName;
  final String? topUnitFacilityType;
  final int topUnitHours;
  final int? peakStartHour;
  final int? peakEndHour;

  bool get hasData => totalHours > 0;

  /// "Room 2" (or "Music Studio"); "–" when nothing is booked yet.
  String get topUnitLabel => topUnitName ?? '–';

  /// "12:00 PM – 2:00 PM"; "–" when nothing is booked yet.
  String get peakWindowLabel => peakStartHour == null || peakEndHour == null
      ? '–'
      : '${CampusTime.timeLabel(peakStartHour!)} – '
          '${CampusTime.timeLabel(peakEndHour!)}';

  factory AdminFacilityAnalytics.fromJson(Map<String, dynamic> json) {
    final top = json['top_unit'] == null
        ? null
        : Map<String, dynamic>.from(json['top_unit'] as Map);
    return AdminFacilityAnalytics(
      totalHours: (json['total_hours'] as num?)?.toInt() ?? 0,
      shares: [
        for (final f in (json['facilities'] as List<dynamic>? ?? const []))
          FacilityShare(
            facilityType: (f as Map)['facility_type'] as String,
            hours: (f['hours'] as num?)?.toInt() ?? 0,
            percent: (f['percent'] as num?)?.toDouble() ?? 0,
          ),
      ],
      noShowCount: (json['no_show_count'] as num?)?.toInt() ?? 0,
      topUnitName: top?['unit_name'] as String?,
      topUnitFacilityType: top?['facility_type'] as String?,
      topUnitHours: (top?['hours'] as num?)?.toInt() ?? 0,
      peakStartHour: (json['peak_start_hour'] as num?)?.toInt(),
      peakEndHour: (json['peak_end_hour'] as num?)?.toInt(),
    );
  }
}

class AdminUnit {
  const AdminUnit({required this.name, required this.isActive, this.capacity});

  final String name;
  final int? capacity;
  final bool isActive;

  String get label => capacity == null ? name : '$name · $capacity pax';
}

class AdminFacility {
  const AdminFacility({
    required this.id,
    required this.name,
    required this.facilityType,
    required this.isActive,
    required this.upcomingBookings,
    required this.units,
  });

  final String id;
  final String name;
  final String facilityType;
  final bool isActive;
  final int upcomingBookings;
  final List<AdminUnit> units;

  factory AdminFacility.fromJson(Map<String, dynamic> json) => AdminFacility(
        id: json['id'] as String,
        name: json['name'] as String,
        facilityType: (json['facility_type'] as String?) ?? '',
        isActive: json['is_active'] as bool? ?? true,
        upcomingBookings: (json['upcoming_bookings'] as num?)?.toInt() ?? 0,
        units: [
          for (final u in (json['units'] as List<dynamic>? ?? const []))
            AdminUnit(
              name: (u as Map)['unit_name'] as String,
              capacity: (u['capacity'] as num?)?.toInt(),
              isActive: u['is_active'] as bool? ?? true,
            ),
        ],
      );
}

/// All admin calls. Each one sends the admin's session token; the database
/// rejects it unless that token belongs to an admin.
class AdminService {
  AdminService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  // ---- Dashboard ----
  Future<AdminStats> stats() async => AdminStats.fromJson(
      _map(await _rpc('admin_dashboard_stats')));

  // ---- Bookings ----
  /// [scope]: 'today' | 'upcoming' | 'cancelled'
  Future<List<AdminBooking>> bookings(String scope) async => [
        for (final row in _list(await _rpc('admin_list_bookings', {'p_scope': scope})))
          AdminBooking.fromJson(row),
      ];

  Future<void> forceCancel(String bookingRef, {String? reason}) =>
      _rpc('admin_force_cancel', {'p_booking_ref': bookingRef, 'p_reason': reason});

  /// "Hand over keys": confirmed → checked_in.
  Future<void> verifyCheckIn(String bookingRef) =>
      _rpc('admin_verify_check_in', {'p_booking_ref': bookingRef});

  /// Student didn't turn up: confirmed → no_show, slot is free again.
  Future<void> releaseNoShow(String bookingRef) =>
      _rpc('admin_release_no_show', {'p_booking_ref': bookingRef});

  // ---- Students ----
  Future<List<AdminStudentSummary>> students({String? search}) async => [
        for (final row in _list(await _rpc('admin_list_students', {
          'p_search': (search == null || search.trim().isEmpty) ? null : search.trim(),
        })))
          AdminStudentSummary.fromJson(row),
      ];

  /// Suspending also logs the student out on every device.
  Future<void> toggleSuspension(String userId, bool suspend) =>
      _rpc('admin_toggle_student_suspension',
          {'p_user_id': userId, 'p_suspend': suspend});

  // ---- Analytics ----
  Future<AdminFacilityAnalytics> analytics() async =>
      AdminFacilityAnalytics.fromJson(
          _map(await _rpc('admin_facility_analytics')));

  // ---- Announcements ----
  Future<List<Announcement>> announcements() async => [
        for (final row in _list(await _rpc('admin_list_announcements')))
          Announcement.fromJson(row),
      ];

  Future<Announcement> createAnnouncement({
    required String? facilityType,
    required String headline,
    required String body,
  }) async =>
      Announcement.fromJson(_map(await _rpc('admin_create_announcement', {
        'p_facility_type': facilityType ?? '',
        'p_headline': headline,
        'p_body': body,
      })));

  Future<void> setAnnouncementActive(String id, bool active) =>
      _rpc('admin_set_announcement_active', {'p_id': id, 'p_active': active});

  Future<void> deleteAnnouncement(String id) =>
      _rpc('admin_delete_announcement', {'p_id': id});

  // ---- Maintenance ----
  Future<List<AdminFacility>> facilities() async => [
        for (final row in _list(await _rpc('admin_list_facilities')))
          AdminFacility.fromJson(row),
      ];

  Future<void> setFacilityActive(String facilityId, bool active) =>
      _rpc('admin_set_facility_active',
          {'p_facility_id': facilityId, 'p_active': active});

  Future<void> setUnitActive(String facilityType, String unitName, bool active) =>
      _rpc('admin_set_unit_active', {
        'p_facility_type': facilityType,
        'p_unit_name': unitName,
        'p_active': active,
      });

  // ---- Plumbing ----

  /// Calls an admin RPC with the saved session token added.
  Future<dynamic> _rpc(String fn, [Map<String, dynamic> params = const {}]) async {
    final token = await SessionManager.token();
    if (token == null) {
      throw const AdminFailure(AdminFailure.sessionExpired, 'Please log in again.');
    }
    try {
      return await _client.rpc(fn, params: {'p_token': token, ...params});
    } on PostgrestException catch (e) {
      throw AdminFailure(e.code ?? '', e.message);
    } catch (_) {
      throw const AdminFailure(
        AdminFailure.network,
        "Can't reach the server. Check your connection and try again.",
      );
    }
  }

  static Map<String, dynamic> _map(dynamic data) =>
      Map<String, dynamic>.from(data as Map);

  static List<Map<String, dynamic>> _list(dynamic data) => [
        for (final row in (data as List<dynamic>? ?? const []))
          Map<String, dynamic>.from(row as Map),
      ];
}
