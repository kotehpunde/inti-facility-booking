import 'package:flutter/material.dart';

import '../services/admin_service.dart';
import '../theme/app_theme.dart';
import '../widgets/admin_common.dart';

/// "Facility Maintenance Controls": open/close whole facilities and single
/// rooms or tables. Closed ones show as "Closed for maintenance" to
/// students, and the database refuses new bookings for them.
/// Existing bookings are kept; cancel them in Master Bookings if needed.
class AdminMaintenanceScreen extends StatefulWidget {
  const AdminMaintenanceScreen({super.key});

  @override
  State<AdminMaintenanceScreen> createState() => _AdminMaintenanceScreenState();
}

class _AdminMaintenanceScreenState extends State<AdminMaintenanceScreen> {
  final _service = AdminService();

  List<AdminFacility> _facilities = const [];
  bool _loading = true;
  String? _error;

  /// Switch currently saving, e.g. "facility:music_room" or "unit:pool:Table 1".
  String? _savingKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final facilities = await _service.facilities();
      if (!mounted) return;
      setState(() {
        _facilities = facilities;
        _loading = false;
        _error = null;
      });
    } on AdminFailure catch (e) {
      if (!mounted) return;
      if (e.needsLogin) {
        await handleAdminFailure(context, e);
        return;
      }
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// Closing something with upcoming bookings? Ask first.
  Future<bool> _confirmClose(String what, int upcoming) async {
    if (upcoming == 0) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Close $what?'),
        content: Text(
          'There ${upcoming == 1 ? 'is 1 upcoming booking' : 'are $upcoming upcoming bookings'} '
          'for this facility. They will stay booked; students just can\'t '
          'make new ones. To cancel them, use Master Bookings.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep open'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.crimson),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Close for maintenance'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _toggleFacility(AdminFacility f, bool open) async {
    if (!open && !await _confirmClose(f.name, f.upcomingBookings)) return;
    await _save(
      'facility:${f.id}',
      () => _service.setFacilityActive(f.id, open),
      open ? '${f.name} is open again.' : '${f.name} closed for maintenance.',
    );
  }

  Future<void> _toggleUnit(AdminFacility f, AdminUnit u, bool open) async {
    await _save(
      'unit:${f.facilityType}:${u.name}',
      () => _service.setUnitActive(f.facilityType, u.name, open),
      open ? '${u.name} is open again.' : '${u.name} closed for maintenance.',
    );
  }

  Future<void> _save(String key, Future<void> Function() call, String done) async {
    setState(() => _savingKey = key);
    try {
      await call();
      if (!mounted) return;
      showAdminSnack(context, done, success: true);
    } on AdminFailure catch (e) {
      if (!mounted) return;
      if (await handleAdminFailure(context, e)) return;
    }
    if (!mounted) return;
    await _load(); // show what the database now says
    if (mounted) setState(() => _savingKey = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: adminAppBar(context, 'Maintenance Controls'),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.crimson))
          : RefreshIndicator(
              color: AppColors.crimson,
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
                children: [
                  if (_error != null)
                    AdminMessage(
                      icon: Icons.cloud_off_rounded,
                      title: "Couldn't load facilities",
                      message: _error,
                      actionLabel: 'Try again',
                      onAction: () {
                        setState(() => _loading = true);
                        _load();
                      },
                    )
                  else ...[
                    const Padding(
                      padding: EdgeInsets.only(bottom: 14),
                      child: Text(
                        'Switch off a facility or a single room/table to stop '
                        'new bookings. Students see it as "Closed for maintenance".',
                        style: TextStyle(
                            fontSize: 13, color: AppColors.subtext, height: 1.4),
                      ),
                    ),
                    for (final f in _facilities)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _FacilityCard(
                          facility: f,
                          savingKey: _savingKey,
                          onFacilityChanged: (open) => _toggleFacility(f, open),
                          onUnitChanged: (u, open) => _toggleUnit(f, u, open),
                        ),
                      ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _FacilityCard extends StatelessWidget {
  const _FacilityCard({
    required this.facility,
    required this.savingKey,
    required this.onFacilityChanged,
    required this.onUnitChanged,
  });

  final AdminFacility facility;
  final String? savingKey;
  final ValueChanged<bool> onFacilityChanged;
  final void Function(AdminUnit unit, bool open) onUnitChanged;

  IconData get _icon => switch (facility.facilityType) {
        'pool' => Icons.table_restaurant_rounded,
        'library' => Icons.menu_book_rounded,
        _ => Icons.music_note_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final f = facility;
    final busy = savingKey != null;
    final savingThis = savingKey == 'facility:${f.id}';

    return AdminCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: f.isActive
                      ? AppColors.crimson.withAlpha(20)
                      : AdminBadge.greyBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  f.isActive ? _icon : Icons.construction_rounded,
                  color: f.isActive ? AppColors.crimson : AdminBadge.greyFg,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        f.isActive
                            ? const AdminBadge(
                                label: 'OPEN',
                                background: AdminBadge.greenBg,
                                foreground: AdminBadge.greenFg,
                              )
                            : const AdminBadge(
                                label: 'CLOSED FOR MAINTENANCE',
                                background: AdminBadge.amberBg,
                                foreground: AdminBadge.amberFg,
                              ),
                        Text(
                          '${f.upcomingBookings} upcoming',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.subtext),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              savingThis
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.crimson),
                      ),
                    )
                  : Switch(
                      value: f.isActive,
                      onChanged: busy ? null : onFacilityChanged,
                    ),
            ],
          ),
          // Units (only for facilities with more than one room/table).
          if (f.units.length > 1) ...[
            const Divider(height: 20),
            for (final u in f.units)
              _UnitRow(
                unit: u,
                facilityOpen: f.isActive,
                saving: savingKey == 'unit:${f.facilityType}:${u.name}',
                busy: busy,
                onChanged: (open) => onUnitChanged(u, open),
              ),
          ],
        ],
      ),
    );
  }
}

class _UnitRow extends StatelessWidget {
  const _UnitRow({
    required this.unit,
    required this.facilityOpen,
    required this.saving,
    required this.busy,
    required this.onChanged,
  });

  final AdminUnit unit;
  final bool facilityOpen;
  final bool saving;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 52),
        Expanded(
          child: Text(
            unit.label,
            style: TextStyle(
              fontSize: 14,
              color: unit.isActive && facilityOpen
                  ? AppColors.textPrimary
                  : AppColors.subtext,
              decoration: unit.isActive ? null : TextDecoration.lineThrough,
            ),
          ),
        ),
        saving
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.crimson),
                ),
              )
            : Switch(
                value: unit.isActive,
                onChanged: busy ? null : onChanged,
              ),
      ],
    );
  }
}
