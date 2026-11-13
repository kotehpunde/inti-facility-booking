import 'package:flutter/material.dart';

import 'models/app_user.dart';
import 'screens/admin_dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'screens/student_dashboard_screen.dart';
import 'services/auth_service.dart';
import 'services/notification_service.dart';
import 'services/session_manager.dart';

/// Role-based routing (RBAC on the UI side).
/// The database still re-checks the role on every protected call.
Widget homeFor(AppUser user) {
  return user.role == UserRole.admin
      ? AdminDashboardScreen(user: user)
      : StudentDashboardScreen(user: user);
}

/// Opens the right dashboard and clears the back stack,
/// so the Back button cannot return to the login screen.
void goToDashboard(BuildContext context, AppUser user) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => homeFor(user)),
    (_) => false,
  );
}

void goToLogin(BuildContext context) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (_) => false,
  );
}

/// Signs the user out everywhere:
/// 1. clears the saved session on this phone,
/// 2. revokes the token in Supabase (rpc/logout),
/// 3. removes this phone's booking reminders,
/// 4. replaces the whole navigation stack with the Login screen.
/// [message] is shown on the Login screen, e.g. "Your session has expired".
Future<void> logOut(BuildContext context, {String? message}) async {
  // Grab these before any await so we don't use a stale BuildContext.
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);

  final token = await SessionManager.token();
  await SessionManager.clear(); // local first: never stay "logged in"
  if (token != null) AuthService().logout(token); // server revoke, no wait
  await NotificationService.cancelAll(); // next user shouldn't get these

  navigator.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (_) => false,
  );
  if (message != null) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}
