import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/password_reset_service.dart';
import '../theme/app_theme.dart';
import '../utils/validators.dart';
import '../widgets/auth_layout.dart';
import '../widgets/password_field.dart';
import '../widgets/primary_button.dart';

/// Opens the "Forgot Password?" sheet from the Login screen.
///
/// Step 1 (request): Student ID + INTI email → reset ticket, e.g. R-1234.
/// Step 2 (complete): ticket + Student ID + temporary passcode from the
///                    admin + new password.
///
/// Returns the Student ID when the password was changed, so the Login
/// screen can pre-fill it; returns null if the sheet was just closed.
Future<String?> showForgotPasswordSheet(
  BuildContext context, {
  String? initialStudentId,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true, // lets the sheet grow above the keyboard
    showDragHandle: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ForgotPasswordSheet(initialStudentId: initialStudentId),
  );
}

enum _Step { request, complete }

class _ForgotPasswordSheet extends StatefulWidget {
  const _ForgotPasswordSheet({this.initialStudentId});

  final String? initialStudentId;

  @override
  State<_ForgotPasswordSheet> createState() => _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends State<_ForgotPasswordSheet> {
  final _service = PasswordResetService();

  _Step _step = _Step.request;
  bool _loading = false;
  String? _formError;

  // ---- Step 1: request ----
  final _requestFormKey = GlobalKey<FormState>();
  late final _studentIdController =
      TextEditingController(text: widget.initialStudentId);
  final _emailController = TextEditingController();
  String? _studentIdServerError;
  String? _emailServerError;

  // ---- Step 2: complete ----
  final _completeFormKey = GlobalKey<FormState>();
  final _confirmFieldKey = GlobalKey<FormFieldState<String>>();
  final _ticketController = TextEditingController();
  final _completeIdController = TextEditingController();
  final _passcodeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _ticketServerError;
  String? _passcodeServerError;
  String? _newPasswordServerError;

  @override
  void dispose() {
    for (final c in [
      _studentIdController,
      _emailController,
      _ticketController,
      _completeIdController,
      _passcodeController,
      _newPasswordController,
      _confirmController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ===========================================================================
  // Step 1: request a ticket
  // ===========================================================================

  Future<void> _requestTicket() async {
    if (_loading) return;
    setState(() {
      _studentIdServerError = null;
      _emailServerError = null;
      _formError = null;
    });
    if (!_requestFormKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    final studentId = _studentIdController.text.trim().toUpperCase();

    try {
      final ticket = await _service.requestReset(
        studentId: studentId,
        email: _emailController.text.trim().toLowerCase(),
      );
      if (!mounted) return;
      setState(() => _loading = false);
      await _showTicketDialog(ticket, studentId);
    } on ResetFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        switch (e.code) {
          case ResetFailure.noAccount:
          case ResetFailure.inactive:
            _studentIdServerError = e.message;
          case ResetFailure.emailMismatch:
            _emailServerError = e.message;
          default:
            _formError = e.message;
        }
      });
      _requestFormKey.currentState!.validate();
    }
  }

  Future<void> _showTicketDialog(ResetTicket ticket, String studentId) async {
    final goToComplete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.confirmation_number_outlined,
            color: AppColors.crimson, size: 44),
        title: Text(ticket.alreadyOpen
            ? 'You already have ticket #${ticket.ticketNo}'
            : 'Reset Ticket #${ticket.ticketNo} Created!'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _TicketNumber(ticket.ticketNo),
            const SizedBox(height: 14),
            Text(
              ticket.status == 'approved'
                  ? 'This ticket is already approved. Use the temporary '
                      'passcode the admin gave you.'
                  : 'Please visit the campus administration counter or '
                      'contact the admin to approve your request. Bring '
                      'your student ID card.',
              textAlign: TextAlign.center,
              style: const TextStyle(height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Close'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.crimson),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('I Have My Temp Passcode'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (goToComplete == true) {
      _goToComplete(ticketNo: ticket.ticketNo, studentId: studentId);
    } else {
      Navigator.of(context).pop(); // close the sheet
    }
  }

  void _goToComplete({String? ticketNo, String? studentId}) {
    setState(() {
      _step = _Step.complete;
      _formError = null;
      if (ticketNo != null) _ticketController.text = ticketNo;
      final id = studentId ??
          (Validators.studentId(_studentIdController.text) == null
              ? _studentIdController.text.trim().toUpperCase()
              : null);
      if (id != null) _completeIdController.text = id;
    });
  }

  // ===========================================================================
  // Step 2: set the new password
  // ===========================================================================

  Future<void> _completeReset() async {
    if (_loading) return;
    setState(() {
      _ticketServerError = null;
      _passcodeServerError = null;
      _newPasswordServerError = null;
      _formError = null;
    });
    if (!_completeFormKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() => _loading = true);
    final studentId = _completeIdController.text.trim().toUpperCase();

    try {
      await _service.completeReset(
        ticketNo: _normalisedTicket(_ticketController.text),
        studentId: studentId,
        passcode: _passcodeController.text.trim().toUpperCase(),
        newPassword: _newPasswordController.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(studentId); // Login shows the success message
    } on ResetFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        switch (e.code) {
          case ResetFailure.wrongPasscode:
            final left = e.attemptsLeft;
            _passcodeServerError = left == null
                ? e.message
                : '${e.message} $left ${left == 1 ? 'try' : 'tries'} left.';
            _passcodeController.clear();
          case ResetFailure.ticketNotFound:
          case ResetFailure.notApproved:
          case ResetFailure.ticketInvalid:
          case ResetFailure.ticketLocked:
            _ticketServerError = e.message;
          case ResetFailure.passwordInvalid:
            _newPasswordServerError = e.message;
          default:
            _formError = e.message;
        }
      });
      _completeFormKey.currentState!.validate();
    }
  }

  /// "r1234", "R 1234", "1234" → "R-1234"
  static String _normalisedTicket(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    return 'R-$digits';
  }

  static String? _validateTicket(String? v) {
    if (v == null || v.trim().isEmpty) return 'This field is required.';
    final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length == 4 ? null : 'Ticket numbers look like R-1234.';
  }

  static String? _validatePasscode(String? v) {
    if (v == null || v.trim().isEmpty) return 'This field is required.';
    return v.trim().length == 6 ? null : 'The passcode has 6 characters.';
  }

  // ===========================================================================
  // UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    // Keep the sheet above the on-screen keyboard.
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _step == _Step.request
                ? _buildRequest()
                : _buildComplete(),
          ),
        ),
      ),
    );
  }

  Widget _buildRequest() {
    return Form(
      key: _requestFormKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        key: const ValueKey('request'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SheetTitle(
            title: 'Forgot your password?',
            subtitle: 'Request a reset ticket. An admin will approve it '
                'and give you a temporary passcode.',
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _studentIdController,
            enabled: !_loading,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            style: _fieldText,
            decoration: AppTheme.field(
              label: 'Student ID',
              icon: Icons.badge_outlined,
              helperText: 'e.g. P22014366',
            ),
            validator: (v) => _studentIdServerError ?? Validators.studentId(v),
            onChanged: (_) {
              if (_studentIdServerError != null) {
                setState(() => _studentIdServerError = null);
              }
            },
          ),
          const SizedBox(height: 4),
          TextFormField(
            controller: _emailController,
            enabled: !_loading,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            style: _fieldText,
            decoration: AppTheme.field(
              label: 'INTI email',
              icon: Icons.mail_outline_rounded,
              helperText: 'p22014366@student.newinti.edu.my',
            ),
            validator: (v) => _emailServerError ?? Validators.intiEmail(v),
            onChanged: (_) {
              if (_emailServerError != null) {
                setState(() => _emailServerError = null);
              }
            },
            onFieldSubmitted: (_) => _requestTicket(),
          ),
          const SizedBox(height: 8),
          FormErrorText(_formError),
          PrimaryButton(
            label: 'Request Reset Ticket',
            loading: _loading,
            onPressed: _requestTicket,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loading ? null : () => _goToComplete(),
            style: TextButton.styleFrom(foregroundColor: AppColors.crimson),
            child: const Text('Already have a ticket and passcode?'),
          ),
        ],
      ),
    );
  }

  Widget _buildComplete() {
    return Form(
      key: _completeFormKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        key: const ValueKey('complete'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SheetTitle(
            title: 'Set a new password',
            subtitle: 'Enter your ticket and the temporary passcode from the '
                'admin. The passcode works for 60 minutes after approval.',
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextFormField(
                  controller: _ticketController,
                  enabled: !_loading,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                  style: _fieldText,
                  decoration: AppTheme.field(
                    label: 'Ticket',
                    icon: Icons.confirmation_number_outlined,
                    helperText: 'R-1234',
                  ),
                  validator: (v) => _ticketServerError ?? _validateTicket(v),
                  onChanged: (_) {
                    if (_ticketServerError != null) {
                      setState(() => _ticketServerError = null);
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: _completeIdController,
                  enabled: !_loading,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  style: _fieldText,
                  decoration: AppTheme.field(
                    label: 'Student ID',
                    icon: Icons.badge_outlined,
                  ),
                  validator: Validators.studentId,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextFormField(
            controller: _passcodeController,
            enabled: !_loading,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [
              LengthLimitingTextInputFormatter(6),
              FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
            ],
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
            ),
            decoration: AppTheme.field(
              label: 'Temporary passcode',
              icon: Icons.key_rounded,
              helperText: '6 characters from the admin, e.g. K7P3QX',
            ),
            validator: (v) => _passcodeServerError ?? _validatePasscode(v),
            onChanged: (_) {
              if (_passcodeServerError != null) {
                setState(() => _passcodeServerError = null);
              }
            },
          ),
          const SizedBox(height: 4),
          PasswordField(
            controller: _newPasswordController,
            enabled: !_loading,
            label: 'New password',
            helperText: 'At least 8 characters',
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.newPassword],
            validator: (v) =>
                _newPasswordServerError ?? Validators.newPassword(v),
            onChanged: (_) {
              if (_newPasswordServerError != null) {
                setState(() => _newPasswordServerError = null);
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
            enabled: !_loading,
            label: 'Confirm new password',
            autofillHints: const [AutofillHints.newPassword],
            validator: (v) =>
                Validators.confirmPassword(v, _newPasswordController.text),
            onFieldSubmitted: (_) => _completeReset(),
          ),
          const SizedBox(height: 8),
          FormErrorText(_formError),
          PrimaryButton(
            label: 'Reset Password',
            loading: _loading,
            onPressed: _completeReset,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loading
                ? null
                : () => setState(() {
                      _step = _Step.request;
                      _formError = null;
                    }),
            style: TextButton.styleFrom(foregroundColor: AppColors.crimson),
            child: const Text("Don't have a ticket yet? Request one"),
          ),
        ],
      ),
    );
  }

  static const _fieldText = TextStyle(color: AppColors.textPrimary, fontSize: 16);
}

class _SheetTitle extends StatelessWidget {
  const _SheetTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: const TextStyle(color: AppColors.subtext, height: 1.4),
        ),
      ],
    );
  }
}

/// Big, easy-to-read ticket number with a copy button.
class _TicketNumber extends StatelessWidget {
  const _TicketNumber(this.ticketNo);

  final String ticketNo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.crimson.withAlpha(16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.crimson.withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            ticketNo,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: AppColors.crimson,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            tooltip: 'Copy ticket number',
            icon: const Icon(Icons.copy_rounded,
                size: 18, color: AppColors.crimson),
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: ticketNo)),
          ),
        ],
      ),
    );
  }
}
