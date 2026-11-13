import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_user.dart';
import '../navigation.dart';
import '../services/auth_service.dart';
import '../services/session_manager.dart';
import '../theme/app_theme.dart';
import '../utils/validators.dart';
import '../widgets/auth_layout.dart';
import '../widgets/password_field.dart';
import '../widgets/primary_button.dart';

/// Opens the student's profile sheet (from the dashboard avatar).
///
/// - Official name, Student ID and email: shown, never editable.
/// - Nickname: optional; used in the dashboard greeting.
/// - Password: optional; needs the current password + new password twice.
///
/// [onUpdated] receives the saved user so the dashboard can refresh its
/// greeting straight away.
Future<void> showStudentProfileSheet(
  BuildContext context, {
  required AppUser user,
  required ValueChanged<AppUser> onUpdated,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _StudentProfileSheet(user: user, onUpdated: onUpdated),
  );
}

class _StudentProfileSheet extends StatefulWidget {
  const _StudentProfileSheet({required this.user, required this.onUpdated});

  final AppUser user;
  final ValueChanged<AppUser> onUpdated;

  @override
  State<_StudentProfileSheet> createState() => _StudentProfileSheetState();
}

class _StudentProfileSheetState extends State<_StudentProfileSheet> {
  static const _maxNicknameLength = 30;
  static const _successGreen = Color(0xFF16A34A);

  final _formKey = GlobalKey<FormState>();
  final _confirmFieldKey = GlobalKey<FormFieldState<String>>();
  final _auth = AuthService();

  late final _nicknameController =
      TextEditingController(text: widget.user.displayName ?? '');
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _saving = false;
  String? _nicknameServerError;
  String? _currentServerError;
  String? _newServerError;
  String? _formError;

  @override
  void initState() {
    super.initState();
    // Rebuild on typing so the avatar preview and "Save Changes" stay current.
    for (final c in _allControllers) {
      c.addListener(_onAnyChange);
    }
  }

  @override
  void dispose() {
    for (final c in _allControllers) {
      c.removeListener(_onAnyChange);
      c.dispose();
    }
    super.dispose();
  }

  List<TextEditingController> get _allControllers =>
      [_nicknameController, _currentController, _newController, _confirmController];

  void _onAnyChange() => setState(() {});

  // ===========================================================================
  // Form state
  // ===========================================================================

  String get _nickname => _nicknameController.text.trim().replaceAll(RegExp(r'\s+'), ' ');

  bool get _nicknameChanged => _nickname != (widget.user.displayName ?? '').trim();

  /// The student started filling in any password field.
  bool get _wantsPasswordChange =>
      _currentController.text.isNotEmpty ||
      _newController.text.isNotEmpty ||
      _confirmController.text.isNotEmpty;

  bool get _hasChanges => _nicknameChanged || _wantsPasswordChange;

  /// Live preview: avatar letter from the nickname being typed.
  String get _previewInitial {
    final name = _nickname.isNotEmpty ? _nickname : widget.user.firstName;
    return name.isEmpty ? '?' : name[0].toUpperCase();
  }

  // ---- Validators (password fields only apply once one is filled) ----

  String? _validateNickname(String? v) {
    if (_nicknameServerError != null) return _nicknameServerError;
    final value = (v ?? '').trim();
    if (value.length > _maxNicknameLength) {
      return 'Nickname must be $_maxNicknameLength characters or fewer.';
    }
    return null;
  }

  String? _validateCurrent(String? v) {
    if (_currentServerError != null) return _currentServerError;
    if (!_wantsPasswordChange) return null;
    return (v == null || v.isEmpty)
        ? 'Enter your current password to change it.'
        : null;
  }

  String? _validateNew(String? v) {
    if (_newServerError != null) return _newServerError;
    if (!_wantsPasswordChange) return null;
    return Validators.newPassword(v);
  }

  String? _validateConfirm(String? v) {
    if (!_wantsPasswordChange) return null;
    if (v == null || v.isEmpty) return 'Please confirm your new password.';
    return v == _newController.text ? null : 'New passwords do not match.';
  }

  // ===========================================================================
  // Save
  // ===========================================================================

  Future<void> _save() async {
    if (_saving || !_hasChanges) return;
    setState(() {
      _nicknameServerError = null;
      _currentServerError = null;
      _newServerError = null;
      _formError = null;
    });
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() => _saving = true);

    // Capture these before any await: the sheet closes on success.
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final changingPassword = _wantsPasswordChange;

    final token = await SessionManager.token();
    if (!mounted) return;
    if (token == null) {
      await logOut(context);
      return;
    }

