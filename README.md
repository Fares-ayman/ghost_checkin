# Auto Attendance demo

A small Flutter app (Android and iOS) that records office attendance with no
daily action from the employee.

## How it works

1. A geofence around the office is registered with Google Play services. The
   system wakes the app on entry and exit, even when the app is closed.
2. An entry or exit is confirmed only after the phone stays on the same side
   of the boundary for the confirmation window (5 minutes). Passing by is
   discarded. The recorded time is the time of the original signal.
3. Motion (walking, in a vehicle, still) is a second signal. An entry on foot
   is confirmed at once. For a late detection it suggests the real arrival
   time.
4. Events are stored on the phone first. The log screen shows them as they
   would be sent to the API.
5. Rules: first entry is the check-in. Away for less than 60 minutes is a
   break. Away for longer is a check-out at the time the person left.
6. One reminder a day (12:00) if no check-in was recorded.
7. Manual check-in stays available as the fallback.

## Run

    flutter pub get
    flutter run
    flutter test

iOS builds need a Mac with Xcode. The iOS code has not been compiled yet.

## Where things are

| Part | Location |
|---|---|
| Android: geofence, motion, alarms, storage | `android/app/src/main/kotlin/.../*.kt` |
| iOS: geofence, motion, reminders, channel | `ios/Runner/AttendanceBridge.swift` |
| iOS: storage and constants | `ios/Runner/AttendanceStore.swift` |
| Attendance rules (check-in, break, check-out) | `lib/logic/timeline_builder.dart` |
| Bridge to native | `lib/native/attendance_channel.dart` |
| Screens | `lib/screens/` |
| Rule tests | `test/widget_test.dart` (`flutter test`) |

## Not in the demo

- No server. The rules run on the phone and the events stay local.
- No real manager. A time-correction request is stored on the phone, and the approve / reject buttons stand in for the manager.
- The reminder fires every day. Days off are not skipped.

## iOS differences

- iOS cannot run code at a set time while the app is closed. A pending entry
  or exit is confirmed the next time the app wakes, if no opposite signal
  arrived before its window ended. The recorded time is unchanged.
- The reminder is scheduled ahead for each day and removed for today as soon
  as an entry is detected.
- Motion is read from the phone's own history when a signal arrives.
