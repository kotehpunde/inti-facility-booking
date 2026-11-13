import 'dart:async';

import 'package:flutter/material.dart';

import '../models/schedule_entry.dart';
import '../navigation.dart';
import '../services/booking_service.dart';
import '../services/session_manager.dart';
import '../theme/app_theme.dart';
import '../utils/campus_time.dart';

/// "Master Schedule": every confirmed booking on campus, today to 14 days
/// ahead, grouped by date and in time order.
///
/// - Filter chips narrow it to one facility instantly (no reload needed).
/// - Badges are live: IN PROGRESS / UPCOMING / COMPLETED, re-checked every
///   minute along with a quiet refresh from Supabase.
/// - Bookers appear by first name only; the database never sends more.
class MasterScheduleScreen extends StatefulWidget {
  const MasterScheduleScreen({super.key});

  @override
  State<MasterScheduleScreen> createState() => _MasterScheduleScreenState();
}

/// One filter chip: label + the `facility_type` it shows (null = all).
typedef _Filter = ({String label, String? type});

class _MasterScheduleScreenState extends State<MasterScheduleScreen> {
  static const List<_Filter> _filters = [
    (label: 'All', type: null),
    (label: 'Music Room', type: 'music'),
    (label: 'Pool Tables', type: 'pool'),
    (label: 'Library Rooms', type: 'library'),
  ];

  final _service = BookingService();

  List<ScheduleEntry> _entries = const [];
  _Filter _filter = _filters.first;
  bool _loading = true;
  String? _error;

  /// Every minute: refresh data quietly and re-evaluate the live badges.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _load();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) => _load());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // ===========================================================================
  // Data
  // ===========================================================================

  /// Used on open, by pull-to-refresh and by the 1-minute ticker.
  Future<void> _load() async {
    final token = await SessionManager.token();
    if (!mounted) return;
    if (token == null) {
      await logOut(context);
      return;
    }
    try {
      final entries = await _service.getMasterSchedule(token);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _error = null;
      });
    } on BookingFailure catch (e) {
      if (!mounted) return;
      if (e.code == BookingFailure.sessionExpired) {
        _ticker?.cancel();
        await logOut(context,
            message: 'Your session has expired. Please log in again.');
        return;
      }
      // Keep showing the last good data if a background refresh fails.
      setState(() {
        _loading = false;
        if (_entries.isEmpty) _error = e.message;
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

  /// Entries for the selected chip, grouped by date (already in time order
  /// from Supabase; sorted again here to be safe).
  List<({DateTime date, List<ScheduleEntry> items})> get _groups {
    final visible = _entries
        .where((e) => _filter.type == null || e.facilityType == _filter.type)
        .toList()
      ..sort((a, b) {
        final byTime = a.startsAt.compareTo(b.startsAt);
        return byTime != 0 ? byTime : a.unitName.compareTo(b.unitName);
      });

    final groups = <({DateTime date, List<ScheduleEntry> items})>[];
    for (final entry in visible) {
      if (groups.isEmpty || !CampusTime.isSameDay(groups.last.date, entry.date)) {
        groups.add((date: entry.date, items: [entry]));
      } else {
        groups.last.items.add(entry);
      }
    }
    return groups;
  }

  /// "Today - 15 Oct", "Tomorrow - 16 Oct", "Sat - 17 Oct"
  String _dateHeader(DateTime date) {
    final today = CampusTime.today();
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    final short = CampusTime.shortDate(date);
    if (CampusTime.isSameDay(date, today)) return 'Today - $short';
    if (CampusTime.isSameDay(date, tomorrow)) return 'Tomorrow - $short';
    return '${CampusTime.dateLabel(date).split(',').first} - $short';
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
          'Master Schedule',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: Column(
        children: [
          _FilterBar(
            filters: _filters,
            selected: _filter,
            onSelected: (f) => setState(() => _filter = f),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.crimson),
      );
    }
    if (_error != null) {
      return _EmptyState(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't load the schedule",
        message: _error!,
        actionLabel: 'Try again',
        onAction: _retry,
      );
    }

    final groups = _groups;
    return RefreshIndicator(
      color: AppColors.crimson,
      onRefresh: _load,
      child: groups.isEmpty
          // ListView (not Center) so pull-to-refresh still works when empty.
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 80),
                _EmptyState(
                  icon: Icons.event_busy_rounded,
                  title: _filter.type == null
                      ? 'No bookings scheduled'
                      : 'No bookings scheduled for this facility',
                  message: 'Every slot is free for the next 14 days. '
                      'Pull down to refresh.',
                ),
              ],
            )
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: [
                const _PrivacyNote(),
                for (final group in groups) ...[
                  _DateHeader(
                    label: _dateHeader(group.date),
                    count: group.items.length,
                  ),
                  for (final entry in group.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ScheduleCard(entry: entry),
                    ),
                ],
              ],
            ),
    );
  }
}

