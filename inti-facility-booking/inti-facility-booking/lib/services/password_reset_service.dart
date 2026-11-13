import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/campus_time.dart';

/// A password-reset error with a stable code from password_resets.sql.
class ResetFailure implements Exception {
  const ResetFailure(this.code, this.message, {this.attemptsLeft});

  final String code;
  final String message;

  /// Wrong-passcode tries left before the ticket locks (INT33 only).
  final int? attemptsLeft;

  // Request
  static const noAccount = 'INT30';
  static const emailMismatch = 'INT31';
  static const inactive = 'INT32';
  // Complete
  static const wrongPasscode = 'INT33';
  static const ticketNotFound = 'INT34';
  static const notApproved = 'INT35';
  static const ticketInvalid = 'INT36';
  static const ticketLocked = 'INT37';
  static const passwordInvalid = 'INT05';
  // Admin
  static const ticketClosed = 'INT38';
  static const sessionExpired = '28000';
  static const forbidden = '42501';
  static const network = 'NETWORK';

  @override
  String toString() => 'ResetFailure($code): $message';
}

/// What a student gets after requesting a reset.
class ResetTicket {
  const ResetTicket({
    required this.ticketNo,
    required this.status,
    required this.alreadyOpen,
  });

  final String ticketNo; // "R-1234"
  final String status; // 'pending' or 'approved'
  final bool alreadyOpen; // true if an existing open ticket was returned
}

/// One open ticket, as the admin sees it.
class AdminResetTicket {
  const AdminResetTicket({
    required this.id,
    required this.ticketNo,
    required this.status,
    required this.studentId,
    required this.email,
    required this.name,
    required this.requestedAt,
    this.expiresAt,
  });

  final String id;
  final String ticketNo;
  final String status; // 'pending' | 'approved'
  final String studentId;
  final String email;
  final String name;
  final DateTime requestedAt; // campus time
  final DateTime? expiresAt; // campus time, when approved

  bool get isPending => status == 'pending';

  factory AdminResetTicket.fromJson(Map<String, dynamic> json) =>
      AdminResetTicket(
        id: json['id'] as String,
        ticketNo: json['ticket_no'] as String,
        status: json['status'] as String,
        studentId: (json['student_id'] as String?) ?? '-',
        email: json['email'] as String,
        name: json['name'] as String,
        requestedAt: CampusTime.fromServer(json['requested_at'] as String),
        expiresAt: json['expires_at'] == null
            ? null
            : CampusTime.fromServer(json['expires_at'] as String),
      );
}

/// The passcode returned once when an admin approves a ticket.
class ApprovedPasscode {
  const ApprovedPasscode({
    required this.ticketNo,
    required this.passcode,
    required this.expiresAt,
  });

  final String ticketNo;
  final String passcode;
  final DateTime expiresAt; // campus time
}

/// Calls the password-reset functions in Supabase.
class PasswordResetService {
  PasswordResetService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  // ---- Student ----

  Future<ResetTicket> requestReset({
    required String studentId,
    required String email,
  }) async {
    final data = await _call(() => _client.rpc('request_password_reset', params: {
          'p_student_id': studentId,
          'p_email': email,
        }));
    final map = Map<String, dynamic>.from(data as Map);
    return ResetTicket(
      ticketNo: map['ticket_no'] as String,
      status: map['status'] as String,
      alreadyOpen: map['already_open'] == true,
    );
  }

  /// Sets the new password. Throws [ResetFailure] on any problem; a wrong
  /// passcode includes [ResetFailure.attemptsLeft].
  Future<void> completeReset({
    required String ticketNo,
    required String studentId,
    required String passcode,
    required String newPassword,
  }) async {
    final data = await _call(() => _client.rpc('complete_password_reset', params: {
          'p_ticket_no': ticketNo,
          'p_student_id': studentId,
          'p_passcode': passcode,
          'p_new_password': newPassword,
        }));
    final map = Map<String, dynamic>.from(data as Map);
    if (map['ok'] != true) {
      throw ResetFailure(
        map['code'] as String? ?? '',
        map['message'] as String? ?? 'Could not reset your password.',
        attemptsLeft: (map['attempts_left'] as num?)?.toInt(),
      );
    }
  }

  // ---- Admin ----

  Future<List<AdminResetTicket>> listOpenTickets(String token) async {
    final data = await _call(
        () => _client.rpc('admin_list_reset_tickets', params: {'p_token': token}));
    return [
      for (final row in (data as List<dynamic>? ?? const []))
        AdminResetTicket.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  Future<ApprovedPasscode> approve({
    required String token,
    required String ticketId,
  }) async {
    final data = await _call(() => _client.rpc('admin_approve_reset', params: {
          'p_token': token,
          'p_ticket_id': ticketId,
        }));
    final map = Map<String, dynamic>.from(data as Map);
    return ApprovedPasscode(
      ticketNo: map['ticket_no'] as String,
      passcode: map['passcode'] as String,
      expiresAt: CampusTime.fromServer(map['expires_at'] as String),
    );
  }

  Future<void> reject({required String token, required String ticketId}) async {
    await _call(() => _client.rpc('admin_reject_reset', params: {
          'p_token': token,
          'p_ticket_id': ticketId,
        }));
  }

  Future<dynamic> _call(Future<dynamic> Function() request) async {
    try {
      return await request();
    } on PostgrestException catch (e) {
      throw ResetFailure(e.code ?? '', e.message);
    } catch (_) {
      throw const ResetFailure(
        ResetFailure.network,
        "Can't reach the server. Check your connection and try again.",
      );
    }
  }
}
