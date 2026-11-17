import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../logic/timeline_builder.dart';
import '../models/attendance_event.dart';
import '../models/native_state.dart';
import '../native/attendance_channel.dart';
import '../widgets/format.dart';
import 'correction_sheet.dart';
import '../widgets/suggestion_card.dart';

/// The day as the attendance system would see it: a timeline built from the
/// stored events, and the raw events that are ready to be sent to the API.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  DateTime _day = DateTime.now();
  List<AttendanceEvent> _events = const [];
  List<MotionEntry> _motion = const [];
  List<CorrectionRequest> _corrections = const [];
  AttendanceSettings _settings = const AttendanceSettings();
  bool _loaded = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final state = await AttendanceChannel.getState();
      final events = await AttendanceChannel.getEvents();
      final motion = await AttendanceChannel.getMotionLog();
      final corrections = await AttendanceChannel.getCorrections();
      if (!mounted) return;
      setState(() {
        _settings = state.settings;
        _events = events;
        _motion = motion;
        _corrections = corrections;
        _loaded = true;
      });
    } on PlatformException {
      // Keep showing the last loaded data.
    } on MissingPluginException {
      if (mounted) setState(() => _loaded = true);
    }
  }

  void _changeDay(int days) {
    setState(() => _day = _day.add(Duration(days: days)));
  }

  CorrectionRequest? _correctionFor(String? eventId) {
    for (final correction in _corrections) {
      if (correction.eventId == eventId) return correction;
    }
    return null;
  }

  /// Stored events, with approved corrections applied to their time.
  List<AttendanceEvent> get _effectiveEvents => [
        for (final event in _events) _withCorrection(event),
      ];

  AttendanceEvent _withCorrection(AttendanceEvent event) {
    final correction = _correctionFor(event.id);
    return correction != null && correction.isApproved
        ? event.withCorrectedTime(correction.requestedTime)
        : event;
  }

  List<AttendanceEvent> _eventsOfDay(List<AttendanceEvent> events) => events
      .where((e) => isSameDay(e.time, _day))
      .toList()
    ..sort((a, b) => a.time.compareTo(b.time));

  /// The day's first check-in, when motion suggests an earlier arrival and
  /// nothing was requested for it yet.
  AttendanceEvent? _suggestionFor(List<AttendanceEvent> dayEvents) {
    final enters = dayEvents.where((e) => e.isConfirmed && e.isEnter);
    if (enters.isEmpty) return null;
    final first = enters.first;
    final estimated = first.estimatedTime;
    if (estimated == null) return null;
    if (first.time.difference(estimated) < const Duration(minutes: 5)) {
      return null;
    }
    if (_correctionFor(first.id) != null) return null;
    return first;
  }

  /// Opens the correction sheet for the event as it was detected.
  Future<void> _openCorrection(String eventId) async {
    final matches = _events.where((e) => e.id == eventId && e.isConfirmed);
    if (matches.isEmpty) return;
    final detected = matches.first;
    final existing = _correctionFor(eventId);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CorrectionSheet(event: detected, existing: existing),
    );
    await _load();
  }

  void _showPayload(List<AttendanceEvent> dayEvents) {
    final payload = const JsonEncoder.withIndent('  ').convert({
      'events': [
        for (final e in dayEvents)
          if (e.isConfirmed) e.toApiJson(),
      ],
      'corrections': [
        for (final e in dayEvents)
          if (_correctionFor(e.id) != null) _correctionFor(e.id)!.toApiJson(),
      ],
    });

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('POST /attendance/events'),
        content: SingleChildScrollView(
          child: SelectableText(
            payload,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: payload));
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Copy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isToday = isSameDay(_day, now);
    final effectiveEvents = _effectiveEvents;
    final dayEvents = _eventsOfDay(effectiveEvents);
    final timeline = buildDayTimeline(
      effectiveEvents,
      day: _day,
      now: now,
      breakLimit: _settings.breakLimit,
    );
    final dayMotion = _motion
        .where((m) => m.transition == 'enter' && isSameDay(m.time, _day))
        .toList();
    final confirmedCount = dayEvents.where((e) => e.isConfirmed).length;

    return Scaffold(
      appBar: AppBar(title: const Text('Attendance log')),
      body: SafeArea(
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _DayPicker(
                    day: _day,
                    isToday: isToday,
                    onPrevious: () => _changeDay(-1),
                    onNext: isToday ? null : () => _changeDay(1),
                  ),
                  const SizedBox(height: 12),
                  _SummaryCard(timeline: timeline, isToday: isToday),
                  if (_suggestionFor(_eventsOfDay(_events)) case final s?) ...[
                    const SizedBox(height: 12),
                    SuggestionCard(
                      recorded: s.time,
                      estimated: s.estimatedTime!,
                      onSend: () => _openCorrection(s.id),
                    ),
                  ],
                  const SizedBox(height: 20),
                  const _SectionTitle('Timeline'),
                  if (!timeline.isEmpty)
                    const _EmptyNote(
                      'Tap a check-in or check-out to ask for its time to be '
                      'corrected.',
                    ),
                  if (timeline.isEmpty)
                    const _EmptyNote('No confirmed entry on this day yet.')
                  else
                    Card(
                      child: Column(
                        children: [
                          for (final entry in timeline.entries)
                            _TimelineTile(
                              entry: entry,
                              breakLimit: _settings.breakLimit,
                              correction: _correctionFor(entry.event?.id),
                              onCorrect: _openCorrection,
                            ),
                          if (timeline.missingCheckOut)
                            const _FlagTile(
                              'No exit was recorded on this day. Flagged for '
                              'review.',
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Expanded(child: _SectionTitle('Stored events')),
                      TextButton.icon(
                        onPressed: confirmedCount == 0
                            ? null
                            : () => _showPayload(dayEvents),
                        icon: const Icon(Icons.data_object, size: 18),
                        label: const Text('API payload'),
                      ),
                    ],
                  ),
                  if (dayEvents.isEmpty)
                    const _EmptyNote('Nothing stored for this day.')
                  else
                    Card(
                      child: Column(
                        children: [
                          for (final event in dayEvents.reversed)
                            _EventTile(
                              event: event,
                              correction: _correctionFor(event.id),
                              onCorrect: _openCorrection,
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 20),
                  const _SectionTitle('Motion'),
                  if (dayMotion.isEmpty)
                    const _EmptyNote(
                      'No motion changes recorded. The first ones can take a '
                      'few minutes after the permission is granted.',
                    )
                  else
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final m in dayMotion.reversed.take(12))
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 3),
                                child: Text(
                                  '${formatTime(m.time)}   '
                                  '${motionLabel(m.type)}',
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _DayPicker extends StatelessWidget {
  const _DayPicker({
    required this.day,
    required this.isToday,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime day;
  final bool isToday;
  final VoidCallback onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Previous day',
          onPressed: onPrevious,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            isToday ? 'Today, ${formatDay(day)}' : formatDay(day),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton(
          tooltip: 'Next day',
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.timeline, required this.isToday});

  final DayTimeline timeline;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final checkIn = timeline.checkIn;
    final checkOut = timeline.checkOut;

    final String checkOutText;
    if (checkOut != null) {
      checkOutText = formatTime(checkOut);
    } else if (timeline.missingCheckOut) {
      checkOutText = 'Unknown';
    } else if (timeline.isInside && isToday) {
      checkOutText = 'Still in';
    } else {
      checkOutText = '--';
    }

    return Card(
      color: scheme.secondaryContainer,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Row(
          children: [
            _SummaryItem(
              label: 'Check-in',
              value: checkIn == null ? '--' : formatTime(checkIn),
            ),
            _SummaryItem(label: 'Check-out', value: checkOutText),
            _SummaryItem(
              label: 'Breaks',
              value: timeline.totalBreak == Duration.zero
                  ? '--'
                  : formatDuration(timeline.totalBreak),
            ),
            _SummaryItem(
              label: 'In office',
              value: timeline.timeInOffice == Duration.zero
                  ? '--'
                  : formatDuration(timeline.timeInOffice),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            textAlign: TextAlign.center,
            style: text.titleMedium?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: text.bodySmall?.copyWith(color: scheme.onSecondaryContainer),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _EmptyNote extends StatelessWidget {
  const _EmptyNote(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _FlagTile extends StatelessWidget {
  const _FlagTile(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.flag_outlined, color: scheme.error),
      title: Text(message),
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({
    required this.entry,
    required this.breakLimit,
    required this.correction,
    required this.onCorrect,
  });

  final TimelineEntry entry;
  final Duration breakLimit;
  final CorrectionRequest? correction;
  final ValueChanged<String> onCorrect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final event = entry.event;

    final IconData icon;
    final String title;
    String detail;

    switch (entry.kind) {
      case TimelineKind.checkIn:
        icon = Icons.login;
        title = 'Check-in  ${formatTime(entry.start)}';
        detail = _signals(event);
      case TimelineKind.breakTime:
        icon = Icons.free_breakfast_outlined;
        title = 'Break  ${formatTime(entry.start)} to '
            '${formatTime(entry.end ?? entry.start)}';
        detail = formatDuration(entry.duration ?? Duration.zero);
      case TimelineKind.checkOut:
        icon = Icons.logout;
        title = 'Check-out  ${formatTime(entry.start)}';
        detail = event?.source == 'motion'
            ? 'No exit was detected. Estimated from motion: got into a '
                'vehicle at this time.'
            : 'Did not return within ${formatDuration(breakLimit)}.';
      case TimelineKind.returned:
        icon = Icons.replay;
        title = 'Returned  ${formatTime(entry.start)}';
        detail = 'Came back after a check-out. Flagged for review.';
      case TimelineKind.away:
        icon = Icons.directions_walk;
        title = 'Left  ${formatTime(entry.start)}';
        detail = 'A break if back within ${formatDuration(breakLimit)}, '
            'otherwise a check-out at this time.';
    }

    final detected = event?.detectedTime;
    if (entry.kind == TimelineKind.checkIn && detected != null) {
      detail = '$detail\nFound inside at ${formatTime(detected)}; '
          'the phone had not moved since ${formatTime(entry.start)}.';
    }
    final estimated = event?.estimatedTime;
    if (entry.kind == TimelineKind.checkIn && estimated != null) {
      detail = '$detail\nMotion suggests arrival around '
          '${formatTime(estimated)}.';
    }
    if (entry.kind == TimelineKind.checkOut && estimated != null) {
      detail = '$detail\nMotion suggests leaving around '
          '${formatTime(estimated)}.';
    }

    // Only a check-in or check-out maps to exactly one event.
    final isSingleEvent = entry.kind == TimelineKind.checkIn ||
        entry.kind == TimelineKind.checkOut;
    final target = isSingleEvent ? event : null;
    if (target != null) {
      final status = correctionLine(target, correction);
      if (status.isNotEmpty) {
        detail = detail.isEmpty ? status : '$detail\n$status';
      }
    }

    return ListTile(
      leading: Icon(icon, color: scheme.primary),
      title: Text(title),
      subtitle: detail.isEmpty ? null : Text(detail),
      trailing:
          target == null ? null : const Icon(Icons.edit_outlined, size: 20),
      onTap: target == null ? null : () => onCorrect(target.id),
    );
  }

  static String _signals(AttendanceEvent? event) {
    if (event == null) return '';
    final parts = [
      sourceLabel(event.source),
      if (event.motion != null) motionLabel(event.motion).toLowerCase(),
    ];
    return parts.join(' + ');
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.event,
    required this.correction,
    required this.onCorrect,
  });

  final AttendanceEvent event;
  final CorrectionRequest? correction;
  final ValueChanged<String> onCorrect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final String statusLabel;
    final Color statusColor;
    if (event.isConfirmed) {
      statusLabel = 'Ready to send';
      statusColor = scheme.primary;
    } else if (event.isPending) {
      statusLabel = 'Confirming';
      statusColor = scheme.tertiary;
    } else {
      statusLabel = 'Discarded';
      statusColor = scheme.outline;
    }

    final details = [
      [
        sourceLabel(event.source),
        if (event.motion != null) 'motion: ${motionLabel(event.motion)}',
      ].join('  ·  '),
      if (event.note.isNotEmpty) event.note,
      if (correctionLine(event, correction).isNotEmpty)
        correctionLine(event, correction),
    ].join('\n');

    return ListTile(
      leading: Icon(
        event.isEnter ? Icons.south_east : Icons.north_east,
        color: event.isDiscarded ? scheme.outline : scheme.onSurface,
      ),
      // The status sits in the title row so the note below gets full width.
      title: Row(
        children: [
          Expanded(
            child: Text(
              '${event.isEnter ? 'Entered' : 'Left'}  '
              '${formatTimeWithSeconds(event.time)}',
            ),
          ),
          const SizedBox(width: 8),
          Text(
            statusLabel,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: statusColor),
          ),
        ],
      ),
      subtitle: Text(details),
      isThreeLine: event.note.isNotEmpty || correction != null,
      onTap: event.isConfirmed ? () => onCorrect(event.id) : null,
    );
  }
}

/// One line describing the correction state of [event], or an empty string.
String correctionLine(AttendanceEvent event, CorrectionRequest? correction) {
  if (correction == null) return '';
  final requested = formatTime(correction.requestedTime);
  if (correction.isApproved) {
    final detected = event.originalTime;
    return detected == null
        ? 'Corrected to $requested. Approved by the manager.'
        : 'Corrected from ${formatTime(detected)}. Approved by the manager.';
  }
  if (correction.isRejected) {
    return 'Correction to $requested was rejected.';
  }
  return 'Correction requested: $requested. Waiting for the manager.';
}
