import 'package:flutter/material.dart';

import '../models/facility.dart';
import '../services/facility_service.dart';
import '../theme/app_theme.dart';
import 'facility_booking_screen.dart';

/// "Select a Facility" — opened from the dashboard's "Book a Facility" card.
///
/// Loads facilities from Supabase (falls back to the built-in list when
/// offline) and shows one card per facility. Tapping a card opens
/// [FacilityBookingScreen] for that facility.
class FacilitySelectionScreen extends StatefulWidget {
  const FacilitySelectionScreen({super.key});

  @override
  State<FacilitySelectionScreen> createState() =>
      _FacilitySelectionScreenState();
}

class _FacilitySelectionScreenState extends State<FacilitySelectionScreen> {
  final _service = FacilityService();

  List<Facility> _facilities = const [];
  bool _loading = true;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Also used by pull-to-refresh.
  Future<void> _load() async {
    final result = await _service.fetchFacilities();
    if (!mounted) return;
    setState(() {
      _facilities = result.facilities;
      _offline = !result.fromServer;
      _loading = false;
    });
  }

  void _openFacility(Facility facility) {
    if (!facility.isOpen) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('${facility.name} is closed for maintenance. '
              'Please check back later.'),
        ));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FacilityBookingScreen(facility: facility)),
    );
  }

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
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text(
          'Select a Facility',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.crimson),
            )
          : RefreshIndicator(
              color: AppColors.crimson,
              onRefresh: _load,
              child: ListView(
                // Always scrollable so pull-to-refresh works with 3 cards.
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                children: [
                  if (_offline) const _OfflineNotice(),
                  for (final facility in _facilities) ...[
                    _FacilityCard(
                      facility: facility,
                      onTap: () => _openFacility(facility),
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
    );
  }
}

// =============================================================================
// Facility card
// =============================================================================

/// White card: banner image on top, name + tags + arrow underneath.
class _FacilityCard extends StatelessWidget {
  const _FacilityCard({required this.facility, required this.onTap});

  static const _radius = 16.0;

  final Facility facility;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final closed = !facility.isOpen;
    return Material(
      color: AppColors.surface,
      elevation: closed ? 0.5 : 1.5,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(_radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: closed ? 0.6 : 1,
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Banner with rounded top corners and the status badge on top.
            ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(_radius)),
              child: SizedBox(
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _FacilityBanner(facility: facility),
                    Positioned(
                      top: 12,
                      left: 12,
                      child: _StatusChip(
                        label: closed
                            ? 'Closed for maintenance'
                            : facility.statusLabel,
                        tone: facility.statusTone,
                        closed: closed,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          facility.name,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Semantics(
                          label: facility.metadata,
                          excludeSemantics: true,
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final tag in facility.tags) _MetaTag(tag),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: closed
                        ? '${facility.name} is closed'
                        : 'Book ${facility.name}',
                    onPressed: onTap,
                    style: IconButton.styleFrom(
                      backgroundColor: closed
                          ? AppColors.background
                          : AppColors.crimson.withAlpha(22),
                      foregroundColor:
                          closed ? AppColors.subtext : AppColors.crimson,
                    ),
                    icon: Icon(closed
                        ? Icons.construction_rounded
                        : Icons.arrow_forward_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// Banner artwork: bundled photo → internet photo → coloured placeholder.
/// Any photo that fails to load falls back to the placeholder.
class _FacilityBanner extends StatelessWidget {
  const _FacilityBanner({required this.facility});

  final Facility facility;

  @override
  Widget build(BuildContext context) {
    final placeholder = _Placeholder(facility: facility);

    final asset = facility.imageAsset;
    if (asset != null) {
      return Image.asset(
        asset,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => placeholder,
      );
    }

    final url = facility.imageUrl;
    if (url != null && url.isNotEmpty) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        // Show the placeholder while the photo downloads, then fade it in.
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : placeholder,
        errorBuilder: (_, __, ___) => placeholder,
      );
    }

    return placeholder;
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.facility});

  final Facility facility;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: facility.gradient,
        ),
      ),
      child: Align(
        alignment: const Alignment(0.8, 0.3),
        child: Icon(facility.icon, size: 88, color: Colors.white.withAlpha(70)),
      ),
    );
  }
}

/// Coloured badge, e.g. green "Open for Booking".
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.tone,
    this.closed = false,
  });

  final String label;
  final StatusTone tone;
  final bool closed;

  ({Color background, Color foreground}) get _colors {
    if (closed) {
      return (
        background: const Color(0xFFF1F5F9),
        foreground: const Color(0xFF475569),
      );
    }
    switch (tone) {
      case StatusTone.success:
        return (
          background: const Color(0xFFDCFCE7),
          foreground: const Color(0xFF15803D),
        );
      case StatusTone.info:
        return (
          background: const Color(0xFFDBEAFE),
          foreground: const Color(0xFF1D4ED8),
        );
      case StatusTone.quiet:
        return (
          background: const Color(0xFFEDE9FE),
          foreground: const Color(0xFF6D28D9),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: colors.foreground,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: colors.foreground,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Small grey tag for metadata like "Level 1" or "Max 4 Pax/Table".
class _MetaTag extends StatelessWidget {
  const _MetaTag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final isLevel = text.toLowerCase().startsWith('level');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.fieldBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isLevel) ...[
            const Icon(Icons.place_outlined, size: 13, color: AppColors.subtext),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when Supabase couldn't be reached and the built-in list is used.
class _OfflineNotice extends StatelessWidget {
  const _OfflineNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        children: [
          Icon(Icons.wifi_off_rounded, size: 18, color: Color(0xFF92400E)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              "Couldn't reach the server, so this is saved facility info. "
              'Pull down to try again.',
              style: TextStyle(fontSize: 13, color: Color(0xFF92400E)),
            ),
          ),
        ],
      ),
    );
  }
}
