import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../navigation.dart';
import '../services/auth_service.dart';
import '../services/session_manager.dart';
import '../theme/app_theme.dart';
import 'primary_button.dart';

/// Shared layout for both dashboards: greeting, role badge and Log Out.
/// Booking features are added to each dashboard in later tasks.
class DashboardShell extends StatefulWidget {
  const DashboardShell({
    super.key,
    required this.title,
    required this.user,
    this.children = const [],
  });

  final String title;
  final AppUser user;
  final List<Widget> children;

  @override
  State<DashboardShell> createState() => _DashboardShellState();
}

class _DashboardShellState extends State<DashboardShell> {
  bool _loggingOut = false;

  Future<void> _logout() async {
    setState(() => _loggingOut = true);
    final token = await SessionManager.token();
    // Clear locally first so the app never stays "logged in" on a network error.
    await SessionManager.clear();
    if (token != null) AuthService().logout(token); // revoke on server, no wait
    if (!mounted) return;
    goToLogin(context);
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final isAdmin = user.role == UserRole.admin;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        title: Text(
          widget.title,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Welcome, ${user.name}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Chip(
                      label: Text(isAdmin ? 'Administrator' : 'Student'),
                      labelStyle: const TextStyle(
                        color: AppColors.crimson,
                        fontWeight: FontWeight.w600,
                      ),
                      backgroundColor: AppColors.surface,
                      side: const BorderSide(color: AppColors.fieldBorder),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    user.studentId != null
                        ? '${user.studentId} · ${user.email}'
                        : user.email,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 32),
                  ...widget.children,
                  PrimaryButton(
                    label: 'Log Out',
                    loading: _loggingOut,
                    onPressed: _logout,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
