import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'navigation.dart';
import 'screens/login_screen.dart';
import 'services/session_manager.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Keys live in .env (git-ignored), never in the source code.
  await dotenv.load(fileName: '.env');
  final url = dotenv.env['SUPABASE_URL'] ?? '';
  final anonKey = dotenv.env['SUPABASE_ANON_KEY'] ?? '';
  if (url.isEmpty || anonKey.isEmpty) {
    throw StateError('SUPABASE_URL or SUPABASE_ANON_KEY is missing from .env');
  }

  // Works with both the old "anon" key and the new "publishable" key.
  await Supabase.initialize(url: url, publishableKey: anonKey);

  // If the user logged in before, open their dashboard directly.
  final session = await SessionManager.load();
  runApp(IntiBookingApp(session: session));
}

class IntiBookingApp extends StatelessWidget {
  const IntiBookingApp({super.key, this.session});

  final Session? session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'INTI Facility Booking',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      home: session == null ? const LoginScreen() : homeFor(session!.user),
    );
  }
}
