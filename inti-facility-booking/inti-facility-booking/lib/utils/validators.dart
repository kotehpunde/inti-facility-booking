import 'dart:convert';

/// Client-side checks for instant feedback.
/// The database re-checks everything, so these are not the security layer.
class Validators {
  Validators._();

  static const intiStudentDomain = '@student.newinti.edu.my';
  static const passwordMin = 8;
  static const passwordMax = 72; // bcrypt only uses the first 72 bytes

  static final _studentId = RegExp(r'^P\d{8}$');
  static final _intiEmail = RegExp(r'^p\d{8}@student\.newinti\.edu\.my$');
  static final _anyEmail = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
  static final _name = RegExp(r"^\p{L}[\p{L} .'\-/@]*$", unicode: true);

  /// Turns "P22014366", "p22014366" or "p22014366@student.newinti.edu.my"
  /// into a normalised Student ID (+ the email if one was typed).
  static StudentIdentity? parseStudentIdentity(String? raw) {
    final value = (raw ?? '').trim();
    if (value.contains('@')) {
      final email = value.toLowerCase();
      if (!_intiEmail.hasMatch(email)) return null;
      final id = email.substring(0, email.indexOf('@')).toUpperCase();
      return StudentIdentity(studentId: id, email: email);
    }
    final id = value.toUpperCase();
    return _studentId.hasMatch(id) ? StudentIdentity(studentId: id) : null;
  }

  // ---- Field validators: return an error message, or null if valid ----

  static String? notEmpty(String? v) =>
      (v == null || v.trim().isEmpty) ? 'This field is required.' : null;

  static String? fullName(String? v) {
    if (v == null || v.trim().isEmpty) return 'This field is required.';
    final name = v.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.length < 2 || name.length > 100 || !_name.hasMatch(name)) {
      return 'Please enter your full name.';
    }
    return null;
  }

  /// Signup: must be an INTI Student ID or INTI student email.
  static String? studentIdentity(String? v) {
    if (v == null || v.trim().isEmpty) return 'This field is required.';
    final value = v.trim().toLowerCase();
    if (value.contains('@') && !value.endsWith(intiStudentDomain)) {
      return 'Email must end with $intiStudentDomain.';
    }
    return parseStudentIdentity(v) == null
        ? 'Enter a Student ID (e.g. P22014366) or an $intiStudentDomain email.'
        : null;
  }

  /// Login: any email (admins use staff emails) or a Student ID.
  static String? loginIdentifier(String? v) {
    if (v == null || v.trim().isEmpty) return 'This field is required.';
    final value = v.trim();
    final ok = value.contains('@')
        ? _anyEmail.hasMatch(value)
        : _studentId.hasMatch(value.toUpperCase());
    return ok ? null : 'Enter your Student ID or email.';
  }

  /// Student ID only, e.g. P22014366.
  static String? studentId(String? v) {
    if (v == null || v.trim().isEmpty) return 'This field is required.';
    return _studentId.hasMatch(v.trim().toUpperCase())
        ? null
        : 'Enter your Student ID, e.g. P22014366.';
  }

  /// Official INTI student email, e.g. p22014366@student.newinti.edu.my.
  static String? intiEmail(String? v) {
    if (v == null || v.trim().isEmpty) return 'This field is required.';
    final value = v.trim().toLowerCase();
    if (!value.endsWith(intiStudentDomain)) {
      return 'Email must end with $intiStudentDomain.';
    }
    return _intiEmail.hasMatch(value) ? null : 'Enter your INTI student email.';
  }

  static String? newPassword(String? v) {
    if (v == null || v.isEmpty) return 'This field is required.';
    if (v.length < passwordMin) return 'Password must be at least 8 characters.';
    if (utf8.encode(v).length > passwordMax) {
      return 'Password must be 72 characters or fewer.';
    }
    return null;
  }

  static String? confirmPassword(String? v, String password) {
    if (v == null || v.isEmpty) return 'This field is required.';
    return v == password ? null : 'Passwords do not match.';
  }
}

class StudentIdentity {
  const StudentIdentity({required this.studentId, this.email});

  final String studentId; // always like P22014366
  final String? email; // only when the user typed an email
}
