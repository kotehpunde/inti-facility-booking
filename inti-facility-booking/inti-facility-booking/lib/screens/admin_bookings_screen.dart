import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../theme/app_theme.dart';
import '../utils/campus_time.dart';
import '../widgets/admin_common.dart';

/// "Master Bookings Manager": every booking with full student details.
///
/// Filters: Today · Upcoming · Cancelled (last 30 days). Sorted by date and
/// time. "Admin Force-Cancel" marks a booking 'admin_cancelled', which
/// frees the slot for other students straight away.
///
/// Counter actions (today's bookings only):
///  * Hand Over Keys / Verify Check-in → 'checked_in'
///  * Release No-Show → 'no_show' (slot is free again)
class AdminBookingsScreen extends StatefulWidget {
  const AdminBookingsScreen({super.key});

  @override
  State<AdminBookingsScreen> createState() => _AdminBookingsScreenState();
}

class _AdminBookingsScreenState extends State<AdminBookingsScreen> {
  static const _scopes = [
    (key: 'today', label: 'Today'),
    (key: 'upcoming', label: 'Upcoming'),
    (key: 'cancelled', label: 'Cancelled'),
  ];

  final _service = AdminService();

  /// Reused by the force-cancel dialog (disposed with the screen, so it is
  /// never disposed while the dialog is still closing).
  final _reasonController = TextEditingController();

  String _scope = 'today';
  List<AdminBooking> _bookings = const [];
  bool _loading = true;
  String? _error;
  /// Booking currently being saved, and which action is running.
  String? _busyRef;
  _Action? _busyAction;

