import 'package:flutter/material.dart';

import '../models/my_booking.dart';
import '../navigation.dart';
import '../services/booking_service.dart';
import '../services/notification_service.dart';
import '../services/session_manager.dart';
import '../theme/app_theme.dart';
import '../utils/campus_time.dart';
import 'facility_selection_screen.dart';

/// "My Bookings": the student's reservations as ticket cards.
///
/// Upcoming bookings (TODAY / UPCOMING badges) come first, soonest at the
/// top; past and cancelled ones follow (COMPLETED / CANCELLED).
/// Cancelling updates Supabase, removes the local reminder and refreshes.
class MyBookingsScreen extends StatefulWidget {
  const MyBookingsScreen({super.key});

  @override
  State<MyBookingsScreen> createState() => _MyBookingsScreenState();
}

class _MyBookingsScreenState extends State<MyBookingsScreen> {
  final _service = BookingService();

  List<MyBooking> _bookings = const [];
  bool _loading = true;
  String? _error;

  /// booking_ref of the booking being cancelled (shows a spinner on its card).
  String? _cancellingRef;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ===========================================================================
  // Data
  // ===========================================================================

  /// Also used by pull-to-refresh and the "Try again" button.
  Future<void> _load() async {
    final token = await SessionManager.token();
    if (!mounted) return;
    if (token == null) {
      await logOut(context);
      return;
    }
    try {
      final bookings = await _service.getMyBookings(token);
      if (!mounted) return;
      setState(() {
        _bookings = bookings;
        _loading = false;
        _error = null;
      });
      // Keep this phone's reminders in step with the bookings (e.g. after a
      // reinstall, or a booking cancelled on another phone).
      NotificationService.syncReminders(bookings);
    } on BookingFailure catch (e) {
      if (!mounted) return;
      if (e.code == BookingFailure.sessionExpired) {
        await logOut(context,
            message: 'Your session has expired. Please log in again.');
        return;
      }
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _load();
  }

  /// Upcoming first (soonest at the top), then history (newest at the top).
  ({List<MyBooking> active, List<MyBooking> history}) get _sections {
    final active = _bookings.where((b) => b.isActive).toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    final history = _bookings.where((b) => !b.isActive).toList()
      ..sort((a, b) => b.startsAt.compareTo(a.startsAt));
    return (active: active, history: history);
  }

  // ===========================================================================
  // Cancel
  // ===========================================================================

  Future<void> _confirmCancel(MyBooking booking) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Cancel this booking?'),
        content: Text(
          '${booking.facilityName} (${booking.unitName})\n'
          '${CampusTime.dateLabel(booking.date)} · '
          '${CampusTime.rangeLabel(booking.startHour, booking.endHour)}\n\n'
          'The slot will be released for other students.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep booking'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.crimson),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Cancel booking'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _cancel(booking);
  }

  Future<void> _cancel(MyBooking booking) async {
    setState(() => _cancellingRef = booking.bookingRef);
    final token = await SessionManager.token();
    if (!mounted) return;
    if (token == null) {
      await logOut(context);
      return;
    }
    try {
      await _service.cancelBooking(token: token, bookingRef: booking.bookingRef);
      await NotificationService.cancelBookingReminder(booking.bookingRef);
      if (!mounted) return;
      _showSnack('Booking cancelled.');
    } on BookingFailure catch (e) {
      if (!mounted) return;
      if (e.code == BookingFailure.sessionExpired) {
        await logOut(context,
            message: 'Your session has expired. Please log in again.');
        return;
      }
      _showSnack(e.message);
    }
    if (!mounted) return;
    setState(() => _cancellingRef = null);
    await _load(); // refresh: the ticket now shows CANCELLED
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ));
  }

  void _bookNow() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const FacilitySelectionScreen()),
    );
  }

  // ===========================================================================
  // UI
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        leading: IconButton(
          tooltip: 'Back',
          icon: const Icon(Icons.arrow_back_rounded,
              color: AppColors.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'My Bookings',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.crimson),
      );
    }
    if (_error != null) {
      return _MessageView(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't load your bookings",
        message: _error!,
        actionLabel: 'Try again',
        onAction: _retry,
      );
    }
    if (_bookings.isEmpty) {
      return _MessageView(
        icon: Icons.event_available_rounded,
        title: 'No bookings yet',
        message: 'Reserve a music room, pool table or study room '
            'and it will appear here.',
        actionLabel: 'Book a Facility',
        onAction: _bookNow,
      );
    }

    final sections = _sections;
    return RefreshIndicator(
      color: AppColors.crimson,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          _SectionHeader('Upcoming', count: sections.active.length),
          if (sections.active.isEmpty)
            const _InlineNote('No upcoming bookings.')
          else
            for (final b in sections.active) _ticket(b),
          if (sections.history.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SectionHeader('Past & cancelled', count: sections.history.length),
            for (final b in sections.history) _ticket(b),
          ],
        ],
      ),
    );
  }

  Widget _ticket(MyBooking booking) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: _BookingTicket(
        booking: booking,
        cancelling: _cancellingRef == booking.bookingRef,
        // Only one cancel at a time.
        onCancel: booking.canCancel && _cancellingRef == null
            ? () => _confirmCancel(booking)
            : null,
      ),
    );
  }
}

