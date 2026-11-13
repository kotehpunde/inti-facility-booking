import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/my_booking.dart';
import '../utils/campus_time.dart';

/// What happened when a reminder was requested for a booking.
enum ReminderOutcome {
  /// Reminder set for 8:00 AM the day before.
  scheduled,

  /// Too late for the day-before reminder (booking is today, or tomorrow
  /// after 8 AM), so a confirmation notification was shown right away.
  shownNow,

  /// Nothing to remind about (booking already started) or it failed.
  none,
}

/// Local booking reminders (flutter_local_notifications).
///
/// Every booking gets one notification ID derived from its booking_ref, so
/// the same booking always maps to the same ID: scheduling again replaces
/// the old reminder, and cancelling the booking cancels its reminder.
///
/// Times use campus time (Asia/Kuala_Lumpur) so a reminder fires at 8:00 AM
/// Malaysia time even if the phone is set to another time zone.
class NotificationService {
  NotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const _reminderHour = 8; // 8:00 AM the day before

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'booking_reminders',
      'Booking reminders',
      channelDescription: 'Reminders the day before your facility bookings',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
  );

  /// Safe to call many times; only the first call does the work.
  static Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Kuala_Lumpur'));

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        // Asked later, in requestPermission(), when the student first books.
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(settings: settings);
    _initialized = true;
  }

  /// Asks for permission to show notifications (Android 13+ and iOS).
  /// Returns false if the student said no.
  static Future<bool> requestPermission() async {
    try {
      await init();
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        return await android.requestNotificationsPermission() ?? false;
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        return await ios.requestPermissions(
                alert: true, badge: true, sound: true) ??
            false;
      }
    } catch (e) {
      debugPrint('Notification permission request failed: $e');
    }
    return false;
  }

  /// Stable 31-bit notification ID for a booking (FNV-1a hash of its ref).
  static int idFor(String bookingRef) {
    var hash = 0x811c9dc5;
    for (final unit in bookingRef.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  /// Reminder at 8:00 AM the day before the booking.
  ///
  /// If that moment has already passed (booking is today, or tomorrow and
  /// it's after 8 AM), shows a confirmation right away instead, unless
  /// [showNowIfTooLate] is false (used when re-syncing existing bookings).
  static Future<ReminderOutcome> scheduleBookingReminder({
    required String bookingRef,
    required String facilityName,
    required String unitName,
    required DateTime date,
    required int startHour,
    bool showNowIfTooLate = true,
  }) async {
    try {
      await init();
      final now = tz.TZDateTime.now(tz.local);
      final startsAt =
          tz.TZDateTime(tz.local, date.year, date.month, date.day, startHour);
      final remindAt = tz.TZDateTime(
          tz.local, date.year, date.month, date.day - 1, _reminderHour);
      final time = CampusTime.timeLabel(startHour);
      final id = idFor(bookingRef);

      if (remindAt.isAfter(now)) {
        await _plugin.zonedSchedule(
          id: id,
          scheduledDate: remindAt,
          notificationDetails: _details,
          // Inexact: no "Alarms & reminders" permission needed; Android may
          // deliver it a few minutes late to save battery.
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          title: 'Facility Reservation Reminder ⏰',
          body: 'Reminder: You have a booking for $facilityName ($unitName) '
              'tomorrow at $time.',
          payload: bookingRef,
        );
        return ReminderOutcome.scheduled;
      }

      if (showNowIfTooLate && startsAt.isAfter(now)) {
        final when = CampusTime.isSameDay(date, CampusTime.today())
            ? 'today'
            : 'tomorrow';
        await _plugin.show(
          id: id,
          title: 'Booking confirmed ✅',
          body: 'You have a booking for $facilityName ($unitName) '
              '$when at $time.',
          notificationDetails: _details,
          payload: bookingRef,
        );
        return ReminderOutcome.shownNow;
      }
    } catch (e) {
      // A reminder problem must never break the booking itself.
      debugPrint('Could not set booking reminder: $e');
    }
    return ReminderOutcome.none;
  }

  /// Removes the reminder (scheduled or already shown) for a booking.
  static Future<void> cancelBookingReminder(String bookingRef) async {
    try {
      await init();
      await _plugin.cancel(id: idFor(bookingRef));
    } catch (e) {
      debugPrint('Could not cancel booking reminder: $e');
    }
  }

  /// Makes this phone's reminders match the student's bookings, e.g. after
  /// reinstalling the app. Upcoming bookings get their reminder (replacing
  /// any existing one); cancelled ones lose theirs. Never shows anything now.
  static Future<void> syncReminders(List<MyBooking> bookings) async {
    for (final b in bookings) {
      if (b.isCancelled) {
        await cancelBookingReminder(b.bookingRef);
      } else if (b.isActive) {
        await scheduleBookingReminder(
          bookingRef: b.bookingRef,
          facilityName: b.facilityName,
          unitName: b.unitName,
          date: b.date,
          startHour: b.startHour,
          showNowIfTooLate: false,
        );
      }
    }
  }

  /// Removes every reminder, e.g. on logout so the next person using this
  /// phone doesn't get someone else's reminders.
  static Future<void> cancelAll() async {
    try {
      await init();
      await _plugin.cancelAll();
    } catch (e) {
      debugPrint('Could not clear reminders: $e');
    }
  }
}
