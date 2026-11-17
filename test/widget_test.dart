import 'package:attendance_demo_app/logic/timeline_builder.dart';
import 'package:attendance_demo_app/models/attendance_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final day = DateTime(2026, 11, 15);
  DateTime at(int hour, int minute) => DateTime(2026, 11, 15, hour, minute);

  var nextId = 0;
  AttendanceEvent event(
    String type,
    DateTime time, {
    String status = 'confirmed',
  }) =>
      AttendanceEvent(
        id: '${nextId++}',
        type: type,
        time: time,
        source: 'geofence',
        status: status,
      );

  const breakLimit = Duration(minutes: 60);

  test('first entry is the check-in and the person is inside', () {
    final timeline = buildDayTimeline(
      [event('ENTER', at(9, 10))],
      day: day,
      now: at(11, 10),
      breakLimit: breakLimit,
    );

    expect(timeline.entries.single.kind, TimelineKind.checkIn);
    expect(timeline.checkIn, at(9, 10));
    expect(timeline.checkOut, isNull);
    expect(timeline.isInside, isTrue);
    expect(timeline.timeInOffice, const Duration(hours: 2));
  });

  test('leaving and returning within the limit is a break', () {
    final timeline = buildDayTimeline(
      [
        event('ENTER', at(9, 0)),
        event('EXIT', at(13, 5)),
        event('ENTER', at(13, 35)),
      ],
      day: day,
      now: at(14, 0),
      breakLimit: breakLimit,
    );

    expect(
      timeline.entries.map((e) => e.kind),
      [TimelineKind.checkIn, TimelineKind.breakTime],
    );
    expect(timeline.totalBreak, const Duration(minutes: 30));
    expect(timeline.checkOut, isNull);
    expect(timeline.isInside, isTrue);
  });

  test('leaving for longer than the limit is a check-out, then a return', () {
    final timeline = buildDayTimeline(
      [
        event('ENTER', at(9, 0)),
        event('EXIT', at(12, 0)),
        event('ENTER', at(14, 0)),
      ],
      day: day,
      now: at(15, 0),
      breakLimit: breakLimit,
    );

    expect(
      timeline.entries.map((e) => e.kind),
      [TimelineKind.checkIn, TimelineKind.checkOut, TimelineKind.returned],
    );
    expect(timeline.totalBreak, Duration.zero);
    expect(timeline.checkOut, isNull, reason: 'the person is back inside');
    expect(timeline.timeInOffice, const Duration(hours: 4));
  });

  test('a recent exit is "away" until the break limit passes', () {
    final events = [event('ENTER', at(9, 0)), event('EXIT', at(18, 0))];

    final soon = buildDayTimeline(
      events,
      day: day,
      now: at(18, 20),
      breakLimit: breakLimit,
    );
    expect(soon.entries.last.kind, TimelineKind.away);
    expect(soon.checkOut, isNull);

    final later = buildDayTimeline(
      events,
      day: day,
      now: at(19, 30),
      breakLimit: breakLimit,
    );
    expect(later.entries.last.kind, TimelineKind.checkOut);
    expect(later.checkOut, at(18, 0));
    expect(later.timeInOffice, const Duration(hours: 9));
  });

  test('pending and discarded events are ignored', () {
    final timeline = buildDayTimeline(
      [
        event('ENTER', at(8, 50), status: 'discarded'),
        event('ENTER', at(9, 10)),
        event('EXIT', at(10, 0), status: 'pending'),
      ],
      day: day,
      now: at(10, 30),
      breakLimit: breakLimit,
    );

    expect(timeline.entries.single.kind, TimelineKind.checkIn);
    expect(timeline.checkIn, at(9, 10));
    expect(timeline.isInside, isTrue);
  });

  test('a past day with no exit is flagged', () {
    final timeline = buildDayTimeline(
      [event('ENTER', at(9, 0))],
      day: day,
      now: DateTime(2026, 11, 16, 10),
      breakLimit: breakLimit,
    );

    expect(timeline.missingCheckOut, isTrue);
    expect(timeline.checkOut, isNull);
  });

  test('events from other days are not included', () {
    final timeline = buildDayTimeline(
      [
        event('ENTER', DateTime(2026, 11, 14, 9)),
        event('EXIT', DateTime(2026, 11, 14, 17)),
      ],
      day: day,
      now: at(10, 0),
      breakLimit: breakLimit,
    );

    expect(timeline.isEmpty, isTrue);
  });
}
