import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/booking_rules.dart';
import '../models/facility.dart';
import '../navigation.dart';
import '../services/booking_service.dart';
import '../services/notification_service.dart';
import '../services/session_manager.dart';
import '../theme/app_theme.dart';
import '../utils/campus_time.dart';
import '../widgets/primary_button.dart';

/// One booking screen for every facility.
///
/// Everything that differs between Music Room, Pool Tables and Library
/// Discussion Rooms (units, slot limits, daily cap) comes from
/// [FacilityRules], so this screen has no facility-specific code.
///
/// Sections, top to bottom:
///   notice banner → popular-times chart → unit chips (if several units)
///   → date card → time-slot grid → "Confirm Booking" button (bottom bar)
class FacilityBookingScreen extends StatefulWidget {
  const FacilityBookingScreen({super.key, required this.facility});

  final Facility facility;

  @override
  State<FacilityBookingScreen> createState() => _FacilityBookingScreenState();
}

/// How one time slot is shown.
enum _SlotState { available, selected, booked, mine, past }

class _FacilityBookingScreenState extends State<FacilityBookingScreen> {
  static const _limitMessage =
      'Maximum booking limit for this facility is 2 hours per day.';

  /// Typical campus busyness (8 AM … 5 PM), used until there is enough
  /// real booking history. Peaks over lunch, 12 PM – 2 PM.
  static const _typicalBusyness = <double>[
    0.15, 0.30, 0.45, 0.60, 0.95, 1.00, 0.80, 0.55, 0.40, 0.25,
  ];

  late final FacilityRules _rules = FacilityRules.forFacility(widget.facility);
  final _service = BookingService();

  // ---- Selection state ----
  late FacilityUnit _unit = _rules.units.first;
  DateTime _date = CampusTime.today();
  final Set<int> _selected = {}; // start hours, e.g. {10, 11}

  // ---- Data from Supabase ----
  SlotAvailability _availability = SlotAvailability.empty;
  bool _loadingSlots = true;
  String? _slotsError;
  List<double>? _busyness; // 0..1 per hour; null while loading
  bool _busynessIsTypical = true;

  bool _submitting = false;

  /// Which units are open (from facility_units). Missing = assume open.
  Map<String, bool> _unitOpen = const {};

