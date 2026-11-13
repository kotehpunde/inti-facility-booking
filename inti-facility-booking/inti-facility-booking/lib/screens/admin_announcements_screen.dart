import 'package:flutter/material.dart';

import '../models/announcement.dart';
import '../services/admin_service.dart';
import '../theme/app_theme.dart';
import '../utils/campus_time.dart';
import '../widgets/admin_common.dart';
import '../widgets/primary_button.dart';

/// "Campus Facility Announcements": publish promos/alerts that appear at
/// the top of every student's dashboard, then switch them off or delete
/// them later.
class AdminAnnouncementsScreen extends StatefulWidget {
  const AdminAnnouncementsScreen({super.key});

  @override
  State<AdminAnnouncementsScreen> createState() =>
      _AdminAnnouncementsScreenState();
}

class _AdminAnnouncementsScreenState extends State<AdminAnnouncementsScreen> {
  /// Dropdown options: label → facility_type (null = all).
  static const _facilityOptions = <(String, String?)>[
    ('All Facilities', null),
    ('Music Room', 'music'),
    ('Pool Tables', 'pool'),
    ('Library Rooms', 'library'),
  ];

  final _service = AdminService();
  final _formKey = GlobalKey<FormState>();
  final _headlineController = TextEditingController();
  final _bodyController = TextEditingController();

  String? _facilityType; // null = All Facilities
  int _formVersion = 0; // bump to reset the dropdown after publishing
  bool _publishing = false;

  List<Announcement> _items = const [];
  bool _loading = true;
  String? _error;
  String? _busyId; // announcement being toggled/deleted

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _headlineController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await _service.announcements();
      if (!mounted) return;
      setState(() {
        _items = items;
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

  Future<void> _publish() async {
    if (_publishing || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _publishing = true);
    try {
      await _service.createAnnouncement(
        facilityType: _facilityType,
        headline: _headlineController.text.trim(),
        body: _bodyController.text.trim(),
      );
      if (!mounted) return;
      _headlineController.clear();
      _bodyController.clear();
      setState(() {
        _facilityType = null;
        _formVersion++;
        _publishing = false;
      });
      showAdminSnack(context, 'Announcement published to students.',
          success: true);
      await _load();
    } on AdminFailure catch (e) {
      if (!mounted) return;
      setState(() => _publishing = false);
      await handleAdminFailure(context, e);
    }
  }

  Future<void> _setActive(Announcement a, bool active) async {
    setState(() => _busyId = a.id);
    try {
      await _service.setAnnouncementActive(a.id, active);
      if (!mounted) return;
      showAdminSnack(context,
          active ? 'Shown to students again.' : 'Hidden from students.');
    } on AdminFailure catch (e) {
      if (!mounted) return;
      if (await handleAdminFailure(context, e)) return;
    }
    await _load();
    if (mounted) setState(() => _busyId = null);
  }

  Future<void> _delete(Announcement a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete announcement?'),
        content: Text('"${a.headline}" will be removed permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.crimson),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busyId = a.id);
    try {
      await _service.deleteAnnouncement(a.id);
      if (!mounted) return;
      showAdminSnack(context, 'Announcement deleted.');
    } on AdminFailure catch (e) {
      if (!mounted) return;
      if (await handleAdminFailure(context, e)) return;
    }
    await _load();
    if (mounted) setState(() => _busyId = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: adminAppBar(context, 'Announcements'),
      body: RefreshIndicator(
        color: AppColors.crimson,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            _buildForm(),
            const SizedBox(height: 24),
            Text(
              'Published (${_items.length})',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                    child: CircularProgressIndicator(color: AppColors.crimson)),
              )
            else if (_error != null)
              AdminMessage(
                icon: Icons.cloud_off_rounded,
                title: "Couldn't load announcements",
                message: _error,
                actionLabel: 'Try again',
                onAction: _load,
              )
            else if (_items.isEmpty)
              const AdminMessage(
                icon: Icons.campaign_outlined,
                title: 'No announcements yet',
                message: 'Publish one above and it appears at the top of '
                    'the student dashboard.',
              )
            else
              for (final a in _items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _AnnouncementTile(
                    announcement: a,
                    busy: _busyId == a.id,
                    enabled: _busyId == null,
                    onActiveChanged: (v) => _setActive(a, v),
                    onDelete: () => _delete(a),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    const fieldText = TextStyle(color: AppColors.textPrimary, fontSize: 15);
    return AdminCard(
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.campaign_rounded, color: AppColors.crimson),
                SizedBox(width: 8),
                Text(
                  'New announcement',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String?>(
              key: ValueKey(_formVersion),
              initialValue: _facilityType,
              isExpanded: true,
              decoration: AppTheme.field(
                label: 'Facility',
                icon: Icons.place_outlined,
              ),
              items: [
                for (final (label, type) in _facilityOptions)
                  DropdownMenuItem<String?>(value: type, child: Text(label)),
              ],
              onChanged:
                  _publishing ? null : (v) => setState(() => _facilityType = v),
            ),
            const SizedBox(height: 4),
            TextFormField(
              controller: _headlineController,
              enabled: !_publishing,
              maxLength: 80,
              textCapitalization: TextCapitalization.sentences,
              style: fieldText,
              decoration: AppTheme.field(
                label: 'Headline',
                icon: Icons.title_rounded,
                helperText: 'e.g. Free Slots This Afternoon!',
              ),
              validator: (v) => (v ?? '').trim().length < 3
                  ? 'Headline needs at least 3 characters.'
                  : null,
            ),
            const SizedBox(height: 4),
            TextFormField(
              controller: _bodyController,
              enabled: !_publishing,
              maxLength: 300,
              minLines: 2,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              style: fieldText,
              decoration: AppTheme.field(
                label: 'Description',
                icon: Icons.notes_rounded,
                helperText: 'e.g. Pool tables are open. Reserve a match now!',
              ),
              validator: (v) => (v ?? '').trim().length < 3
                  ? 'Description needs at least 3 characters.'
                  : null,
            ),
            const SizedBox(height: 8),
            PrimaryButton(
              label: 'Publish Announcement',
              loading: _publishing,
              onPressed: _publish,
            ),
          ],
        ),
      ),
    );
  }
}

class _AnnouncementTile extends StatelessWidget {
  const _AnnouncementTile({
    required this.announcement,
    required this.busy,
    required this.enabled,
    required this.onActiveChanged,
    required this.onDelete,
  });

  final Announcement announcement;
  final bool busy;
  final bool enabled;
  final ValueChanged<bool> onActiveChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final a = announcement;
    return AdminCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
      child: Opacity(
        opacity: a.isActive ? 1 : 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AdminBadge(
                  label: a.facilityLabel.toUpperCase(),
                  background: AppColors.crimson.withAlpha(18),
                  foreground: AppColors.crimson,
                ),
                const SizedBox(width: 6),
                a.isActive
                    ? const AdminBadge(
                        label: 'LIVE',
                        background: AdminBadge.greenBg,
                        foreground: AdminBadge.greenFg,
                      )
                    : const AdminBadge(
                        label: 'HIDDEN',
                        background: AdminBadge.greyBg,
                        foreground: AdminBadge.greyFg,
                      ),
                const Spacer(),
                busy
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
                        value: a.isActive,
                        onChanged: enabled ? onActiveChanged : null,
                      ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.headline,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    a.body,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.subtext, height: 1.35),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                Text(
                  'Posted ${CampusTime.dayAndClock(a.createdAt)}',
                  style: const TextStyle(fontSize: 12, color: AppColors.subtext),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: enabled ? onDelete : null,
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.textSecondary),
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