// =============================================================================
// Ticket card
// =============================================================================

class _BookingTicket extends StatelessWidget {
  const _BookingTicket({
    required this.booking,
    required this.cancelling,
    required this.onCancel,
  });

  final MyBooking booking;
  final bool cancelling;
  final VoidCallback? onCancel;

  IconData get _facilityIcon {
    switch (booking.facilityType) {
      case 'pool':
        return Icons.table_restaurant_rounded;
      case 'library':
        return Icons.menu_book_rounded;
      default:
        return Icons.music_note_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final badge = booking.badge;
    final faded = !booking.isActive; // past and cancelled tickets are muted
    final duration = booking.hours == 1 ? '1 hour' : '${booking.hours} hours';

    return Material(
      color: AppColors.surface,
      elevation: 1,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.fieldBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Opacity(
        opacity: faded ? 0.75 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- Header: icon, facility, unit, badge ----
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: faded
                          ? AppColors.background
                          : AppColors.crimson.withAlpha(20),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _facilityIcon,
                      color: faded ? AppColors.subtext : AppColors.crimson,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          booking.facilityName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          booking.unitName,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.subtext,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(badge),
                ],
              ),
            ),
            const _TicketDivider(),
            // ---- Date and time ----
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                children: [
                  _InfoRow(
                    icon: Icons.calendar_today_rounded,
                    text: CampusTime.dateLabel(booking.date),
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    icon: Icons.schedule_rounded,
                    text:
                        '${CampusTime.rangeLabel(booking.startHour, booking.endHour)}'
                        '  ·  $duration',
                  ),
                ],
              ),
            ),
            // ---- Cancel ----
            if (booking.canCancel)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed: cancelling ? null : onCancel,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.crimson,
                      side: BorderSide(color: AppColors.crimson.withAlpha(90)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: cancelling
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.crimson,
                            ),
                          )
                        : const Icon(Icons.close_rounded, size: 18),
                    label: Text(cancelling ? 'Cancelling…' : 'Cancel Booking'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// TODAY (amber) · UPCOMING (green) · COMPLETED (grey) · CANCELLED (red)
class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.badge);

  final BookingBadge badge;

  @override
  Widget build(BuildContext context) {
    final (String label, IconData icon, Color bg, Color fg) = switch (badge) {
      BookingBadge.today => (
          'TODAY',
          Icons.notification_important_rounded,
          const Color(0xFFFEF3C7),
          const Color(0xFFB45309),
        ),
      BookingBadge.upcoming => (
          'UPCOMING',
          Icons.event_rounded,
          const Color(0xFFDCFCE7),
          const Color(0xFF15803D),
        ),
      BookingBadge.completed => (
          'COMPLETED',
          Icons.check_rounded,
          const Color(0xFFF1F5F9),
          const Color(0xFF64748B),
        ),
      BookingBadge.cancelled => (
          'CANCELLED',
          Icons.close_rounded,
          const Color(0xFFFEE2E2),
          const Color(0xFFB91C1C),
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Dashed line between the ticket header and its details.
class _TicketDivider extends StatelessWidget {
  const _TicketDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (_, constraints) {
          const dash = 6.0, gap = 4.0;
          final count = (constraints.maxWidth / (dash + gap)).floor();
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < count; i++)
                Container(width: dash, height: 1, color: AppColors.fieldBorder),
            ],
          );
        },
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.subtext),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Section headers, empty and error states
// =============================================================================

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, {required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Text(
        '$title ($count)',
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}

class _InlineNote extends StatelessWidget {
  const _InlineNote(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text(text, style: const TextStyle(color: AppColors.subtext)),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
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
              textAlign: TextAlign.center,
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
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.crimson,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}
