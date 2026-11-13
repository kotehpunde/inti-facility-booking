import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Temporary page used by screens that are built in later tasks.
class ComingSoonView extends StatelessWidget {
  const ComingSoonView({
    super.key,
    required this.title,
    required this.icon,
    required this.message,
  });

  final String title;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: AppColors.crimson.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 40, color: AppColors.crimson),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.subtext, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