// =============================================================================
// Filter chips
// =============================================================================

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filters,
    required this.selected,
    required this.onSelected,
  });

  final List<_Filter> filters;
  final _Filter selected;
  final ValueChanged<_Filter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Row(
        children: [
          for (final f in filters) ...[
            ChoiceChip(
              label: Text(f.label),
              selected: f.label == selected.label,
              onSelected: (_) => onSelected(f),
              showCheckmark: false,
              selectedColor: AppColors.crimson,
              backgroundColor: AppColors.surface,
              side: BorderSide(
                color: f.label == selected.label
                    ? AppColors.crimson
                    : AppColors.fieldBorder,
              ),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              labelStyle: TextStyle(
                fontWeight: FontWeight.w600,
                color: f.label == selected.label
                    ? Colors.white
                    : AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// List pieces
// =============================================================================

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 14, color: AppColors.subtext),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Next 14 days · bookers are shown by first name only',
              style: TextStyle(fontSize: 12, color: AppColors.subtext),
            ),
          ),
        ],
      ),
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 10),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            count == 1 ? '1 booking' : '$count bookings',
            style: const TextStyle(fontSize: 12.5, color: AppColors.subtext),
          ),
        ],
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.entry});

  final ScheduleEntry entry;

  IconData get _icon {
    switch (entry.facilityType) {
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
    final status = entry.status;
    final muted = status == ScheduleStatus.completed;
    final time = '${CampusTime.timeLabel(entry.startHour)} – '
        '${CampusTime.timeLabel(entry.endHour)}';

    return Material(
      color: AppColors.surface,
      elevation: 1,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: AppColors.fieldBorder),
      ),
      child: Opacity(
        opacity: muted ? 0.7 : 1,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---- Facility + unit + live badge ----
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: muted
                          ? AppColors.background
                          : AppColors.crimson.withAlpha(20),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _icon,
                      size: 20,
                      color: muted ? AppColors.subtext : AppColors.crimson,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${entry.facilityName} - ${entry.unitName}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusBadge(status),
                ],
              ),
              const SizedBox(height: 12),
              // ---- Time + booked by ----
              Row(
                children: [
                  const Icon(Icons.schedule_rounded,
                      size: 18, color: AppColors.textPrimary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      time,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  _BookedByTag(entry: entry),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Booked by Joel" (grey) or "Booked by you" (crimson).
class _BookedByTag extends StatelessWidget {
  const _BookedByTag({required this.entry});

  final ScheduleEntry entry;

  @override
  Widget build(BuildContext context) {
    final mine = entry.isMine;
    final fg = mine ? AppColors.crimson : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: mine ? AppColors.crimson.withAlpha(18) : AppColors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: mine ? AppColors.crimson.withAlpha(70) : AppColors.fieldBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_outline_rounded, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(
            mine ? 'Booked by you' : 'Booked by ${entry.firstName}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// IN PROGRESS (amber) · UPCOMING (green) · COMPLETED (grey)
class _StatusBadge extends StatelessWidget {
  const _StatusBadge(this.status);

  final ScheduleStatus status;

  @override
  Widget build(BuildContext context) {
    final (String label, IconData icon, Color bg, Color fg) = switch (status) {
      ScheduleStatus.inProgress => (
          'IN PROGRESS',
          Icons.play_circle_outline_rounded,
          const Color(0xFFFEF3C7),
          const Color(0xFFB45309),
        ),
      ScheduleStatus.upcoming => (
          'UPCOMING',
          Icons.event_rounded,
          const Color(0xFFDCFCE7),
          const Color(0xFF15803D),
        ),
      ScheduleStatus.completed => (
          'COMPLETED',
          Icons.check_rounded,
          const Color(0xFFF1F5F9),
          const Color(0xFF64748B),
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
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppColors.crimson.withAlpha(20),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 38, color: AppColors.crimson),
            ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.subtext, height: 1.4),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 18),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.crimson,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
