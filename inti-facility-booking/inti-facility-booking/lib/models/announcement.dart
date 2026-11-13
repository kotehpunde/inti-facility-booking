import '../utils/campus_time.dart';
import 'booking_rules.dart';

/// A campus announcement or promo published by an admin.
class Announcement {
  const Announcement({
    required this.id,
    required this.headline,
    required this.body,
    required this.isActive,
    required this.createdAt,
    this.facilityType,
  });

  final String id;
  final String? facilityType; // null = all facilities
  final String headline;
  final String body;
  final bool isActive;
  final DateTime createdAt; // campus time

  /// "All facilities", "Pool Table", …
  String get facilityLabel => facilityType == null
      ? 'All facilities'
      : FacilityRules.forType(facilityType!).displayName;

  factory Announcement.fromJson(Map<String, dynamic> json) => Announcement(
        id: json['id'] as String,
        facilityType: json['facility_type'] as String?,
        headline: json['headline'] as String,
        body: json['body'] as String,
        isActive: json['is_active'] as bool? ?? true,
        createdAt: CampusTime.fromServer(json['created_at'] as String),
      );
}
