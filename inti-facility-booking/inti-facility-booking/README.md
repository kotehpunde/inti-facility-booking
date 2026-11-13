# Campus Facility Booking System INTI Penang

Final Year Project (6001CEM) by Joel Vincent (15095581), BSc (Hons) Computer Science, INTI International College Penang. Supervisor: Ms. Asvhini Subramaniam.

A mobile app for booking the Music Room, Pool Tables and Library Discussion Rooms at INTI Penang. Students book 1-hour slots and get a reminder on their phone at 8:00 AM the day before. Administrators handle key handover, no-shows, maintenance, announcements and usage analytics.

## Built with

- Flutter (Dart) for the Android app
- Supabase (PostgreSQL) for the database
- flutter_local_notifications for booking reminders

## Folder structure

```
lib/
  main.dart, navigation.dart
  models/      data classes (user, facility, booking, announcement)
  screens/     student and admin screens
  services/    calls to the database functions (auth, booking, admin, notifications)
  utils/       campus time and input validation
  widgets/     shared UI parts
database/      SQL scripts, run in order 01 to 10
pubspec.yaml   Flutter dependencies
```

## How the main rules work

- Double bookings are blocked by a partial unique index on the bookings table.
- The 2-hour daily limit is checked by a trigger that uses an advisory lock.
- The tables are locked. The app can only call database functions that check the user's role first.
- Passwords are hashed with bcrypt. Session tokens are stored as SHA-256 hashes.

## Running it

1. Create a Supabase project.
2. Open the SQL Editor and run the scripts in `database/` in order, from `01_schema.sql` to `10_admin_enhancements.sql`.
3. Create a new Flutter project, then copy in the `lib/` folder and `pubspec.yaml` from this repository.
4. Copy `.env.example` to `.env` and fill in your Supabase URL and anon key.
5. Run `flutter pub get`, then `flutter run`.

`01_schema.sql` creates a default admin account (admin@newinti.edu.my). Change its password after setup.
