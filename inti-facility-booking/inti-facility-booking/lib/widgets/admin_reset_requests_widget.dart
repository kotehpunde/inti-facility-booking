import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../navigation.dart';
import '../services/password_reset_service.dart';
import '../services/session_manager.dart';
import '../theme/app_theme.dart';
import '../utils/campus_time.dart';

/// Admin Dashboard card: "Password Reset Requests".
///
/// - Pending tickets (with a counter badge): Approve or Reject.
/// - Approving shows a one-time passcode to give the student. Only its
///   hash is stored, so it can't be shown again; use "New code" instead.
/// - Approved tickets stay listed under "Waiting for student" until the
///   student uses the code or it expires (60 minutes).
class AdminResetRequestsPanel extends StatefulWidget {
  const AdminResetRequestsPanel({super.key});

  @override
  State<AdminResetRequestsPanel> createState() =>
      _AdminResetRequestsPanelState();
}

class _AdminResetRequestsPanelState extends State<AdminResetRequestsPanel> {
  final _service = PasswordResetService();

  List<AdminResetTicket> _tickets = const [];
  bool _loading = true;
  String? _error;

  /// Ticket being approved/rejected (disables its buttons).
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<AdminResetTicket> get _pending =>
      _tickets.where((t) => t.isPending).toList();
  List<AdminResetTicket> get _approved =>
      _tickets.where((t) => !t.isPending).toList();

  // ===========================================================================
  // Data
  // ===========================================================================

  Future<String?> _tokenOrLogout() async {
    final token = await SessionManager.token();
    if (token == null && mounted) await logOut(context);
    return token;
  }

