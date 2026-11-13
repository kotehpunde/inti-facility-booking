import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_user.dart';
import '../models/facility.dart';
import '../navigation.dart';
import '../services/auth_service.dart';
import '../services/session_manager.dart';
import '../theme/app_theme.dart';
import '../widgets/announcements_strip.dart';
import 'facility_selection_screen.dart';
import 'master_schedule_screen.dart';
import 'my_bookings_screen.dart';
import 'student_profile_bottom_sheet.dart';

/// Student home screen.
///
/// Layout (top to bottom):
///   1. App bar: initial avatar (opens profile sheet), greeting, logout button
///   2. "Featured facilities" auto-rotating carousel with page dots
///   3. "Book a Facility" hero card
///   4. "My Bookings" + "Master Schedule" cards side by side
///
/// The student's details come from the login session saved on the phone,
/// then are refreshed from Supabase (rpc/me) when the screen opens.
class StudentDashboardScreen extends StatefulWidget {
  const StudentDashboardScreen({super.key, required this.user});

  /// The user returned by rpc/login (or loaded from the saved session).
  final AppUser user;

  @override
  State<StudentDashboardScreen> createState() => _StudentDashboardScreenState();
}

class _StudentDashboardScreenState extends State<StudentDashboardScreen> {
  late AppUser _user = widget.user;
  bool _loggingOut = false;

  @override
  void initState() {
    super.initState();
    _refreshProfile();
  }

  /// Greeting name: the nickname if set, otherwise the first name.
  String get _firstName => _user.greetingName;

  /// Avatar letter of the greeting name.
  String get _initial => _user.initial;

  // ---------------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------------

