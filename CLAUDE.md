# Auto Attendance demo: project context

Handoff notes from the design conversation. Read this before changing code.

## What this is

A Flutter demo for the MD-Labs "Stump the Model" challenge (deadline: end of
Monday 16 Nov 2026). It records office attendance with no daily action from
the employee. If accepted, the feature moves into the company app.

The problem with the current system: check-in is a manual button gated by a
GPS range. People forget it, nobody checks out, and it sometimes says "outside"
when the person is inside.

## Decisions already made (do not reopen without asking)

- **Signal:** an OS geofence around the office (~150 m). The system wakes the
  app on entry and exit even when it is terminated. Requires "Always" location.
- **Rejected:** office Wi-Fi / IP detection (too dependent on IT), Bluetooth
  beacons, NFC tap, server push reminders.
- **Confirmation window:** an entry or exit counts only if the phone stays on
  that side for 5 minutes. The opposite signal inside the window discards it.
  The recorded time is the original signal time, not the confirmation time.
- **Motion** is a second signal, never a trigger for an entry. An entry on
  foot confirms at once. For a late detection it suggests the arrival or
  leaving time. One exception: when a day ends with no exit detected, the
  exit is filled in at the last time that day the phone got into a vehicle
  (`source: motion`), marked as an estimate. A new day always starts
  "outside". On Android this runs from an alarm at 00:05; on iOS it runs the
  next time the app wakes.
- **Rules:** first confirmed entry = check-in. Exit then entry within 60 min =
  break. Exit with no return within 60 min = check-out at the exit time.
- **Time correction:** tap a check-in or check-out in the log to request a
  different time with a reason. Stored locally. An approved request replaces
  the time used by the rules; the detected time is kept and still sent. The
  approve / reject buttons stand in for the manager (`correction_sheet.dart`).
- **Reminder:** one local notification at 12:00 if no check-in today. No
  action buttons. Days off are not skipped in the demo (the company app knows
  them).
- **Late detection set back to stillness:** when the phone is found inside on
  (re)registration and its latest motion change is "still" (started after the
  last confirmed event and over 5 min ago), the check-in is recorded at the
  start of that stillness (`detectedTs` keeps when it was found). The confirm
  window still runs from detection (`confirmAfter`). Any earlier time (vehicle
  exit) stays a suggestion for the manager: motion cannot say where the phone
  was before it last moved.
- **Location watch (Android):** after the arrival nudge or the noon reminder
  with Location off, an alarm checks every 2 min for 20 min and registers the
  geofence as soon as Location is on.
- **Arrival suggestion:** when a check-in has a motion estimate at least 5 min
  earlier and no correction yet, the home and log screens show a card with
  "Send <time> to my manager", opening the correction sheet pre-filled.
- **Arrival nudge (Android only):** with Location off, on a work day with no
  check-in, between 06:00 and 16:00, when motion goes vehicle -> walking ->
  still within 30 min: one notification a day to turn Location on (tap opens
  Location settings). iOS cannot do this while closed: motion does not wake it.
- **Work days:** default Sunday to Thursday, set in Settings. The noon reminder
  and the nudge run on work days only.
- **Fallbacks:** the existing manual check-in stays, plus the time-correction
  request.
- **No server in the demo.** Events are stored locally and shown on the log
  screen as the payload that would be posted. Coordinates are never sent.
- **Thresholds are configurable** so the flow can be demonstrated in minutes
  ("Demo values": 60 s confirm, 10 min break).

## Structure

- `lib/logic/timeline_builder.dart`: the rules. Pure Dart, covered by
  `test/widget_test.dart`. These move to the server later.
- `lib/native/attendance_channel.dart`: the only bridge. Channel
  `attendance/native`.
- `lib/screens/`: home (status + setup checklist), log (timeline, stored
  events, API payload, motion), settings.
- `android/app/src/main/kotlin/com/example/attendance_demo_app/`: all
  background work. `AttendanceEngine` (pending/confirm/discard),
  `GeofenceManager`, `ActivityMonitor`, `AttendanceAlarms`, `AttendanceStore`,
  `Notifier`, `BootReceiver`, `Perms`, `MainActivity`.
- `ios/Runner/AttendanceBridge.swift` and `AttendanceStore.swift`: the same
  for iOS, hooked from `AppDelegate.swift`.

Background work is native on purpose: events arrive while the Flutter engine
is not running. No plugins are used. The UI uses plain `setState`, not Bloc.

## Platform differences

- Android confirms with an exact alarm. iOS cannot run code at a set time, so
  it confirms lazily on the next wake.
- Android runs code at reminder time and checks. iOS pre-schedules the
  reminder per day and removes today's when an entry is detected.
- Android stores motion transitions as they arrive. iOS queries the system's
  motion history when a signal arrives.

## Verification status

- Kotlin: compiled cleanly against the Android 34 SDK jar, with hand-written
  stand-ins for the Flutter embedding and Play services classes. Not yet built
  with Gradle.
- Dart: not compiled. Not run.
- Swift: not compiled. `project.pbxproj` was edited by hand to add the two
  Swift files. Needs a Mac.
- Nothing has been tested on a device.

Project was generated with Flutter 3.22 (Kotlin 1.7.10, Gradle 7.6.3, AGP
7.3.0). `play-services-location` is pinned to 21.0.1 for that Kotlin version.

## Next steps

1. `flutter pub get`, `flutter run` on Android, fix build errors.
2. `flutter test`.
3. Device test: set the office to the current location, use "Demo values",
   close the app, walk 300 m away and back.
4. Check behaviour on Xiaomi / Oppo / Samsung with the app swiped away.
5. Build and test iOS on a Mac.
6. Later: server sync and a real manager approval flow, integration into the company
   app (which uses Clean Architecture with Bloc/Cubit).

## For the challenge write-up

Keep a list of every place the model got something wrong and why. The judges
score that as much as what worked.