  /// Increases on every slot request, so a slow old response (e.g. for the
  /// previous room) can't overwrite the newest one.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _fetchSlots();
    _fetchBusyness();
    _fetchUnitStatus();
  }

  /// Loads maintenance status. If the chosen unit is closed, switches to
  /// the first open one.
  Future<void> _fetchUnitStatus() async {
    final status = await _service.getUnitStatus(_rules.type);
    if (!mounted) return;
    setState(() => _unitOpen = status);
    if (!_isUnitOpen(_unit)) {
      final open = _rules.units.where(_isUnitOpen);
      if (open.isNotEmpty) _onUnitChanged(open.first);
    }
  }

  bool _isUnitOpen(FacilityUnit unit) => _unitOpen[unit.name] ?? true;

  // ===========================================================================
  // Data loading
  // ===========================================================================

  /// Shows the loading state, then fetches. Used after the unit or date changes.
  void _reloadSlots() {
    setState(() {
      _loadingSlots = true;
      _slotsError = null;
    });
    _fetchSlots();
  }

  Future<void> _fetchSlots() async {
    final requestId = ++_requestId;
    final token = await SessionManager.token();
    if (!mounted) return;
    if (token == null) {
      await logOut(context);
      return;
    }
    try {
      final availability = await _service.getAvailability(
        token: token,
        facilityType: _rules.type,
        unitName: _unit.name,
        date: _date,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _availability = availability;
        _loadingSlots = false;
        // Drop any selected slot that has just been taken.
        _selected.removeWhere((h) => _stateOf(h) != _SlotState.selected);
      });
    } on BookingFailure catch (e) {
      if (!mounted || requestId != _requestId) return;
      if (e.code == BookingFailure.sessionExpired) {
        await logOut(context,
            message: 'Your session has expired. Please log in again.');
        return;
      }
      setState(() {
        _loadingSlots = false;
        _slotsError = e.message;
      });
    }
  }

  Future<void> _fetchBusyness() async {
    final counts = await _service.getHourlyBusyness(_rules.type);
    if (!mounted) return;

    final hours = FacilityRules.slotStartHours.length;
    final total = counts.fold<int>(0, (sum, n) => sum + n);
    // Need some history before real data is meaningful.
    final useTypical = counts.length != hours || total < 10;
    final raw = useTypical
        ? _typicalBusyness
        : [for (final n in counts) n.toDouble()];
    final peak = raw.reduce(math.max);

    setState(() {
      _busyness = [for (final v in raw) peak == 0 ? 0.0 : v / peak];
      _busynessIsTypical = useTypical;
    });
  }

  // ===========================================================================
  // Slot rules
  // ===========================================================================

  bool get _isToday => CampusTime.isSameDay(_date, CampusTime.today());

  _SlotState _stateOf(int hour) {
    if (_isToday && hour <= CampusTime.now().hour) return _SlotState.past;
    if (_availability.mine.contains(hour)) return _SlotState.mine;
    if (_availability.booked.contains(hour)) return _SlotState.booked;
    if (_selected.contains(hour)) return _SlotState.selected;
    return _SlotState.available;
  }

  /// How many slots the student may still pick for this booking.
  int get _allowedSlots {
    final limit = _rules.dailyLimitHours;
    if (limit == null) return _rules.maxSlotsPerBooking;
    final remaining = limit - _availability.myHoursToday;
    return math.max(0, math.min(_rules.maxSlotsPerBooking, remaining));
  }

  void _onSlotTap(int hour) {
    final state = _stateOf(hour);
    if (state == _SlotState.selected) {
      setState(() => _selected.remove(hour));
      return;
    }
    if (state != _SlotState.available) return;

    // Pool tables: one 1-hour slot per booking, so tapping swaps the choice.
    if (_rules.maxSlotsPerBooking == 1) {
      setState(() => _selected
        ..clear()
        ..add(hour));
      return;
    }

    // Music / Library: up to 2 back-to-back hours per day.
    if (_selected.length >= _allowedSlots) {
      final used = _availability.myHoursToday;
      _showSnack(used > 0
          ? '$_limitMessage You already have $used '
              '${used == 1 ? 'hour' : 'hours'} booked on this day.'
          : _limitMessage);
      return;
    }

    final isAdjacent = _selected.isEmpty ||
        hour == _selected.reduce(math.min) - 1 ||
        hour == _selected.reduce(math.max) + 1;
    setState(() {
      if (!isAdjacent) _selected.clear(); // not back-to-back: start over
      _selected.add(hour);
    });
  }

  // ===========================================================================
  // Actions
  // ===========================================================================

  void _onUnitChanged(FacilityUnit unit) {
    if (unit.name == _unit.name || !_isUnitOpen(unit)) return;
    _unit = unit;
    _selected.clear();
    _reloadSlots();
  }

  Future<void> _pickDate() async {
    final today = CampusTime.today();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: today,
      lastDate: DateTime(
          today.year, today.month, today.day + FacilityRules.maxDaysAhead),
      helpText: 'Choose a booking date',
    );
    if (!mounted || picked == null || CampusTime.isSameDay(picked, _date)) {
      return;
    }
    _date = picked;
    _selected.clear();
    _reloadSlots();
  }

  Future<void> _confirmBooking() async {
    if (_selected.isEmpty || _submitting) return;
    final hours = _selected.toList()..sort();

    setState(() => _submitting = true);
    final token = await SessionManager.token();
    if (!mounted) return;
    if (token == null) {
      await logOut(context);
      return;
    }

    try {
      final result = await _service.createBooking(
        token: token,
        facilityType: _rules.type,
        unitName: _unit.name,
        date: _date,
        startHours: hours,
      );
      // Reminder at 8:00 AM the day before (or an instant confirmation if
      // that time has passed). Never blocks or breaks the booking.
      await NotificationService.requestPermission();
      final reminder = await NotificationService.scheduleBookingReminder(
        bookingRef: result.bookingRef,
        facilityName: _rules.displayName,
        unitName: result.unitName,
        date: _date,
        startHour: result.startHour,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _selected.clear();
      });
      _reloadSlots();
      await _showSuccess(result, reminder);
    } on BookingFailure catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      switch (e.code) {
        case BookingFailure.sessionExpired:
          await logOut(context,
              message: 'Your session has expired. Please log in again.');
        case BookingFailure.slotTaken:
          _showSnack(e.message);
          _selected.clear();
          _reloadSlots(); // show the slot as booked now
        default:
          _showSnack(e.message);
      }
    }
  }

  Future<void> _showSuccess(BookingResult result, ReminderOutcome reminder) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.check_circle_rounded,
            color: Color(0xFF16A34A), size: 48),
        title: const Text('Booking confirmed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.facility.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (_rules.showUnitSelector) Text(result.unitName),
            const SizedBox(height: 8),
            Text(CampusTime.dateLabel(_date)),
            Text(
              CampusTime.rangeLabel(result.startHour, result.endHour),
              style: const TextStyle(
                color: AppColors.crimson,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (reminder == ReminderOutcome.scheduled) ...[
              const SizedBox(height: 12),
              const Text(
                "We'll remind you at 8:00 AM the day before.",
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: AppColors.subtext),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Book another'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.crimson),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              // Back to the dashboard (the first screen in the stack).
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
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
        title: Text(
          widget.facility.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          const _NoticeBanner(),
          const SizedBox(height: 16),
          _PopularTimesCard(
            values: _busyness,
            isTypical: _busynessIsTypical,
            nowHour: _isToday ? CampusTime.now().hour : null,
          ),
          if (_rules.showUnitSelector) ...[
            const SizedBox(height: 24),
            _SectionTitle(_rules.unitLabel),
            const SizedBox(height: 10),
            _UnitSelector(
              units: _rules.units,
              selected: _unit,
              isOpen: _isUnitOpen,
              onSelected: _onUnitChanged,
            ),
          ],
          const SizedBox(height: 24),
          const _SectionTitle('Date'),
          const SizedBox(height: 10),
          _DateCard(date: _date, onTap: _pickDate),
          const SizedBox(height: 24),
          const _SectionTitle('Choose a time'),
          const SizedBox(height: 4),
          Text(
            _slotHint,
            style: const TextStyle(fontSize: 13, color: AppColors.subtext),
          ),
          const SizedBox(height: 12),
          _buildSlotArea(),
          const SizedBox(height: 12),
          const _SlotLegend(),
        ],
      ),
      bottomNavigationBar: _BottomBar(
        summary: _summary,
        submitting: _submitting,
        onConfirm: _selected.isEmpty || !_isUnitOpen(_unit)
            ? null
            : _confirmBooking,
      ),
    );
  }

  String get _slotHint {
    final limit = _rules.dailyLimitHours;
    if (limit == null) {
      return '1-hour slots. Book again if you need more time.';
    }
    final used = _availability.myHoursToday;
    if (used > 0) {
      return 'You have $used of $limit hours booked on '
          '${CampusTime.shortDate(_date)}. Up to $limit back-to-back hours per day.';
    }
    return 'Up to $limit back-to-back hours per day.';
  }

  /// Text above the button, e.g. "Room 5 · Wed, 15 Oct 2026 · 10:00 – 12:00".
  String? get _summary {
    if (_selected.isEmpty) return null;
    final hours = _selected.toList()..sort();
    final range = CampusTime.rangeLabel(hours.first, hours.last + 1);
    final length = hours.length == 1 ? '1 hour' : '${hours.length} hours';
    final unit = _rules.showUnitSelector ? '${_unit.name} · ' : '';
    return '$unit${CampusTime.dateLabel(_date)} · $range ($length)';
  }

  Widget _buildSlotArea() {
    if (!_isUnitOpen(_unit)) {
      return _ErrorBox(
        icon: Icons.construction_rounded,
        message: _rules.showUnitSelector
            ? 'All ${_rules.displayName.toLowerCase()}s are closed for '
                'maintenance right now. Please check back later.'
            : '${widget.facility.name} is closed for maintenance right now. '
                'Please check back later.',
        onRetry: _fetchUnitStatus,
      );
    }
    if (_slotsError != null) {
      return _ErrorBox(message: _slotsError!, onRetry: _reloadSlots);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loadingSlots)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: LinearProgressIndicator(
              color: AppColors.crimson,
              backgroundColor: AppColors.fieldBorder,
              minHeight: 3,
            ),
          ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: FacilityRules.slotStartHours.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            mainAxisExtent: 58,
          ),
          itemBuilder: (_, index) {
            final hour = FacilityRules.slotStartHours[index];
            return _SlotChip(
              hour: hour,
              // While loading, show every slot as unavailable.
              state: _loadingSlots ? _SlotState.booked : _stateOf(hour),
              loading: _loadingSlots,
              onTap: _loadingSlots ? null : () => _onSlotTap(hour),
            );
          },
        ),
      ],
    );
  }
}

