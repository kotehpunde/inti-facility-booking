import 'dart:async';

import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../theme/app_theme.dart';
import '../utils/campus_time.dart';
import '../widgets/admin_common.dart';

/// "Student Directory & Governance": search every student account, see
/// how much they book (and how often they don't turn up), and suspend or
/// restore an account.
///
/// Suspending logs the student out straight away (the database deletes
/// their sessions) and blocks them from logging in or booking until an
/// admin restores the account.
class AdminStudentsScreen extends StatefulWidget {
  const AdminStudentsScreen({super.key});

  @override
  State<AdminStudentsScreen> createState() => _AdminStudentsScreenState();
}

class _AdminStudentsScreenState extends State<AdminStudentsScreen> {
  final _service = AdminService();
  final _searchController = TextEditingController();

  Timer? _debounce;
  List<AdminStudentSummary> _students = const [];
  bool _loading = true;
  String? _error;
  String? _busyId; // student being suspended / restored

  /// Ignore a slow response for a search the admin already changed.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final requestId = ++_requestId;
    try {
      final students =
          await _service.students(search: _searchController.text);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _students = students;
        _loading = false;
        _error = null;
      });
    } on AdminFailure catch (e) {
      if (!mounted || requestId != _requestId) return;
      if (e.needsLogin) {
        await handleAdminFailure(context, e);
        return;
      }
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// Searches 350 ms after the admin stops typing.
  void _onSearchChanged(String _) {
    setState(() {}); // show / hide the clear button
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _loading = true);
      _load();
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    setState(() => _loading = true);
    _load();
  }

  Future<void> _toggle(AdminStudentSummary s) async {
    final suspend = !s.isSuspended;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: Icon(
          suspend ? Icons.gavel_rounded : Icons.lock_open_rounded,
          color: suspend ? AppColors.crimson : AdminBadge.greenFg,
        ),
        title: Text(suspend ? 'Suspend this account?' : 'Restore this account?'),
        content: Text(
          suspend
              ? '${s.name} (${s.studentId}) will be logged out immediately '
                  'and won\'t be able to log in or make bookings until you '
                  'restore the account.\n\n'
                  'Their existing bookings are kept. Cancel them in Master '
                  'Bookings if needed.'
              : '${s.name} (${s.studentId}) will be able to log in and book '
                  'facilities again.',
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor:
                  suspend ? AppColors.crimson : AdminBadge.greenFg,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(suspend ? 'Suspend account' : 'Restore account'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busyId = s.id);
    try {
      await _service.toggleSuspension(s.id, suspend);
      if (!mounted) return;
      showAdminSnack(
        context,
        suspend
            ? '${s.name} has been suspended and logged out.'
            : '${s.name} can use the app again.',
        success: !suspend,
      );
    } on AdminFailure catch (e) {
      if (!mounted) return;
      if (await handleAdminFailure(context, e)) return;
    }
    await _load();
    if (mounted) setState(() => _busyId = null);
  }

  @override
  Widget build(BuildContext context) {
    final suspendedCount = _students.where((s) => s.isSuspended).length;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: adminAppBar(context, 'Student Directory'),
      body: Column(
        children: [
          // ---- Search ----
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 15),
              decoration: AppTheme.field(
                label: 'Search name, Student ID or email',
                icon: Icons.search_rounded,
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: _clearSearch,
                      ),
              ),
            ),
          ),
          if (!_loading && _error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Text(
                    '${_students.length} '
                    '${_students.length == 1 ? 'student' : 'students'}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (suspendedCount > 0) ...[
                    const SizedBox(width: 8),
                    AdminBadge(
                      label: '$suspendedCount SUSPENDED',
                      background: AdminBadge.redBg,
                      foreground: AdminBadge.redFg,
                    ),
                  ],
                ],
              ),
            ),
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.crimson));
    }
    return RefreshIndicator(
      color: AppColors.crimson,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          if (_error != null)
            AdminMessage(
              icon: Icons.cloud_off_rounded,
              title: "Couldn't load students",
              message: _error,
              actionLabel: 'Try again',
              onAction: () {
                setState(() => _loading = true);
                _load();
              },
            )
          else if (_students.isEmpty)
            AdminMessage(
              icon: Icons.person_search_rounded,
              title: _searchController.text.trim().isEmpty
                  ? 'No student accounts yet'
                  : 'No students match "${_searchController.text.trim()}"',
            )
          else
            for (final s in _students)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _StudentTile(
                  student: s,
                  busy: _busyId == s.id,
                  onToggle: _busyId == null ? () => _toggle(s) : null,
                ),
              ),
        ],
      ),
    );
  }
}

