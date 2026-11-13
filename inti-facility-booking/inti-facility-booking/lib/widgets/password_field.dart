import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Password input with a built-in eye icon to show/hide the text.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    this.fieldKey,
    required this.controller,
    required this.label,
    this.validator,
    this.onChanged,
    this.onFieldSubmitted,
    this.focusNode,
    this.helperText,
    this.textInputAction = TextInputAction.done,
    this.autofillHints = const [AutofillHints.password],
    this.enabled = true,
  });

  /// Optional key for the inner field, so other code can call validate() on it.
  final GlobalKey<FormFieldState<String>>? fieldKey;
  final TextEditingController controller;
  final String label;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onFieldSubmitted;
  final FocusNode? focusNode;
  final String? helperText;
  final TextInputAction textInputAction;
  final Iterable<String> autofillHints;
  final bool enabled;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      key: widget.fieldKey,
      controller: widget.controller,
      focusNode: widget.focusNode,
      enabled: widget.enabled,
      obscureText: _obscured,
      enableSuggestions: false,
      autocorrect: false,
      textInputAction: widget.textInputAction,
      autofillHints: widget.autofillHints,
      validator: widget.validator,
      onChanged: widget.onChanged,
      onFieldSubmitted: widget.onFieldSubmitted,
      style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
      decoration: AppTheme.field(
        label: widget.label,
        icon: Icons.lock_outline,
        helperText: widget.helperText,
        suffixIcon: IconButton(
          tooltip: _obscured ? 'Show password' : 'Hide password',
          icon: Icon(
            _obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            color: AppColors.textSecondary,
          ),
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
    );
  }
}
