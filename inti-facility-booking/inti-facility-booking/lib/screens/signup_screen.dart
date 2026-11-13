import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../utils/validators.dart';
import '../widgets/auth_layout.dart';
import '../widgets/password_field.dart';
import '../widgets/primary_button.dart';

/// Student self-registration.
///
/// The app checks formats (Student ID / INTI email, password rules).
/// The database function register_student then, in one step:
/// roster lookup → active check → duplicate check → bcrypt → insert as 'student'.
class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _confirmFieldKey = GlobalKey<FormFieldState<String>>();

  final _nameController = TextEditingController();
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  final _idFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();

  final _auth = AuthService();

  bool _loading = false;
  String? _nameServerError;
  String? _idServerError;
  String? _passwordServerError;
  String? _formError;

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _idFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _signup() async {
    if (_loading) return;
    setState(() {
      _nameServerError = null;
      _idServerError = null;
      _passwordServerError = null;
      _formError = null;
    });
    if (!_formKey.currentState!.validate()) return;

    final identity = Validators.parseStudentIdentity(_idController.text);
    if (identity == null) return; // already reported by the validator

    FocusScope.of(context).unfocus();
    setState(() => _loading = true);

    try {
      final user = await _auth.registerStudent(
        fullName: _nameController.text.trim().replaceAll(RegExp(r'\s+'), ' '),
        studentId: identity.studentId,
        password: _passwordController.text,
        email: identity.email,
      );
      if (!mounted) return;
      // Back to Login; it shows the success message and pre-fills the email.
      Navigator.of(context).pop(user.email);
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        switch (e.code) {
          case AuthFailure.notInRoster:
            _idServerError = 'Student ID not found in INTI eligibility roster.';
          case AuthFailure.rosterInactive:
            _idServerError = 'This student record is no longer active.';
          case AuthFailure.emailMismatch:
            _idServerError =
                'Email does not match the INTI record for this Student ID.';
          case AuthFailure.alreadyRegistered:
            _idServerError = 'Account already registered. Please log in.';
          case AuthFailure.passwordInvalid:
            _passwordServerError = e.message;
          case AuthFailure.nameInvalid:
            _nameServerError = 'Please enter your full name.';
          default:
            _formError = e.message;
        }
      });
      _formKey.currentState!.validate();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _formError = 'Something went wrong. Please try again.';
      });
    }
  }

  void _clearOnEdit(String? serverError, VoidCallback clear) {
    if (serverError != null) setState(clear);
  }

  @override
  Widget build(BuildContext context) {
    const fieldText = TextStyle(color: AppColors.textPrimary, fontSize: 16);

    return AuthLayout(
      title: 'Create Account',
      subtitle: 'Only students on the INTI roster can register',
      titleSize: 32,
      children: [
        Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Full Name
                TextFormField(
                  controller: _nameController,
                  enabled: !_loading,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.name],
                  inputFormatters: [LengthLimitingTextInputFormatter(100)],
                  style: fieldText,
                  decoration: AppTheme.field(
                    label: 'Full Name',
                    icon: Icons.person_outline,
                  ),
                  validator: (v) => _nameServerError ?? Validators.fullName(v),
                  onChanged: (_) => _clearOnEdit(
                      _nameServerError, () => _nameServerError = null),
                  onFieldSubmitted: (_) => _idFocus.requestFocus(),
                ),
                const SizedBox(height: 4),

                // Student ID or INTI email
                TextFormField(
                  controller: _idController,
                  focusNode: _idFocus,
                  enabled: !_loading,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  enableSuggestions: false,
                  autofillHints: const [AutofillHints.username],
                  style: fieldText,
                  decoration: AppTheme.field(
                    label: 'Student ID or INTI email',
                    icon: Icons.badge_outlined,
                    helperText:
                        'e.g. P22014366 or p22014366@student.newinti.edu.my',
                  ),
                  validator: (v) =>
                      _idServerError ?? Validators.studentIdentity(v),
                  onChanged: (_) =>
                      _clearOnEdit(_idServerError, () => _idServerError = null),
                  onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                ),
                const SizedBox(height: 4),

                // Password
                PasswordField(
                  controller: _passwordController,
                  focusNode: _passwordFocus,
                  enabled: !_loading,
                  label: 'Password',
                  helperText: 'At least 8 characters',
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: (v) =>
                      _passwordServerError ?? Validators.newPassword(v),
                  onChanged: (_) {
                    _clearOnEdit(
                        _passwordServerError, () => _passwordServerError = null);
                    // Re-check Confirm Password live once it has text.
                    if (_confirmController.text.isNotEmpty) {
                      _confirmFieldKey.currentState?.validate();
                    }
                  },
                  onFieldSubmitted: (_) => _confirmFocus.requestFocus(),
                ),
                const SizedBox(height: 4),

                // Confirm Password
                PasswordField(
                  fieldKey: _confirmFieldKey,
                  controller: _confirmController,
                  focusNode: _confirmFocus,
                  enabled: !_loading,
                  label: 'Confirm Password',
                  autofillHints: const [AutofillHints.newPassword],
                  validator: (v) => Validators.confirmPassword(
                      v, _passwordController.text),
                  onFieldSubmitted: (_) => _signup(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        FormErrorText(_formError),
        PrimaryButton(label: 'Sign Up', loading: _loading, onPressed: _signup),
        const SizedBox(height: 20),
        AuthSwitchLink(
          question: 'Already have an account?',
          action: 'Log In',
          onTap: _loading ? null : () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
