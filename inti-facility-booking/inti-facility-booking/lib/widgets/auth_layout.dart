import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Centred, scrollable column used by the Login and Signup screens.
/// Width is capped so the form looks right on tablets too.
class AuthLayout extends StatelessWidget {
  const AuthLayout({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    this.titleSize = 40,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final double titleSize;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: titleSize,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 32),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Red message for errors that don't belong to one field (e.g. no internet).
class FormErrorText extends StatelessWidget {
  const FormErrorText(this.message, {super.key});

  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        message!,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.error, fontSize: 14),
      ),
    );
  }
}

/// "Don't have an account? Sign Up Now" style link row.
class AuthSwitchLink extends StatelessWidget {
  const AuthSwitchLink({
    super.key,
    required this.question,
    required this.action,
    required this.onTap,
  });

  final String question;
  final String action;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          question,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 15),
        ),
        TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.crimson,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          child: Text(action),
        ),
      ],
    );
  }
}
