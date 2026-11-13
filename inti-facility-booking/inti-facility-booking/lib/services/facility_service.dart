import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/facility.dart';

/// Result of loading facilities: the list, and whether it came from Supabase
/// (true) or the built-in fallback copy (false).
class FacilityLoadResult {
  const FacilityLoadResult(this.facilities, {required this.fromServer});

  final List<Facility> facilities;
  final bool fromServer;
}

/// Reads the `facilities` table (see facilities.sql).
class FacilityService {
  FacilityService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// All facilities in display order (closed ones have isOpen = false). Never throws: on any error
  /// (offline, table missing) it returns [Facility.fallback].
  Future<FacilityLoadResult> fetchFacilities() async {
    try {
      final rows = await _client
          .from('facilities')
          .select()
          .order('sort_order'); // closed ones included, shown as closed
      final facilities = rows.map(Facility.fromJson).toList();
      if (facilities.isEmpty) {
        return const FacilityLoadResult(Facility.fallback, fromServer: false);
      }
      return FacilityLoadResult(facilities, fromServer: true);
    } catch (_) {
      return const FacilityLoadResult(Facility.fallback, fromServer: false);
    }
  }
}