    try {
      final updated = await _auth.updateProfile(
        token: token,
        displayName: _nickname,
        currentPassword: changingPassword ? _currentController.text : null,
        newPassword: changingPassword ? _newController.text : null,
      );
      await SessionManager.save(Session(token: token, user: updated));
      widget.onUpdated(updated); // dashboard greeting updates now

      if (mounted) navigator.pop(); // close the sheet (if still open)
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          backgroundColor: _successGreen,
          behavior: SnackBarBehavior.floating,
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Colors.white),
              const SizedBox(width: 10),
              Expanded(
                child: Text(changingPassword
                    ? 'Profile updated successfully! Other devices were signed out.'
                    : 'Profile updated successfully!'),
              ),
            ],
          ),
        ));
    } on AuthFailure catch (e) {
      if (!mounted) return;
      if (e.code == AuthFailure.sessionExpired) {
        await logOut(context,
            message: 'Your session has expired. Please log in again.');
        return;
      }
      setState(() {
        _saving = false;
        switch (e.code) {
          case AuthFailure.currentPasswordWrong:
            _currentServerError = e.message; // "Current password is incorrect."
            _currentController.clear();
          case AuthFailure.passwordInvalid:
          case AuthFailure.samePassword:
            _newServerError = e.message;
          case AuthFailure.nicknameInvalid:
            _nicknameServerError = e.message;
          default:
            _formError = e.message;
        }
      });
      _formKey.currentState!.validate();
    }
  }

  // ===========================================================================
  // UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final user = widget.user;
    final keyboard = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ---- Header ----
                Center(
                  child: CircleAvatar(
                    radius: 38,
                    backgroundColor: AppColors.crimson,
                    child: Text(
                      _previewInitial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  user.name,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Official name · can only be changed by INTI',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: AppColors.subtext),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _InfoChip(
                      icon: Icons.badge_outlined,
                      label: 'ID: ${user.studentId ?? '-'}',
                    ),
                    _InfoChip(icon: Icons.mail_outline_rounded, label: user.email),
                  ],
                ),
                const SizedBox(height: 24),

                // ---- Nickname ----
                const _SectionTitle('Preferred name'),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _nicknameController,
                  enabled: !_saving,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(_maxNicknameLength),
                  ],
                  style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
                  decoration: AppTheme.field(
                    label: 'Preferred Name / Nickname',
                    icon: Icons.face_outlined,
                    helperText: _nickname.isEmpty
                        ? 'Empty = greet me as "${user.firstName}"'
                        : 'Dashboard will say "Welcome back, $_nickname"',
                  ),
                  validator: _validateNickname,
                  onChanged: (_) {
                    if (_nicknameServerError != null) {
                      setState(() => _nicknameServerError = null);
                    }
                  },
                ),
                const SizedBox(height: 16),

                // ---- Password (optional) ----
                const _SectionTitle('Change password'),
                const SizedBox(height: 4),
                const Text(
                  'Optional. Leave these empty to keep your current password.',
                  style: TextStyle(fontSize: 12.5, color: AppColors.subtext),
                ),
                const SizedBox(height: 10),
                PasswordField(
                  controller: _currentController,
                  enabled: !_saving,
                  label: 'Current Password',
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.password],
                  validator: _validateCurrent,
                  onChanged: (_) {
                    if (_currentServerError != null) {
                      setState(() => _currentServerError = null);
                    }
                  },
                ),
                const SizedBox(height: 4),
                PasswordField(
                  controller: _newController,
                  enabled: !_saving,
                  label: 'New Password',
                  helperText: 'At least 8 characters',
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: _validateNew,
                  onChanged: (_) {
                    if (_newServerError != null) {
                      setState(() => _newServerError = null);
                    }
                    if (_confirmController.text.isNotEmpty) {
                      _confirmFieldKey.currentState?.validate();
                    }
                  },
                ),
                const SizedBox(height: 4),
                PasswordField(
                  fieldKey: _confirmFieldKey,
                  controller: _confirmController,
                  enabled: !_saving,
                  label: 'Confirm New Password',
                  autofillHints: const [AutofillHints.newPassword],
                  validator: _validateConfirm,
                  onFieldSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 8),
                FormErrorText(_formError),
                PrimaryButton(
                  label: 'Save Changes',
                  loading: _saving,
                  onPressed: _hasChanges ? _save : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
    );
  }
}

/// Read-only chip, e.g. "ID: P22014366".
class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.fieldBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppColors.subtext),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