class _StudentTile extends StatelessWidget {
  const _StudentTile({
    required this.student,
    required this.busy,
    required this.onToggle,
  });

  final AdminStudentSummary student;
  final bool busy;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final s = student;
    final suspended = s.isSuspended;
    return AdminCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: suspended
                    ? AdminBadge.greyBg
                    : AppColors.crimson.withAlpha(20),
                child: Text(
                  s.initial,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: suspended ? AdminBadge.greyFg : AppColors.crimson,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (s.displayName != null &&
                        s.displayName!.trim().isNotEmpty &&
                        s.displayName != s.name)
                      Text(
                        'Goes by "${s.displayName}"',
                        style: const TextStyle(
                            fontSize: 12.5, color: AppColors.subtext),
                      ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        AdminBadge(
                          label: s.studentId,
                          icon: Icons.badge_outlined,
                          background: AppColors.crimson.withAlpha(18),
                          foreground: AppColors.crimson,
                        ),
                        suspended
                            ? const AdminBadge(
                                label: 'SUSPENDED',
                                background: AdminBadge.redBg,
                                foreground: AdminBadge.redFg,
                              )
                            : const AdminBadge(
                                label: 'ACTIVE',
                                background: AdminBadge.greenBg,
                                foreground: AdminBadge.greenFg,
                              ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                _Line(icon: Icons.mail_outline_rounded, text: s.email, selectable: true),
                _Line(
                  icon: Icons.event_note_rounded,
                  text: '${s.bookingCount} total '
                      '${s.bookingCount == 1 ? 'booking' : 'bookings'}'
                      '${s.noShowCount > 0 ? ' · ${s.noShowCount} no-show${s.noShowCount == 1 ? '' : 's'}' : ''}',
                  warn: s.noShowCount > 0,
                ),
                _Line(
                  icon: Icons.calendar_today_outlined,
                  text: 'Joined ${CampusTime.shortDate(s.createdAt)} ${s.createdAt.year}',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 42,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onToggle,
              style: OutlinedButton.styleFrom(
                foregroundColor:
                    suspended ? AdminBadge.greenFg : AppColors.crimson,
                side: BorderSide(
                  color: (suspended ? AdminBadge.greenFg : AppColors.crimson)
                      .withAlpha(90),
                ),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.crimson),
                    )
                  : Icon(
                      suspended
                          ? Icons.lock_open_rounded
                          : Icons.block_rounded,
                      size: 18),
              label: Text(busy
                  ? 'Saving…'
                  : suspended
                      ? 'Unsuspend account'
                      : 'Suspend account'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.text,
    this.selectable = false,
    this.warn = false,
  });

  final IconData icon;
  final String text;
  final bool selectable;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 13,
      color: warn ? AdminBadge.amberFg : AppColors.textSecondary,
      fontWeight: warn ? FontWeight.w600 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 15, color: warn ? AdminBadge.amberFg : AppColors.subtext),
          const SizedBox(width: 8),
          Expanded(
            child: selectable
                ? SelectableText(text, style: style)
                : Text(text, style: style),
          ),
        ],
      ),
    );
  }
}