// =============================================================================
// Small building blocks
// =============================================================================

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
    );
  }
}

/// White card with 16px corners and a soft shadow, used by several sections.
class _WhiteCard extends StatelessWidget {
  const _WhiteCard({required this.child, this.onTap, this.padding});

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 1.5,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding ?? const EdgeInsets.all(16),
          child: child,
        ),
      ),
    );
  }
}

class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.crimson.withAlpha(14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.crimson.withAlpha(40)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: AppColors.crimson, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Reminder: Bookings are first come, first served. '
              'Facilities operate 8:00 AM – 6:00 PM.',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.35,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Popular times chart
// =============================================================================

/// Google-Maps-style bar chart of how busy each hour usually is.
/// The busiest hours are crimson; the current hour (if today) is dark.
class _PopularTimesCard extends StatelessWidget {
  const _PopularTimesCard({
    required this.values,
    required this.isTypical,
    required this.nowHour,
  });

  final List<double>? values; // null while loading
  final bool isTypical;
  final int? nowHour;

  static const _barAreaHeight = 84.0;
  static const _peakThreshold = 0.75;

  /// "12 PM – 2 PM": the run of busy hours around the busiest one.
  String? get _peakLabel {
    final v = values;
    if (v == null || v.isEmpty) return null;
    var top = 0;
    for (var i = 1; i < v.length; i++) {
      if (v[i] > v[top]) top = i;
    }
    if (v[top] == 0) return null;
    var start = top, end = top;
    while (start > 0 && v[start - 1] >= _peakThreshold) {
      start--;
    }
    while (end < v.length - 1 && v[end + 1] >= _peakThreshold) {
      end++;
    }
    final first = FacilityRules.openingHour + start;
    final last = FacilityRules.openingHour + end + 1;
    return '${CampusTime.hourLabel(first)} – ${CampusTime.hourLabel(last)}';
  }

  @override
  Widget build(BuildContext context) {
    final hours = FacilityRules.slotStartHours;
    final peakLabel = _peakLabel;

    return _WhiteCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.bar_chart_rounded, color: AppColors.crimson, size: 20),
              SizedBox(width: 6),
              Text(
                'Popular times',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            peakLabel == null
                ? 'Loading…'
                : 'Usually busiest $peakLabel',
            style: const TextStyle(fontSize: 13, color: AppColors.subtext),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: _barAreaHeight + 16, // bars + "Now" label room
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < hours.length; i++)
                  Expanded(child: _bar(hours[i], values?[i])),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final h in hours)
                Expanded(
                  child: Text(
                    CampusTime.shortHour(h),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10, color: AppColors.subtext),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            isTypical
                ? 'Based on typical campus usage.'
                : 'Based on bookings over the last 8 weeks.',
            style: const TextStyle(fontSize: 11.5, color: AppColors.subtext),
          ),
        ],
      ),
    );
  }

  Widget _bar(int hour, double? value) {
    final isNow = hour == nowHour;
    final isPeak = value != null && value >= _peakThreshold;
    final color = value == null
        ? AppColors.fieldBorder
        : isNow
            ? AppColors.textPrimary
            : isPeak
                ? AppColors.crimson
                : AppColors.crimson.withAlpha(70);
    final height = math.max(4.0, (value ?? 0.35) * _barAreaHeight);

    return Semantics(
      label: '${CampusTime.hourLabel(hour)}: '
          '${value == null ? 'loading' : '${(value * 100).round()}% busy'}'
          '${isPeak ? ', peak' : ''}',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (isNow)
            const Text(
              'Now',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          const SizedBox(height: 2),
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
            height: height,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Unit selector, date card
// =============================================================================

class _UnitSelector extends StatelessWidget {
  const _UnitSelector({
    required this.units,
    required this.selected,
    required this.isOpen,
    required this.onSelected,
  });

  final List<FacilityUnit> units;
  final FacilityUnit selected;
  final bool Function(FacilityUnit) isOpen;
  final ValueChanged<FacilityUnit> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final unit in units) ...[
            ChoiceChip(
              label: Text(isOpen(unit) ? unit.label : '${unit.name} · Closed'),
              selected: unit.name == selected.name,
              // Closed units can't be picked (greyed out).
              onSelected: isOpen(unit) ? (_) => onSelected(unit) : null,
              showCheckmark: false,
              selectedColor: AppColors.crimson,
              backgroundColor: AppColors.surface,
              side: BorderSide(
                color: unit.name == selected.name
                    ? AppColors.crimson
                    : AppColors.fieldBorder,
              ),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              labelStyle: TextStyle(
                fontWeight: FontWeight.w600,
                color: unit.name == selected.name
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

class _DateCard extends StatelessWidget {
  const _DateCard({required this.date, required this.onTap});

  final DateTime date;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isToday = CampusTime.isSameDay(date, CampusTime.today());
    return _WhiteCard(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.crimson.withAlpha(20),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.calendar_today_rounded,
                color: AppColors.crimson, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isToday ? 'Today' : 'Booking date',
                  style: const TextStyle(fontSize: 12, color: AppColors.subtext),
                ),
                const SizedBox(height: 2),
                Text(
                  CampusTime.dateLabel(date),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          const Text(
            'Change',
            style: TextStyle(
              color: AppColors.crimson,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: AppColors.crimson),
        ],
      ),
    );
  }
}

// =============================================================================
// Time slots
// =============================================================================

class _SlotChip extends StatelessWidget {
  const _SlotChip({
    required this.hour,
    required this.state,
    required this.onTap,
    this.loading = false,
  });

  final int hour;
  final _SlotState state;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    late final Color background, border, text;
    late final String caption;
    switch (state) {
      case _SlotState.available:
        background = AppColors.surface;
        border = AppColors.fieldBorder;
        text = AppColors.textPrimary;
        caption = 'Available';
      case _SlotState.selected:
        background = AppColors.crimson;
        border = AppColors.crimson;
        text = Colors.white;
        caption = 'Selected';
      case _SlotState.mine:
        background = AppColors.crimson.withAlpha(18);
        border = AppColors.crimson.withAlpha(90);
        text = AppColors.crimson;
        caption = 'Your booking';
      case _SlotState.booked:
        background = const Color(0xFFE2E8F0);
        border = const Color(0xFFE2E8F0);
        text = const Color(0xFF94A3B8);
        caption = loading ? 'Checking…' : 'Booked';
      case _SlotState.past:
        background = const Color(0xFFF1F5F9);
        border = const Color(0xFFF1F5F9);
        text = const Color(0xFFB6C2D1);
        caption = 'Past';
    }

    final tappable =
        state == _SlotState.available || state == _SlotState.selected;

    return Semantics(
      button: tappable,
      selected: state == _SlotState.selected,
      label: '${CampusTime.slotLabel(hour)}, $caption',
      excludeSemantics: true,
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: tappable ? onTap : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                CampusTime.slotLabel(hour),
                style: TextStyle(
                  color: text,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                caption,
                style: TextStyle(
                  color: state == _SlotState.available
                      ? AppColors.subtext
                      : text,
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SlotLegend extends StatelessWidget {
  const _SlotLegend();

  @override
  Widget build(BuildContext context) {
    Widget item(Color fill, Color border, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: border),
              ),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(fontSize: 12, color: AppColors.subtext)),
          ],
        );

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        item(AppColors.surface, AppColors.fieldBorder, 'Available'),
        item(AppColors.crimson, AppColors.crimson, 'Selected'),
        item(const Color(0xFFE2E8F0), const Color(0xFFE2E8F0), 'Booked'),
        item(AppColors.crimson.withAlpha(18), AppColors.crimson.withAlpha(90),
            'Yours'),
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({
    required this.message,
    required this.onRetry,
    this.icon = Icons.cloud_off_rounded,
  });

  final String message;
  final VoidCallback onRetry;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return _WhiteCard(
      child: Column(
        children: [
          Icon(icon, color: AppColors.subtext, size: 32),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: AppColors.crimson),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Bottom bar
// =============================================================================

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.summary,
    required this.submitting,
    required this.onConfirm,
  });

  final String? summary;
  final bool submitting;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.fieldBorder)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                summary ?? 'Select a time slot to continue',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: summary == null ? FontWeight.w400 : FontWeight.w600,
                  color: summary == null
                      ? AppColors.subtext
                      : AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              PrimaryButton(
                label: 'Confirm Booking',
                loading: submitting,
                onPressed: onConfirm,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
