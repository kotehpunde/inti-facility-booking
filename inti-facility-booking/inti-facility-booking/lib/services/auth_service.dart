import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../models/app_user.dart';

/// An auth error with a stable code (INT01…INT12 from auth_v2.sql,
/// or [AuthFailure.network] when Supabase could not be reached).
class AuthFailure implements Exception {
  const AuthFailure(this.code, this.message);

  final String code;
  final String message;

  // Signup
  static const notInRoster = 'INT01';
  static const rosterInactive = 'INT02';
  static const alreadyRegistered = 'INT03';
  static const emailMismatch = 'INT04';
  static const passwordInvalid = 'INT05';
  static const nameInvalid = 'INT06';
  // Login
  static const accountNotFound = 'INT10';
  static const wrongPassword = 'INT11';
  static const loginInactive = 'INT12';
  static const accountSuspended = 'INT13'; // admin_enhancements.sql
  // Profile (profile.sql)
  static const nicknameInvalid = 'INT40';
  static const currentPasswordWrong = 'INT41';
  static const samePassword = 'INT42';
  // Session (raised by app_require_role in schema.sql)
  static const sessionExpired = '28000';
  // Client side
  static const network = 'NETWORK';

  @override
  String toString() => 'AuthFailure($code): $message';
}

/// Talks to the Supabase SQL functions (RPCs). The app never reads the
/// users table directly, so password hashes never reach the phone:
/// bcrypt hashing and checking both happen inside PostgreSQL.
class AuthService {
  AuthService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Unified login for students and admins (email or Student ID).
  Future<Session> login(String identifier, String password) async {
    final data = await _call(() => _client.rpc('login', params: {
          'p_identifier': identifier,
          'p_password': password,
        }));
    final map = Map<String, dynamic>.from(data as Map);
    return Session(
      token: map['token'] as String,
      user: AppUser.fromJson(Map<String, dynamic>.from(map['user'] as Map)),
    );
  }

  /// Checks the INTI roster and existing accounts, then creates a
  /// role = 'student' account with a bcrypt-hashed password.
  Future<AppUser> registerStudent({
    required String fullName,
    required String studentId,
    required String password,
    String? email,
  }) async {
    final params = <String, dynamic>{
      'p_full_name': fullName,
      'p_student_id': studentId,
      'p_password': password,
      if (email != null) 'p_email': email,
    };
    final data =
        await _call(() => _client.rpc('register_student', params: params));
    return AppUser.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Re-reads the logged-in user's profile from the database.
  /// Throws [AuthFailure.sessionExpired] if the token was revoked or expired.
  Future<AppUser> me(String token) async {
    final data =
        await _call(() => _client.rpc('me', params: {'p_token': token}));
    return AppUser.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Saves the nickname and, if [newPassword] is given, changes the password
  /// (the database checks [currentPassword] with bcrypt first).
  /// Returns the updated user. The official name is never changed.
  Future<AppUser> updateProfile({
    required String token,
    required String? displayName,
    String? currentPassword,
    String? newPassword,
  }) async {
    final data = await _call(() => _client.rpc('update_my_profile', params: {
          'p_token': token,
          'p_display_name': displayName ?? '',
          if (newPassword != null && newPassword.isNotEmpty) ...{
            'p_current_password': currentPassword ?? '',
            'p_new_password': newPassword,
          },
        }));
    return AppUser.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Revokes the token on the server. Errors are ignored: the local
  /// session is cleared either way.
  Future<void> logout(String token) async {
    try {
      await _client.rpc('logout', params: {'p_token': token});
    } catch (_) {}
  }

  Future<dynamic> _call(Future<dynamic> Function() request) async {
    try {
      return await request();
    } on PostgrestException catch (e) {
      throw AuthFailure(e.code ?? '', e.message);
    } catch (_) {
      throw const AuthFailure(
        AuthFailure.network,
        "Can't reach the server. Check your connection and try again.",
      );
    }
  }
}
