import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_user.dart';

export '../models/app_user.dart' show Session;

/// Saves the login session on the device (token, role, student ID, name).
///
/// The token is revocable on the server (only its SHA-256 is stored in
/// Supabase). The cached role is only used to pick which screen to show.
class SessionManager {
  SessionManager._();

  static const _kToken = 'session_token';
  static const _kUser = 'session_user';

  static Future<void> save(Session session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kToken, session.token);
    await prefs.setString(_kUser, jsonEncode(session.user.toJson()));
  }

  static Future<Session?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_kToken);
    final userJson = prefs.getString(_kUser);
    if (token == null || userJson == null) return null;
    try {
      final user = AppUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
      return Session(token: token, user: user);
    } catch (_) {
      await clear(); // corrupted data: force a fresh login
      return null;
    }
  }

  static Future<String?> token() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kToken);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kUser);
  }
}
