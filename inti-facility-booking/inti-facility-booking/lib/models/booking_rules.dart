import 'facility.dart';

/// One bookable room or table, e.g. "Room 5" for 6 people.
class FacilityUnit {
  const FacilityUnit(this.name, {this.capacity});

  /// Must match `facility_units.unit_name` in Supabase.
  final String name;

  /// Max people, or null for open capacity.
  final int? capacity;

  String get label => capacity == null ? name : '$name · $capacity pax';
}

/// Booking rules for one facility. The booking screen reads everything it
/// needs from here, so one screen works for all three facilities.
///
/// The same rules are enforced again in Supabase (bookings.sql), so a
/// modified app still can't break them.
class FacilityRules {
  const FacilityRules({
    required this.type,
    required this.units,
    required this.maxSlotsPerBooking,
    required this.unitLabel,
    required this.displayName,
    this.dailyLimitHours,
  });

  /// Value stored in `bookings.facility_type`: 'music', 'pool' or 'library'.
  final String type;

  final List<FacilityUnit> units;

  /// How many 1-hour slots can be picked in one booking.
  final int maxSlotsPerBooking;

  /// Max hours per student per day, or null for no limit (pool tables).
  final int? dailyLimitHours;

  /// Heading above the unit chips, e.g. "Choose a table".
  final String unitLabel;

  /// Name on tickets and reminders, e.g. "Pool Table".
  final String displayName;

  bool get showUnitSelector => units.length > 1;

  // ---- Campus-wide rules ----
  static const openingHour = 8; // 8:00 AM
  static const closingHour = 18; // 6:00 PM
  static const maxDaysAhead = 14;

  /// Start hours of every slot: 8, 9, ... 17.
  static List<int> get slotStartHours =>
      [for (var h = openingHour; h < closingHour; h++) h];

  // ---- Per-facility rules ----
  static const music = FacilityRules(
    type: 'music',
    units: [FacilityUnit('Music Studio')],
    maxSlotsPerBooking: 2,
    dailyLimitHours: 2,
    unitLabel: 'Studio',
    displayName: 'Music Room',
  );

  static const pool = FacilityRules(
    type: 'pool',
    units: [
      FacilityUnit('Table 1', capacity: 4),
      FacilityUnit('Table 2', capacity: 4),
    ],
    maxSlotsPerBooking: 1,
    unitLabel: 'Choose a table',
    displayName: 'Pool Table',
  );

  static const library = FacilityRules(
    type: 'library',
    units: [
      FacilityUnit('Room 1', capacity: 4),
      FacilityUnit('Room 2', capacity: 4),
      FacilityUnit('Room 3', capacity: 4),
      FacilityUnit('Room 4', capacity: 4),
      FacilityUnit('Room 5', capacity: 6),
      FacilityUnit('Room 6', capacity: 6),
    ],
    maxSlotsPerBooking: 2,
    dailyLimitHours: 2,
    unitLabel: 'Choose a room',
    displayName: 'Library Discussion Room',
  );

  /// Rules for a `bookings.facility_type` value ('music', 'pool', 'library').
  static FacilityRules forType(String type) {
    switch (type) {
      case 'pool':
        return pool;
      case 'library':
        return library;
      case 'music':
      default:
        return music;
    }
  }

  /// Rules for a facility from the selection screen (matched by its id).
  static FacilityRules forFacility(Facility facility) {
    switch (facility.id) {
      case 'pool_table':
        return pool;
      case 'library_room':
        return library;
      case 'music_room':
      default:
        return music;
    }
  }
}
