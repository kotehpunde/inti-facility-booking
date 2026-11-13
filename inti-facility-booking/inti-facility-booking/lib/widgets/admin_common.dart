import 'package:flutter/material.dart';

import '../navigation.dart';
import '../services/admin_service.dart';
import '../theme/app_theme.dart';

/// Shared building blocks for the admin screens.

/// White card: 16px corners, subtle border, slight elevation.
class AdminCard extends StatelessWidget {
  const AdminCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 1,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.fieldBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// AppBar used by every admin sub-screen: back arrow + bold title.
PreferredSizeWidget adminAppBar(BuildContext context, String title,
    {List<Widget>? actions}) {
  return AppBar(
    backgroundColor: AppColors.background,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    centerTitle: false,
    leading: IconButton(
      tooltip: 'Back',
      icon: const Icon(Icons.arrow_back_rounded, color: AppColors.textPrimary),
      onPressed: () => Navigator.pop(context),
    ),
    title: Text(
      title,
      style: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
    ),
    actions: actions,
  );
}

/// Small rounded label, e.g. a status or count badge.
class AdminBadge extends StatelessWidget {
  const AdminBadge({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    this.icon,
  });

  final String label;
  final Color background;
  final Color foreground;
  final IconData? icon;

  static const amberBg = Color(0xFFFEF3C7), amberFg = Color(0xFFB45309);
  static const greenBg = Color(0xFFDCFCE7), greenFg = Color(0xFF15803D);
  static const greyBg = Color(0xFFF1F5F9), greyFg = Color(0xFF64748B);
  static const redBg = Color(0xFFFEE2E2), redFg = Color(0xFFB91C1C);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// Centered icon + title + message (+ optional button) for empty/error states.
class AdminMessage extends StatelessWidget {
  const AdminMessage({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: AppColors.subtext),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.subtext, height: 1.4)),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(foregroundColor: AppColors.crimson),
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

void showAdminSnack(BuildContext context, String message, {bool success = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: success ? const Color(0xFF16A34A) : null,
      content: Text(message),
    ));
}

/// Session expired or not an admin → back to Login. Otherwise a snackbar.
/// Returns true if the user was sent to Login.
Future<bool> handleAdminFailure(BuildContext context, AdminFailure e) async {
  if (e.needsLogin) {
    await logOut(context,
        message: e.code == AdminFailure.forbidden
            ? 'This area is for administrators only.'
            : 'Your session has expired. Please log in again.');
    return true;
  }
  if (context.mounted) showAdminSnack(context, e.message);
  return false;
}