  /// Re-reads the profile from Supabase so the screen shows current data,
  /// and signs the student out if their session was revoked or expired.
  /// If the phone is offline, the saved profile keeps being shown.
  Future<void> _refreshProfile() async {
    final token = await SessionManager.token();
    if (!mounted) return;
    if (token == null) {
      goToLogin(context);
      return;
    }
    try {
      final fresh = await AuthService().me(token);
      await SessionManager.save(Session(token: token, user: fresh));
      if (mounted) setState(() => _user = fresh);
    } on AuthFailure catch (e) {
      if (e.code == AuthFailure.sessionExpired && mounted) {
        await logOut(context,
            message: 'Your session has expired. Please log in again.');
      }
      // Any other error (e.g. no internet): keep the saved profile.
    }
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _logout() async {
    if (_loggingOut) return;
    setState(() => _loggingOut = true);
    await logOut(context);
  }

  void _open(Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  void _showProfile() {
    showStudentProfileSheet(
      context,
      user: _user,
      onUpdated: (updated) {
        if (mounted) setState(() => _user = updated);
      },
    );
  }


  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 76,
        leadingWidth: 72,
        titleSpacing: 4,
        leading: Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Center(
            child: _InitialAvatar(
              initial: _initial,
              radius: 24,
              onTap: _showProfile,
            ),
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Welcome back, $_firstName 👋',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              'What would you like to book today?',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.5, color: AppColors.subtext),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Log out',
            onPressed: _loggingOut ? null : _logout,
            icon: _loggingOut
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.logout_rounded, color: AppColors.textPrimary),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            const AnnouncementsStrip(), // admin promos/alerts, if any
            const _SectionLabel('Featured facilities'),
            const SizedBox(height: 12),
            const _FeaturedCarousel(facilities: featuredFacilities),
            const SizedBox(height: 28),
            const _SectionLabel('Quick actions'),
            const SizedBox(height: 12),
            _BookFacilityHeroCard(
              onTap: () => _open(const FacilitySelectionScreen()),
            ),
            const SizedBox(height: 12),
            // Two equal cards; IntrinsicHeight keeps them the same height
            // even if one subtitle wraps to two lines.
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _ActionCard(
                      icon: Icons.bookmark_border_rounded,
                      title: 'My Bookings',
                      subtitle: 'Your reservations',
                      onTap: () => _open(const MyBookingsScreen()),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _ActionCard(
                      icon: Icons.schedule_rounded,
                      title: 'Master Schedule',
                      subtitle: 'Live slot availability',
                      onTap: () => _open(const MasterScheduleScreen()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Header widgets
// =============================================================================

/// Crimson circle with the student's initial. Tappable.
class _InitialAvatar extends StatelessWidget {
  const _InitialAvatar({required this.initial, this.radius = 22, this.onTap});

  final String initial;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final avatar = Material(
      color: AppColors.crimson,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox.square(
          dimension: radius * 2,
          child: Center(
            child: Text(
              initial,
              style: TextStyle(
                color: Colors.white,
                fontSize: radius * 0.85,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
    return onTap == null ? avatar : Tooltip(message: 'View profile', child: avatar);
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

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

// =============================================================================
// Featured facilities carousel
// =============================================================================

/// Auto-rotating carousel: moves to the next slide every 4 seconds,
/// wraps back to the first, and restarts the countdown after a manual swipe.
class _FeaturedCarousel extends StatefulWidget {
  const _FeaturedCarousel({required this.facilities});

  final List<Facility> facilities;

  @override
  State<_FeaturedCarousel> createState() => _FeaturedCarouselState();
}

class _FeaturedCarouselState extends State<_FeaturedCarousel> {
  static const _interval = Duration(seconds: 4);
  static const _slideDuration = Duration(milliseconds: 450);

  final _controller = PageController();
  Timer? _timer;
  int _current = 0;

  @override
  void initState() {
    super.initState();
    _startAutoPlay();
  }

  @override
  void dispose() {
    _timer?.cancel(); // stop the timer so it can't fire after the screen closes
    _controller.dispose();
    super.dispose();
  }

  void _startAutoPlay() {
    _timer?.cancel();
    if (widget.facilities.length < 2) return;
    _timer = Timer.periodic(_interval, (_) {
      if (!_controller.hasClients) return;
      final next = (_current + 1) % widget.facilities.length;
      _controller.animateToPage(
        next,
        duration: _slideDuration,
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.facilities.length;
    return Column(
      children: [
        SizedBox(
          height: 180,
          child: PageView.builder(
            controller: _controller,
            itemCount: count,
            onPageChanged: (index) {
              setState(() => _current = index);
              _startAutoPlay(); // full 4 s on every slide, including after a swipe
            },
            itemBuilder: (_, index) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _FacilitySlide(facility: widget.facilities[index]),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Page indicator dots
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(count, (i) {
            final active = i == _current;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: active ? 22 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: active ? AppColors.crimson : AppColors.fieldBorder,
                borderRadius: BorderRadius.circular(4),
              ),
            );
          }),
        ),
      ],
    );
  }
}

/// One carousel card: photo (or coloured placeholder) with title and caption.
class _FacilitySlide extends StatelessWidget {
  const _FacilitySlide({required this.facility});

  final Facility facility;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _background(),
          // Dark fade at the bottom so the white text is always readable.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.35, 1.0],
                colors: [Colors.transparent, Color(0xB3000000)],
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  facility.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  facility.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _background() {
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: facility.gradient,
        ),
      ),
      child: Align(
        alignment: const Alignment(0.85, -0.6),
        child: Icon(facility.icon, size: 84, color: Colors.white.withAlpha(70)),
      ),
    );
    final asset = facility.imageAsset;
    if (asset == null) return placeholder;
    return Image.asset(
      asset,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => placeholder, // missing file → placeholder
    );
  }
}

// =============================================================================
// Action cards
// =============================================================================

/// Full-width crimson card: the main call to action.
class _BookFacilityHeroCard extends StatelessWidget {
  const _BookFacilityHeroCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.crimson,
      elevation: 2,
      shadowColor: AppColors.crimson.withAlpha(90),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withAlpha(40),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.calendar_month_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Book a Facility',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Reserve a room or space on campus',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_rounded, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

/// White card used in the two-column row.
class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 1,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.crimson.withAlpha(20),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: AppColors.crimson),
              ),
              const SizedBox(height: 14),
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
                style: const TextStyle(fontSize: 12.5, color: AppColors.subtext),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
