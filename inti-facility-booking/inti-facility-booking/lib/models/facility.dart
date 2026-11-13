import 'package:flutter/material.dart';

/// Colour of the status badge on a facility card.
enum StatusTone {
  success, // green, e.g. "Open for Booking"
  info, // blue, e.g. "2 Tables On-Site"
  quiet; // purple, e.g. "Quiet Study Zone"

  static StatusTone fromString(String? value) => StatusTone.values.firstWhere(
        (t) => t.name == value,
        orElse: () => StatusTone.success,
      );
}

/// A bookable campus facility.
///
/// Loaded from the Supabase `facilities` table with [Facility.fromJson].
/// If Supabase can't be reached, the app uses [Facility.fallback] instead.
class Facility {
  const Facility({
    required this.id,
    required this.name,
    required this.caption,
    required this.tags,
    required this.statusLabel,
    required this.statusTone,
    required this.icon,
    required this.gradient,
    this.imageUrl,
    this.imageAsset,
    this.isOpen = true,
  });

  /// Stable identifier passed between screens: 'music_room', 'pool_table', 'library_room'.
  final String id;
  final String name;

  /// Short line used on the dashboard carousel.
  final String caption;

  /// Metadata shown as small tags, e.g. ['Level 1', 'Open Capacity'].
  final List<String> tags;

  final String statusLabel;
  final StatusTone statusTone;

  /// Placeholder artwork used when there is no photo (or it fails to load).
  final IconData icon;
  final List<Color> gradient;

  /// Optional banner photo from the internet (e.g. Supabase Storage).
  final String? imageUrl;

  /// Optional banner photo bundled in the app, e.g. 'assets/images/music_room.jpg'.
  final String? imageAsset;

  /// False while an admin has it closed for maintenance.
  final bool isOpen;

  /// Tags joined into one line: "Level 1 • Open Capacity • Acoustic Studio".
  String get metadata => tags.join(' • ');

  /// Builds a facility from a row of the Supabase `facilities` table.
  factory Facility.fromJson(Map<String, dynamic> json) {
    final style = _styleFor(json['icon_key'] as String?);
    return Facility(
      id: json['id'] as String,
      name: json['name'] as String,
      caption: (json['caption'] as String?) ?? '',
      tags: (json['tags'] as List<dynamic>? ?? const [])
          .map((tag) => tag.toString())
          .toList(),
      statusLabel: (json['status_label'] as String?) ?? 'Open for Booking',
      statusTone: StatusTone.fromString(json['status_tone'] as String?),
      icon: style.icon,
      gradient: style.gradient,
      imageUrl: json['image_url'] as String?,
      isOpen: json['is_active'] as bool? ?? true,
    );
  }

  /// Icon and colours for each `icon_key` stored in the database.
  static ({IconData icon, List<Color> gradient}) _styleFor(String? key) {
    switch (key) {
      case 'music':
        return (
          icon: Icons.music_note_rounded,
          gradient: const [Color(0xFFC41230), Color(0xFF7A0B1E)],
        );
      case 'pool':
        return (
          icon: Icons.table_restaurant_rounded,
          gradient: const [Color(0xFF166534), Color(0xFF0B3B20)],
        );
      case 'library':
        return (
          icon: Icons.menu_book_rounded,
          gradient: const [Color(0xFF1E3A5F), Color(0xFF0F172A)],
        );
      default:
        return (
          icon: Icons.meeting_room_rounded,
          gradient: const [Color(0xFF475569), Color(0xFF1E293B)],
        );
    }
  }

  /// Built-in copy of the three facilities, used offline or before
  /// facilities.sql has been run.
  static const fallback = <Facility>[
    Facility(
      id: 'music_room',
      name: 'Music Room',
      caption: 'Music Room: Acoustic studio open to all students',
      tags: ['Level 1', 'Open Capacity', 'Acoustic Studio'],
      statusLabel: 'Open for Booking',
      statusTone: StatusTone.success,
      icon: Icons.music_note_rounded,
      gradient: [Color(0xFFC41230), Color(0xFF7A0B1E)],
    ),
    Facility(
      id: 'pool_table',
      name: 'Pool Tables',
      caption: 'Recreation Corner: Unwind with a game between classes',
      tags: ['Level 2', '2 Tables Available', 'Max 4 Pax/Table'],
      statusLabel: '2 Tables On-Site',
      statusTone: StatusTone.info,
      icon: Icons.table_restaurant_rounded,
      gradient: [Color(0xFF166534), Color(0xFF0B3B20)],
    ),
    Facility(
      id: 'library_room',
      name: 'Library Discussion Rooms',
      caption: 'Discussion Rooms: Quiet study spaces available',
      tags: ['Level 6', '6 Study Rooms', 'Rooms 1–4: 4 Pax', 'Rooms 5–6: 6 Pax'],
      statusLabel: 'Quiet Study Zone',
      statusTone: StatusTone.quiet,
      icon: Icons.menu_book_rounded,
      gradient: [Color(0xFF1E3A5F), Color(0xFF0F172A)],
    ),
  ];
}

/// Facilities shown in the dashboard carousel.
const featuredFacilities = Facility.fallback;
