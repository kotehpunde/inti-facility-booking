enum UserRole {
  student,
  admin;

  static UserRole fromString(String? value) =>
      value == 'admin' ? UserRole.admin : UserRole.student;
}

/// A row from the `users` table (never includes password_hash).
class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.studentId,
    this.displayName,
  });

  final String id;
  final String? studentId; // null for admins
  final String name;
  final String email;
  final UserRole role;

  /// Optional nickname chosen by the student, e.g. "Joshie".
  /// The official [name] never changes when this does.
  final String? displayName;

  /// First word of the official name: "Tan Wei Ming" → "Tan".
  String get firstName {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.isEmpty || parts.first.isEmpty ? 'there' : parts.first;
  }

  /// Name for greetings: the nickname if set, otherwise the first name.
  String get greetingName {
    final nick = displayName?.trim();
    return nick == null || nick.isEmpty ? firstName : nick;
  }

  /// Avatar letter.
  String get initial => greetingName.isEmpty ? '?' : greetingName[0].toUpperCase();

  AppUser copyWith({String? displayName, bool clearDisplayName = false}) =>
      AppUser(
        id: id,
        studentId: studentId,
        name: name,
        email: email,
        role: role,
        displayName: clearDisplayName ? null : (displayName ?? this.displayName),
      );

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      studentId: json['student_id'] as String?,
      name: json['name'] as String,
      email: json['email'] as String,
      role: UserRole.fromString(json['role'] as String?),
      displayName: json['display_name'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'student_id': studentId,
        'name': name,
        'email': email,
        'role': role.name,
        'display_name': displayName,
      };
}

/// What rpc/login returns: an opaque session token plus the user.
class Session {
  const Session({required this.token, required this.user});

  final String token;
  final AppUser user;
}