  /// Ignore a slow response for a filter the admin already left.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final requestId = ++_requestId;
    final scope = _scope;
    try {
      final bookings = await _service.bookings(scope);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _bookings = bookings;
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

  void _changeScope(String scope) {
    if (scope == _scope) return;
    setState(() {
      _scope = scope;
      _loading = true;
      _error = null;
      _bookings = const [];
    });
    _load();
  }

  Future<void> _forceCancel(AdminBooking b) async {
    _reasonController.clear();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Force-cancel this booking?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${b.fullName} (${b.studentId})\n'
              '${b.facilityName} - ${b.unitName}\n'
              '${CampusTime.dateLabel(b.date)} · '
              '${CampusTime.rangeLabel(b.startHour, b.endHour)}',
              style: const TextStyle(height: 1.45),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _reasonController,
              maxLength: 120,
              decoration: AppTheme.field(
                label: 'Reason (optional)',
                icon: Icons.edit_note_rounded,
                helperText: 'e.g. Room needed for an official event',
              ),
            ),
            const Text(
              'The slot is freed for other students immediately.',
              style: TextStyle(fontSize: 12.5, color: AppColors.subtext),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep booking'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.crimson),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Force-cancel'),
          ),
        ],
      ),
    );
    final reason = _reasonController.text.trim();
    if (confirmed != true || !mounted) return;

    await _run(
      b,
      _Action.cancel,
      () => _service.forceCancel(b.bookingRef,
          reason: reason.isEmpty ? null : reason),
      'Booking cancelled. The slot is free again.',
    );
  }

  /// "Hand Over Keys": the student is at the counter.
  Future<void> _checkIn(AdminBooking b) => _run(
        b,
        _Action.checkIn,
        () => _service.verifyCheckIn(b.bookingRef),
        'Keys handed over. ${b.fullName} is checked in.',
      );

  /// The student didn't turn up: free the slot for someone else.
  Future<void> _releaseNoShow(AdminBooking b) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.timer_off_rounded, color: AdminBadge.amberFg),
        title: const Text('Release as a no-show?'),
        content: Text(
          '${b.fullName} (${b.studentId}) hasn\'t collected the keys for\n'
          '${b.facilityName} - ${b.unitName} · '
          '${CampusTime.rangeLabel(b.startHour, b.endHour)}.\n\n'
          'The booking will be marked as a no-show on their record and the '
          'slot opens up for other students straight away.',
          style: const TextStyle(height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep waiting'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AdminBadge.amberFg),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Release slot'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(
      b,
      _Action.noShow,
      () => _service.releaseNoShow(b.bookingRef),
      'No-show recorded. ${b.unitName} is open for booking again.',
    );
  }

  /// Runs one admin action on a booking, shows the result, reloads.
  Future<void> _run(AdminBooking b, _Action action,
      Future<void> Function() call, String done) async {
    setState(() {
      _busyRef = b.bookingRef;
      _busyAction = action;
    });
    try {
      await call();
      if (!mounted) return;
      showAdminSnack(context, done, success: true);
    } on AdminFailure catch (e) {
      if (!mounted) return;
      if (await handleAdminFailure(context, e)) return;
    }
    if (!mounted) return;
    setState(() {
      _busyRef = null;
      _busyAction = null;
    });
    await _load();
  }

  /// Groups bookings under date headers (already sorted by the database).
  List<({DateTime date, List<AdminBooking> items})> get _groups {
    final groups = <({DateTime date, List<AdminBooking> items})>[];
    for (final b in _bookings) {
      if (groups.isEmpty || !CampusTime.isSameDay(groups.last.date, b.date)) {
        groups.add((date: b.date, items: [b]));
      } else {
        groups.last.items.add(b);
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: adminAppBar(context, 'Master Bookings'),
      body: Column(
        children: [
          // ---- Filter chips ----
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                for (final s in _scopes) ...[
                  ChoiceChip(
                    label: Text(s.label),
                    selected: _scope == s.key,
                    onSelected: (_) => _changeScope(s.key),
                    showCheckmark: false,
                    selectedColor: AppColors.crimson,
                    backgroundColor: AppColors.surface,
                    side: BorderSide(
                      color: _scope == s.key
                          ? AppColors.crimson
                          : AppColors.fieldBorder,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    labelStyle: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: _scope == s.key
                          ? Colors.white
                          : AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 8),
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
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          if (_error != null)
            AdminMessage(
              icon: Icons.cloud_off_rounded,
              title: "Couldn't load bookings",
              message: _error,
              actionLabel: 'Try again',
              onAction: () {
                setState(() => _loading = true);
                _load();
              },
            )
          else if (_bookings.isEmpty)
            AdminMessage(
              icon: Icons.event_busy_rounded,
              title: switch (_scope) {
                'today' => 'No bookings today',
                'upcoming' => 'No upcoming bookings',
                _ => 'No cancellations or no-shows in the last 30 days',
              },
            )
          else
            for (final group in _groups) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 10),
                child: Text(
                  '${CampusTime.dateLabel(group.date)} · '
                  '${group.items.length} '
                  '${group.items.length == 1 ? 'booking' : 'bookings'}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              for (final b in group.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _AdminBookingCard(
                    booking: b,
                    busyAction: _busyRef == b.bookingRef ? _busyAction : null,
                    enabled: _busyRef == null,
                    onForceCancel: () => _forceCancel(b),
                    onCheckIn: () => _checkIn(b),
                    onReleaseNoShow: () => _releaseNoShow(b),
                  ),
                ),
            ],
        ],
      ),
    );
  }
}

enum _Action { cancel, checkIn, noShow }

class _AdminBookingCard extends StatelessWidget {
  const _AdminBookingCard({
    required this.booking,
    required this.busyAction,
    required this.enabled,
    required this.onForceCancel,
    required this.onCheckIn,
    required this.onReleaseNoShow,
  });

  final AdminBooking booking;
  final _Action? busyAction; // running on THIS card, if any
  final bool enabled; // false while any card is saving
  final VoidCallback onForceCancel;
  final VoidCallback onCheckIn;
  final VoidCallback onReleaseNoShow;

  IconData get _icon => switch (booking.facilityType) {
        'pool' => Icons.table_restaurant_rounded,
        'library' => Icons.menu_book_rounded,
        _ => Icons.music_note_rounded,
      };

