import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/announcement.dart';
import '../theme/app_theme.dart';

/// Active admin announcements on the student dashboard (newest first).
/// Shows nothing at all if there are none or they can't be loaded.
class AnnouncementsStrip extends StatefulWidget {
  const AnnouncementsStrip({super.key});

  @override
  State<AnnouncementsStrip> createState() => _AnnouncementsStripState();
}

class _AnnouncementsStripState extends State<AnnouncementsStrip> {
  List<Announcement> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Readable by the app: RLS only returns is_active = true rows.
      final rows = await Supabase.instance.client
          .from('announcements')
          .select()
          .eq('is_active', true)
          .order('created_at', ascending: false)
          .limit(3);
      if (!mounted) return;
      setState(() => _items = rows.map(Announcement.fromJson).toList());
    } catch (_) {
      // Announcements are a nice-to-have; stay hidden on error.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final a in _items) ...[
            _AnnouncementCard(announcement: a),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _AnnouncementCard extends StatelessWidget {
  const _AnnouncementCard({required this.announcement});

  final Announcement announcement;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.crimson.withAlpha(50)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppColors.crimson.withAlpha(20),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.campaign_rounded,
                color: AppColors.crimson, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  announcement.facilityLabel.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10.5,
                    letterSpacing: 0.7,
                    fontWeight: FontWeight.w700,
                    color: AppColors.crimson,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  announcement.headline,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  announcement.body,
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.subtext, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
