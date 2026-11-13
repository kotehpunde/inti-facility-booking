import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/admin_common.dart';
import '../widgets/admin_reset_requests_widget.dart';

/// "Password Reset Clearance": full screen around the approval panel.
class AdminResetRequestsScreen extends StatelessWidget {
  const AdminResetRequestsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: adminAppBar(context, 'Password Reset Clearance'),
      body: const SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 32),
          child: AdminResetRequestsPanel(),
        ),
      ),
    );
  }
}
