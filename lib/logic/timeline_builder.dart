import '../models/attendance_event.dart';

/// The attendance rules. In the demo they run on the phone; in the company
/// app the same rules belong on the server, fed by the same events.
///
/// * First confirmed entry of the day is the check-in.
/// * Leaving and coming back within the break limit is a break.
/// * Leaving for longer than the break limit is a check-out at the time the
///   person left. Coming back after that starts a new session.

enum TimelineKind { checkIn, breakTime, checkOut, returned, away }

class TimelineEntry {
  const TimelineEntry({
    required this.kind,
    required this.start,
    this.end,
    this.event,
  });

  final TimelineKind kind;
  final DateTime start;

  /// Only for breaks: when the person came back.
  final DateTime? end;

  /// The event behind this entry, for its note and motion.
  final AttendanceEvent? event;

  Duration? get duration => end?.difference(start);
}

class DayTimeline {
  const DayTimeline({
    required this.entries,
    required this.checkIn,
    required this.checkOut,
    required this.totalBreak,
    required this.timeInOffice,
    required this.isInside,
    required this.missingCheckOut,
  });

  final List<TimelineEntry> entries;
  final DateTime? checkIn;

  /// The last check-out of the day, or null while the day is still open.
  final DateTime? checkOut;
  final Duration totalBreak;
  final Duration timeInOffice;

  /// True when the last confirmed event of the day is an entry.
  final bool isInside;

  /// A past day that ended without any exit being recorded.
  final bool missingCheckOut;

  bool get isEmpty => entries.isEmpty;
}

bool isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Builds the timeline of [day] from [events].
///
/// Only confirmed events on that day are used. [now] decides whether an exit
/// with no return is still a possible break or already a check-out.
DayTimeline buildDayTimeline(
  List<AttendanceEvent> events, {
  required DateTime day,
  required DateTime now,
  required Duration breakLimit,
}) {
  final dayEvents = events
      .where((e) => e.isConfirmed && isSameDay(e.time, day))
      .toList()
    ..sort((a, b) => a.time.compareTo(b.time));

  final entries = <TimelineEntry>[];
  DateTime? checkIn;
  DateTime? checkOut;
  var totalBreak = Duration.zero;
  var timeInOffice = Duration.zero;

  var inside = false;
  DateTime? insideSince;
  AttendanceEvent? lastExit;

  for (final event in dayEvents) {
    if (event.isEnter) {
      if (inside) continue;
      final exit = lastExit;
      if (exit == null) {
        checkIn ??= event.time;
        entries.add(TimelineEntry(
          kind: TimelineKind.checkIn,
          start: event.time,
          event: event,
        ));
      } else {
        final gap = event.time.difference(exit.time);
        if (gap < breakLimit) {
          totalBreak += gap;
          entries.add(TimelineEntry(
            kind: TimelineKind.breakTime,
            start: exit.time,
            end: event.time,
            event: exit,
          ));
        } else {
          entries.add(TimelineEntry(
            kind: TimelineKind.checkOut,
            start: exit.time,
            event: exit,
          ));
          entries.add(TimelineEntry(
            kind: TimelineKind.returned,
            start: event.time,
            event: event,
          ));
        }
      }
      inside = true;
      insideSince = event.time;
      lastExit = null;
      checkOut = null;
    } else {
      if (!inside) continue;
      timeInOffice += event.time.difference(insideSince ?? event.time);
      inside = false;
      insideSince = null;
      lastExit = event;
    }
  }

  final isToday = isSameDay(day, now);
  final pendingExit = lastExit;

  if (pendingExit != null) {
    final stillPossibleBreak =
        isToday && now.difference(pendingExit.time) < breakLimit;
    if (stillPossibleBreak) {
      entries.add(TimelineEntry(
        kind: TimelineKind.away,
        start: pendingExit.time,
        event: pendingExit,
      ));
    } else {
      checkOut = pendingExit.time;
      entries.add(TimelineEntry(
        kind: TimelineKind.checkOut,
        start: pendingExit.time,
        event: pendingExit,
      ));
    }
  }

  if (inside && insideSince != null && isToday && now.isAfter(insideSince)) {
    timeInOffice += now.difference(insideSince);
  }

  return DayTimeline(
    entries: entries,
    checkIn: checkIn,
    checkOut: checkOut,
    totalBreak: totalBreak,
    timeInOffice: timeInOffice,
    isInside: inside,
    missingCheckOut: inside && !isToday,
  );
}
