import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../navigation.dart';
import '../services/admin_service.dart';
import '../theme/app_theme.dart';
import '../utils/campus_time.dart';
import '../widgets/admin_common.dart';
import 'admin_announcements_screen.dart';
import 'admin_bookings_screen.dart';
import 'admin_maintenance_screen.dart';
import 'admin_reset_requests_screen.dart';
import 'admin_students_screen.dart';

/// Admin Console: KPIs, this week's bookings chart, 30-day utilization
/// analytics, and links to the management screens. Numbers refresh when returning from a sub-screen
/// and on pull-to-refresh.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key, required this.user});

  final AppUser user;

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final _service = AdminService();

  AdminStats? _stats;
  String? _error;

  AdminFacilityAnalytics? _analytics;
  String? _analyticsError;
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Analytics load alongside the KPIs; if they fail, only their card
    // shows an error.
    final analyticsDone = _loadAnalytics();
    try {
      final stats = await _service.stats();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _error = null;
      });
    } on AdminFailure catch (e) {
      if (!mounted) return;
      if (e.needsLogin) {
        await handleAdminFailure(context, e);
        return;
      }
      setState(() => _error = e.message);
    }
    await analyticsDone;
  }

  Future<void> _loadAnalytics() async {
    try {
      final analytics = await _service.analytics();
      if (!mounted) return;
      setState(() {
        _analytics = analytics;
        _analyticsError = null;
      });
    } on AdminFailure catch (e) {
      if (!mounted || e.needsLogin) return; // _load() handles the logout
      setState(() => _analyticsError = e.message);
    }
  }

  /// Opens a sub-screen, then refreshes the numbers when the admin returns.
  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (mounted) _load();
  }

  Future<void> _logout() async {
    setState(() => _loggingOut = true);
    await logOut(context);
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.crimson,
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              _Header(
                adminName: widget.user.name,
                loggingOut: _loggingOut,
                onLogout: _logout,
              ),
              const SizedBox(height: 20),
              if (_error != null && stats == null)
                AdminCard(
                  child: AdminMessage(
                    icon: Icons.cloud_off_rounded,
                    title: "Couldn't load the dashboard",
                    message: _error,
                    actionLabel: 'Try again',
                    onAction: _load,
                  ),
                )
              else ...[
                // ---- KPIs ----
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _KpiCard(
                          icon: Icons.event_available_rounded,
                          label: 'Bookings today',
                          value: stats?.bookingsToday,
                          badge: null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _KpiCard(
                          icon: Icons.key_rounded,
                          label: 'Pending reset tickets',
                          value: stats?.pendingResets,
                          badge: stats == null
                              ? null
                              : stats.pendingResets > 0
                                  ? const AdminBadge(
                                      label: 'NEEDS ACTION',
                                      icon: Icons.warning_amber_rounded,
                                      background: AdminBadge.amberBg,
                                      foreground: AdminBadge.amberFg,
                                    )
                                  : const AdminBadge(
                                      label: 'ALL CLEAR',
                                      icon: Icons.check_rounded,
                                      background: AdminBadge.greenBg,
                                      foreground: AdminBadge.greenFg,
                                    ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // ---- Weekly chart ----
                _WeeklyChartCard(stats: stats),
                const SizedBox(height: 16),
                // ---- Utilization analytics (last 30 days) ----
                _UtilizationCard(
                  analytics: _analytics,
                  error: _analyticsError,
                  onRetry: _loadAnalytics,
                ),
                const SizedBox(height: 24),
                // ---- Management ----
                const Text(
                  'Management',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                _NavCard(
                  icon: Icons.calendar_month_rounded,
                  title: 'Master Bookings Manager',
                  subtitle: 'All bookings with student details · force-cancel',
                  onTap: () => _open(const AdminBookingsScreen()),
                ),
                _NavCard(
                  icon: Icons.groups_rounded,
                  title: 'Student Directory & Governance',
                  subtitle: 'Search students · suspend or restore accounts',
                  onTap: () => _open(const AdminStudentsScreen()),
                ),
                _NavCard(
                  icon: Icons.key_rounded,
                  title: 'Password Reset Clearance',
                  subtitle: 'Approve or reject reset tickets',
                  count: stats?.pendingResets,
                  countIsWarning: true,
                  onTap: () => _open(const AdminResetRequestsScreen()),
                ),
                _NavCard(
                  icon: Icons.campaign_rounded,
                  title: 'Campus Facility Announcements',
                  subtitle: stats == null
                      ? 'Promos and alerts for students'
                      : '${stats.activeAnnouncements} active on the student dashboard',
                  onTap: () => _open(const AdminAnnouncementsScreen()),
                ),
                _NavCard(
                  icon: Icons.build_rounded,
                  title: 'Facility Maintenance Controls',
                  subtitle: stats == null
                      ? 'Open or close facilities and units'
                      : stats.closedFacilities == 0
                          ? 'Everything is open'
                          : '${stats.closedFacilities} closed for maintenance',
                  onTap: () => _open(const AdminMaintenanceScreen()),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Header
// =============================================================================

class _Header extends StatelessWidget {
  const _Header({
    required this.adminName,
    required this.loggingOut,
    required this.onLogout,
  });

  final String adminName;
  final bool loggingOut;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Admin Console',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppColors.crimson,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.school_rounded, size: 13, color: Colors.white),
                        SizedBox(width: 4),
                        Text(
                          'INTI CAMPUS',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    adminName,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.subtext),
                  ),
                ],
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Log out',
          onPressed: loggingOut ? null : onLogout,
          icon: loggingOut
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.logout_rounded, color: AppColors.textPrimary),
        ),
      ],
    );
  }
}

