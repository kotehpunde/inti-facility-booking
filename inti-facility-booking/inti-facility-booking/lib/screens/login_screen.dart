import 'package:flutter/material.dart';

import '../navigation.dart';
import '../services/auth_service.dart';
import '../services/session_manager.dart';
import '../theme/app_theme.dart';
import '../utils/validators.dart';
import '../widgets/auth_layout.dart';
import '../widgets/password_field.dart';
import '../widgets/primary_button.dart';
import 'forgot_password_sheet.dart';
import 'signup_screen.dart';

/// Unified login for students and admins.
/// The password is checked inside PostgreSQL (bcrypt), and the returned
/// role decides which dashboard opens.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocus = FocusNode();
  final _auth = AuthService();

  bool _loading = false;
  String? _idServerError;
  String? _passwordServerError;
  String? _formError;

  @override
  void dispose() {
    _idController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_loading) return;
    setState(() {
      _idServerError = null;
      _passwordServerError = null;
      _formError = null;
    });
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() => _loading = true);

    try {
      final session = await _auth.login(
        _idController.text.trim(),
        _passwordController.text,
      );
      await SessionManager.save(session);
      if (!mounted) return;
      goToDashboard(context, session.user);
    } on AuthFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        switch (e.code) {
          case AuthFailure.accountNotFound:
            _idServerError = 'Account does not exist.';
          case AuthFailure.wrongPassword:
            _passwordServerError = 'Incorrect password.';
            _passwordController.clear();
          case AuthFailure.loginInactive:
            _idServerError = 'This student record is no longer active.';
          case AuthFailure.accountSuspended:
            _formError = 'Account has been suspended by campus '
                'administration. Please visit the admin counter.';
            _passwordController.clear();
          default:
            _formError = e.message;
        }
      });
      _formKey.currentState!.validate(); // show the server error under the field
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _formError = 'Something went wrong. Please try again.';
      });
    }
  }

  /// Opens the reset-ticket sheet. If the password was changed, pre-fills
  /// the Student ID so the student can log in straight away.
  Future<void> _openForgotPassword() async {
    final typed = _idController.text.trim();
    final studentId = await showForgotPasswordSheet(
      context,
      initialStudentId:
          Validators.studentId(typed) == null ? typed.toUpperCase() : null,
    );
    if (studentId == null || !mounted) return;

    _idController.text = studentId;
    _passwordController.clear();
    setState(() {
      _idServerError = null;
      _passwordServerError = null;
      _formError = null;
    });
    _passwordFocus.requestFocus();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Password updated. Log in with your new password.'),
      ),
    );
  }

  Future<void> _openSignup() async {
    final email = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const SignupScreen()),
    );
    if (email == null || !mounted) return;

    // Back from a successful signup: pre-fill the email.
    _idController.text = email;
    _passwordController.clear();
    _passwordFocus.requestFocus();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Account created. Please log in.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AuthLayout(
      title: 'Welcome!',
      subtitle: 'Sign in to book campus facilities',
      children: [
        Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _idController,
                  enabled: !_loading,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.username],
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontSize: 16),
                  decoration: AppTheme.field(
                    label: 'Student ID or INTI email',
                    icon: Icons.person_outline,
                  ),
                  validator: (v) =>
                      _idServerError ?? Validators.loginIdentifier(v),
                  onChanged: (_) {
                    if (_idServerError != null) {
                      setState(() => _idServerError = null);
                    }
                  },
                  onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                ),
                const SizedBox(height: 4),
                PasswordField(
                  controller: _passwordController,
                  focusNode: _passwordFocus,
                  enabled: !_loading,
                  label: 'Password',
                  validator: (v) =>
                      _passwordServerError ?? Validators.notEmpty(v),
                  onChanged: (_) {
                    if (_passwordServerError != null) {
                      setState(() => _passwordServerError = null);
                    }
                  },
                  onFieldSubmitted: (_) => _login(),
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _loading ? null : _openForgotPassword,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.crimson,
              textStyle: const TextStyle(fontWeight: FontWeight.w600),
            ),
            child: const Text('Forgot Password?'),
          ),
        ),
        FormErrorText(_formError),
        PrimaryButton(label: 'Log In', loading: _loading, onPressed: _login),
        const SizedBox(height: 20),
        AuthSwitchLink(
          question: "Don't have an account?",
          action: 'Sign Up Now',
          onTap: _loading ? null : _openSignup,
        ),
      ],
    );
  }
}
