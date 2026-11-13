import 'package:flutter/material.dart';

/// INTI brand colours.
class AppColors {
  AppColors._();

  static const crimson = Color(0xFFC41230); // INTI Crimson Red
  static const crimsonDark = Color(0xFF9E0E26);
  static const background = Color(0xFFF8FAFC); // off-white slate
  static const surface = Color(0xFFFFFFFF);
  static const textPrimary = Color(0xFF0F172A);
  static const textSecondary = Color(0xFF475569);
  static const subtext = Color(0xFF64748B); // slate grey for captions
  static const textHint = Color(0xFF94A3B8);
  static const fieldBorder = Color(0xFFCBD5E1);
  static const error = Color(0xFFDC2626);
}

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.crimson,
      primary: AppColors.crimson,
      onPrimary: Colors.white,
      error: AppColors.error,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: AppColors.crimson,
      ),
    );
  }

  static OutlineInputBorder _border(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color, width: width),
      );

  /// Outlined, white-filled text field style used on every form.
  /// [helperText] defaults to a blank line so there is always room
  /// under the field for a validation message (no layout jump).
  static InputDecoration field({
    required String label,
    required IconData icon,
    String? helperText,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      helperText: helperText ?? ' ',
      helperMaxLines: 2,
      errorMaxLines: 2,
      filled: true,
      fillColor: AppColors.surface,
      prefixIcon: Icon(icon, color: AppColors.textSecondary),
      suffixIcon: suffixIcon,
      labelStyle: const TextStyle(color: AppColors.textHint),
      helperStyle: const TextStyle(color: AppColors.textSecondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      border: _border(AppColors.fieldBorder, 1),
      enabledBorder: _border(AppColors.fieldBorder, 1),
      disabledBorder: _border(AppColors.fieldBorder, 1),
      focusedBorder: _border(AppColors.crimson, 2),
      errorBorder: _border(AppColors.error, 1),
      focusedErrorBorder: _border(AppColors.error, 2),
    );
  }
}