// =============================================================================
// KPI card
// =============================================================================

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.badge,
  });

  final IconData icon;
  final String label;
  final int? value; // null while loading
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.crimson.withAlpha(20),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: AppColors.crimson),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value?.toString() ?? '–',
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
              height: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 13, color: AppColors.subtext),
          ),
          if (badge != null) ...[
            const SizedBox(height: 8),
            badge!,
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// Weekly bookings chart (Mon → Sun)
// =============================================================================

class _WeeklyChartCard extends StatelessWidget {
  const _WeeklyChartCard({required this.stats});

  final AdminStats? stats;

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _barMaxHeight = 110.0;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final values = s?.weekly ?? List.filled(7, 0);
    final peak = values.fold<int>(0, (a, b) => math.max(a, b));
    final total = values.fold<int>(0, (a, b) => a + b);
    final todayIndex = s == null ? -1 : s.today.difference(s.weekStart).inDays;
    final weekLabel = s == null
        ? ''
        : '${CampusTime.shortDate(s.weekStart)} – '
            '${CampusTime.shortDate(s.weekStart.add(const Duration(days: 6)))}';

    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Bookings this week',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                s == null ? '' : '$total total',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.crimson,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(weekLabel,
              style: const TextStyle(fontSize: 12.5, color: AppColors.subtext)),
          const SizedBox(height: 16),
          SizedBox(
            height: _barMaxHeight + 22, // bars + value labels
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < 7; i++)
                  Expanded(
                    child: _Bar(
                      value: s == null ? null : values[i],
                      fraction: peak == 0 ? 0 : values[i] / peak,
                      isToday: i == todayIndex,
                      isFuture: todayIndex >= 0 && i > todayIndex,
                      maxHeight: _barMaxHeight,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Text(
                    _days[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight:
                          i == todayIndex ? FontWeight.w800 : FontWeight.w500,
                      color: i == todayIndex
                          ? AppColors.crimson
                          : AppColors.subtext,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.value,
    required this.fraction,
    required this.isToday,
    required this.isFuture,
    required this.maxHeight,
  });

  final int? value; // null while loading
  final double fraction;
  final bool isToday;
  final bool isFuture; // booked ahead: lighter colour
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final color = value == null
        ? AppColors.fieldBorder
        : isToday
            ? AppColors.crimson
            : isFuture
                ? AppColors.crimson.withAlpha(45)
                : AppColors.crimson.withAlpha(110);
    return Semantics(
      label: value == null ? 'Loading' : '$value bookings',
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            value?.toString() ?? '',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isToday ? AppColors.crimson : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
            height: math.max(4, fraction * maxHeight),
            margin: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Utilization analytics card (last 30 days)
// =============================================================================

class _UtilizationCard extends StatelessWidget {
  const _UtilizationCard({
    required this.analytics,
    required this.error,
    required this.onRetry,
  });

  final AdminFacilityAnalytics? analytics;
  final String? error;
  final VoidCallback onRetry;

  /// One colour per facility, used in the bar and the legend.
  static Color colorFor(String facilityType) => switch (facilityType) {
        'music' => AppColors.crimson,
        'pool' => const Color(0xFF2563EB),
        _ => const Color(0xFF16A34A),
      };

  @override
  Widget build(BuildContext context) {
    final a = analytics;
    return AdminCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Facility utilization',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              Text(
                a == null ? '' : '${a.totalHours} hours booked',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.crimson,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text('Share of booked hours · last 30 days',
              style: TextStyle(fontSize: 12.5, color: AppColors.subtext)),
          const SizedBox(height: 16),
          if (a == null && error != null)
            Row(
              children: [
                const Icon(Icons.cloud_off_rounded,
                    size: 18, color: AppColors.subtext),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(error!,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.subtext)),
                ),
                TextButton(
                  onPressed: onRetry,
                  style:
                      TextButton.styleFrom(foregroundColor: AppColors.crimson),
                  child: const Text('Retry'),
                ),
              ],
            )
          else ...[
            _StackedShareBar(analytics: a),
            const SizedBox(height: 12),
            // Legend with percentages
            Wrap(
              spacing: 14,
              runSpacing: 6,
              children: [
                for (final share in a?.shares ?? const <FacilityShare>[])
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: colorFor(share.facilityType),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${share.displayName} ',
                        style: const TextStyle(
                            fontSize: 12.5, color: AppColors.textSecondary),
                      ),
                      Text(
                        '${_pct(share.percent)}%',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            // Stat chips
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _StatChip(
                      icon: Icons.emoji_events_outlined,
                      label: 'Top Unit',
                      value: a?.topUnitLabel ?? '–',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _StatChip(
                      icon: Icons.schedule_rounded,
                      label: 'Peak Window',
                      value: a?.peakWindowLabel ?? '–',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _StatChip(
                      icon: Icons.timer_off_outlined,
                      label: '30-Day No-Shows',
                      value: a?.noShowCount.toString() ?? '–',
                      warn: (a?.noShowCount ?? 0) > 0,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 33.3 → "33.3", 50.0 → "50"
  static String _pct(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
}

/// One horizontal bar split into the three facilities' shares.
class _StackedShareBar extends StatelessWidget {
  const _StackedShareBar({required this.analytics});

  final AdminFacilityAnalytics? analytics;

  @override
  Widget build(BuildContext context) {
    final a = analytics;
    final segments = [
      for (final s in a?.shares ?? const <FacilityShare>[])
        if (s.hours > 0) s,
    ];
    return Semantics(
      label: a == null
          ? 'Loading utilization'
          : [
              for (final s in a.shares) '${s.displayName} ${s.percent}%',
            ].join(', '),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          height: 16,
          child: a == null || !a.hasData
              ? Container(
                  color: AppColors.fieldBorder.withAlpha(120),
                  alignment: Alignment.center,
                  child: a == null
                      ? null
                      : const Text(
                          'No bookings in the last 30 days',
                          style: TextStyle(
                              fontSize: 10.5, color: AppColors.subtext),
                        ),
                )
              : Row(
                  children: [
                    for (var i = 0; i < segments.length; i++)
                      Expanded(
                        // hours as flex keeps the proportions exact
                        flex: segments[i].hours,
                        child: Container(
                          margin: EdgeInsets.only(
                              right: i == segments.length - 1 ? 0 : 2),
                          color: _UtilizationCard.colorFor(
                              segments[i].facilityType),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.icon,
    required this.label,
    required this.value,
    this.warn = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final fg = warn ? AdminBadge.amberFg : AppColors.crimson;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: warn ? AdminBadge.amberBg : AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: warn ? AdminBadge.amberBg : AppColors.fieldBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: AppColors.subtext),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Navigation card
// =============================================================================

class _NavCard extends StatelessWidget {
  const _NavCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.count,
    this.countIsWarning = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final int? count;
  final bool countIsWarning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AdminCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.crimson.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppColors.crimson),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style:
                        const TextStyle(fontSize: 12.5, color: AppColors.subtext),
                  ),
                ],
              ),
            ),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: countIsWarning
                      ? AdminBadge.amberBg
                      : AppColors.crimson.withAlpha(20),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: countIsWarning
                        ? AdminBadge.amberFg
                        : AppColors.crimson,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, color: AppColors.subtext),
          ],
        ),
      ),
    );
  }
}