  Future<void> _load() async {
    final token = await _tokenOrLogout();
    if (token == null || !mounted) return;
    try {
      final tickets = await _service.listOpenTickets(token);
      if (!mounted) return;
      setState(() {
        _tickets = tickets;
        _loading = false;
        _error = null;
      });
    } on ResetFailure catch (e) {
      await _handleFailure(e, showInline: true);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _load();
  }

  Future<void> _handleFailure(ResetFailure e, {bool showInline = false}) async {
    if (!mounted) return;
    if (e.code == ResetFailure.sessionExpired) {
      await logOut(context,
          message: 'Your session has expired. Please log in again.');
      return;
    }
    setState(() {
      _loading = false;
      _busyId = null;
      if (showInline) _error = e.message;
    });
    if (!showInline) _showSnack(e.message);
  }

  // ===========================================================================
  // Actions
  // ===========================================================================

  Future<void> _approve(AdminResetTicket ticket) async {
    setState(() => _busyId = ticket.id);
    final token = await _tokenOrLogout();
    if (token == null || !mounted) return;
    try {
      final code = await _service.approve(token: token, ticketId: ticket.id);
      if (!mounted) return;
      setState(() => _busyId = null);
      await _showPasscode(ticket, code);
      await _load();
    } on ResetFailure catch (e) {
      await _handleFailure(e);
      await _load();
    }
  }

  Future<void> _reject(AdminResetTicket ticket) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Reject ticket #${ticket.ticketNo}?'),
        content: Text(
          '${ticket.name} (${ticket.studentId}) will need to request a new '
          'ticket to reset their password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.crimson),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyId = ticket.id);
    final token = await _tokenOrLogout();
    if (token == null || !mounted) return;
    try {
      await _service.reject(token: token, ticketId: ticket.id);
      if (!mounted) return;
      setState(() => _busyId = null);
      _showSnack('Ticket #${ticket.ticketNo} rejected.');
      await _load();
    } on ResetFailure catch (e) {
      await _handleFailure(e);
      await _load();
    }
  }

  Future<void> _showPasscode(AdminResetTicket ticket, ApprovedPasscode code) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false, // make sure the admin has noted the code
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.verified_user_rounded,
            color: Color(0xFF16A34A), size: 44),
        title: Text('Ticket #${code.ticketNo} approved'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Give this temporary passcode to ${ticket.name}:',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.fieldBorder),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SelectableText(
                    code.passcode,
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 6,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy passcode',
                    icon: const Icon(Icons.copy_rounded,
                        color: AppColors.crimson),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code.passcode));
                      _showSnack('Passcode copied.');
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Expires at ${CampusTime.clockLabel(code.expiresAt)} '
              '(60 minutes). It won\'t be shown again. If it\'s lost, '
              'tap "New code" on the ticket.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.subtext, height: 1.4),
            ),
          ],
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.crimson),
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ===========================================================================
  // UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final pending = _pending;
    final approved = _approved;

    return Material(
      color: AppColors.surface,
      elevation: 1.5,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- Header with counter badge ----
            Row(
              children: [
                const Icon(Icons.lock_reset_rounded, color: AppColors.crimson),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Password Reset Requests',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                if (!_loading && pending.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.crimson,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${pending.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                  ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded,
                      color: AppColors.textSecondary),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(right: 8, bottom: 8),
              child: Text(
                "Check the student's ID card before approving.",
                style: TextStyle(fontSize: 12.5, color: AppColors.subtext),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _buildContent(pending, approved),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
      List<AdminResetTicket> pending, List<AdminResetTicket> approved) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: CircularProgressIndicator(color: AppColors.crimson),
        ),
      );
    }
    if (_error != null) {
      return Column(
        children: [
          Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary)),
          TextButton(
            onPressed: _refresh,
            style: TextButton.styleFrom(foregroundColor: AppColors.crimson),
            child: const Text('Try again'),
          ),
        ],
      );
    }
    if (pending.isEmpty && approved.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Icon(Icons.inbox_outlined, color: AppColors.subtext),
            SizedBox(width: 10),
            Text('No pending requests.',
                style: TextStyle(color: AppColors.subtext)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pending.isNotEmpty) ...[
          _SubHeader('Pending (${pending.length})'),
          for (final t in pending)
            _TicketTile(
              ticket: t,
              busy: _busyId == t.id,
              actions: [
                OutlinedButton(
                  onPressed: _busyId == null ? () => _reject(t) : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: const BorderSide(color: AppColors.fieldBorder),
                  ),
                  child: const Text('Reject'),
                ),
                FilledButton(
                  onPressed: _busyId == null ? () => _approve(t) : null,
                  style: FilledButton.styleFrom(
                      backgroundColor: AppColors.crimson),
                  child: const Text('Approve'),
                ),
              ],
            ),
        ],
        if (approved.isNotEmpty) ...[
          _SubHeader('Waiting for student (${approved.length})'),
          for (final t in approved)
            _TicketTile(
              ticket: t,
              busy: _busyId == t.id,
              actions: [
                TextButton(
                  onPressed: _busyId == null ? () => _reject(t) : null,
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary),
                  child: const Text('Cancel'),
                ),
                OutlinedButton(
                  onPressed: _busyId == null ? () => _approve(t) : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.crimson,
                    side: BorderSide(color: AppColors.crimson.withAlpha(90)),
                  ),
                  child: const Text('New code'),
                ),
              ],
            ),
        ],
      ],
    );
  }
}

class _SubHeader extends StatelessWidget {
  const _SubHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.subtext,
        ),
      ),
    );
  }
}

/// One ticket: number, student ID, email, request time, and buttons.
class _TicketTile extends StatelessWidget {
  const _TicketTile({
    required this.ticket,
    required this.busy,
    required this.actions,
  });

  final AdminResetTicket ticket;
  final bool busy;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.fieldBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '#${ticket.ticketNo}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppColors.crimson,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  ticket.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _Line(icon: Icons.badge_outlined, text: ticket.studentId),
          _Line(icon: Icons.mail_outline_rounded, text: ticket.email),
          _Line(
            icon: Icons.schedule_rounded,
            text: ticket.isPending
                ? 'Requested ${CampusTime.dayAndClock(ticket.requestedAt)}'
                : 'Code expires ${ticket.expiresAt == null ? '-' : CampusTime.clockLabel(ticket.expiresAt!)}',
          ),
          const SizedBox(height: 10),
          busy
              ? const Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.5, color: AppColors.crimson),
                  ),
                )
              : Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 8),
                      actions[i],
                    ],
                  ],
                ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppColors.subtext),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text,
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