  AdminBadge get _badge {
    if (booking.isCheckedIn) {
      return const AdminBadge(
        label: 'CHECKED IN',
        icon: Icons.key_rounded,
        background: AdminBadge.greenBg,
        foreground: AdminBadge.greenFg,
      );
    }
    if (booking.isNoShow) {
      return const AdminBadge(
        label: 'NO SHOW',
        icon: Icons.timer_off_rounded,
        background: AdminBadge.amberBg,
        foreground: AdminBadge.redFg,
      );
    }
    if (booking.status == 'admin_cancelled') {
      return const AdminBadge(
        label: 'ADMIN CANCELLED',
        background: AdminBadge.redBg,
        foreground: AdminBadge.redFg,
      );
    }
    if (booking.status == 'cancelled') {
      return const AdminBadge(
        label: 'CANCELLED BY STUDENT',
        background: AdminBadge.greyBg,
        foreground: AdminBadge.greyFg,
      );
    }
    final n = CampusTime.now();
    final now = DateTime(n.year, n.month, n.day, n.hour, n.minute);
    if (!booking.endsAt.isAfter(now)) {
      return const AdminBadge(
        label: 'COMPLETED',
        background: AdminBadge.greyBg,
        foreground: AdminBadge.greyFg,
      );
    }
    if (!booking.startsAt.isAfter(now)) {
      return const AdminBadge(
        label: 'IN PROGRESS',
        background: AdminBadge.amberBg,
        foreground: AdminBadge.amberFg,
      );
    }
    // Blue, so it isn't confused with the green CHECKED IN badge.
    return const AdminBadge(
      label: 'UPCOMING',
      background: Color(0xFFDBEAFE),
      foreground: Color(0xFF1D4ED8),
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = booking;
    return AdminCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: AppColors.crimson.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_icon, size: 20, color: AppColors.crimson),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${b.facilityName} - ${b.unitName}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      CampusTime.rangeLabel(b.startHour, b.endHour),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _badge,
            ],
          ),
          const SizedBox(height: 12),
          // ---- Student accountability details ----
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                _Detail(icon: Icons.person_outline_rounded, text: b.fullName),
                _Detail(icon: Icons.badge_outlined, text: b.studentId),
                _Detail(icon: Icons.mail_outline_rounded, text: b.email),
              ],
            ),
          ),
          if (b.checkedInAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Keys handed over at ${CampusTime.clockLabel(b.checkedInAt!)}',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AdminBadge.greenFg,
              ),
            ),
          ],
          if (b.cancelReason != null) ...[
            const SizedBox(height: 8),
            Text(
              'Reason: ${b.cancelReason}',
              style: const TextStyle(fontSize: 12.5, color: AppColors.subtext),
            ),
          ],
          // ---- Counter actions (today only) ----
          if (b.canUseCounterActions) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 44,
              child: FilledButton.icon(
                onPressed: enabled ? onCheckIn : null,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF16A34A),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: busyAction == _Action.checkIn
                    ? const _Spinner(color: Colors.white)
                    : const Icon(Icons.key_rounded, size: 18),
                label: Text(busyAction == _Action.checkIn
                    ? 'Checking in…'
                    : 'Hand Over Keys / Verify Check-in'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 42,
              child: OutlinedButton.icon(
                onPressed: enabled ? onReleaseNoShow : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AdminBadge.amberFg,
                  side: BorderSide(color: AdminBadge.amberFg.withAlpha(110)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: busyAction == _Action.noShow
                    ? const _Spinner(color: AdminBadge.amberFg)
                    : const Icon(Icons.timer_off_rounded, size: 18),
                label: Text(busyAction == _Action.noShow
                    ? 'Releasing…'
                    : 'Release No-Show'),
              ),
            ),
          ],
          if (b.canForceCancel) ...[
            SizedBox(height: b.canUseCounterActions ? 8 : 12),
            SizedBox(
              height: 42,
              child: OutlinedButton.icon(
                onPressed: enabled ? onForceCancel : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.crimson,
                  side: BorderSide(color: AppColors.crimson.withAlpha(90)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: busyAction == _Action.cancel
                    ? const _Spinner(color: AppColors.crimson)
                    : const Icon(Icons.block_rounded, size: 18),
                label: Text(busyAction == _Action.cancel
                    ? 'Cancelling…'
                    : 'Admin Force-Cancel'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
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

class _Spinner extends StatelessWidget {
  const _Spinner({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
}
