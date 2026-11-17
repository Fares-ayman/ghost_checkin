import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/attendance_event.dart';
import '../native/attendance_channel.dart';
import '../widgets/format.dart';

/// Lets the employee ask for the recorded time of one event to be changed,
/// for example when the phone was off on arrival. The request goes to the
/// manager together with what the phone detected.
///
/// The demo has no server, so the manager's decision is made here as well.
class CorrectionSheet extends StatefulWidget {
  const CorrectionSheet({
    super.key,
    required this.event,
    required this.existing,
  });

  /// The event as it was detected, before any correction.
  final AttendanceEvent event;
  final CorrectionRequest? existing;

  @override
  State<CorrectionSheet> createState() => _CorrectionSheetState();
}

class _CorrectionSheetState extends State<CorrectionSheet> {
  final _reason = TextEditingController();
  late TimeOfDay _time;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    // Start from the best guess: a previous request, then the motion estimate.
    final initial = existing?.requestedTime ??
        widget.event.estimatedTime ??
        widget.event.time;
    _time = TimeOfDay.fromDateTime(initial);
    final estimated = widget.event.estimatedTime;
    _reason.text = existing?.reason ??
        (estimated != null && widget.event.isEnter
            ? 'Location was off when I arrived. Motion shows I arrived around '
                '${formatTime(estimated)}.'
            : '');
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  DateTime get _requested {
    final day = widget.event.time;
    return DateTime(day.year, day.month, day.day, _time.hour, _time.minute);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked == null || !mounted) return;
    setState(() {
      _time = picked;
      _error = null;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message ?? e.code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final detected = widget.event.time;
    final requested = _requested;
    if (requested.hour == detected.hour && requested.minute == detected.minute) {
      setState(() => _error = 'Choose a time different from the detected one.');
      return;
    }
    if (requested.isAfter(DateTime.now())) {
      setState(() => _error = 'The time cannot be in the future.');
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = 'Add a short reason for the manager.');
      return;
    }
    await _run(
      () => AttendanceChannel.requestCorrection(
        eventId: widget.event.id,
        requestedTime: requested,
        reason: _reason.text.trim(),
      ),
    );
  }

  Future<void> _resolve(bool approved) => _run(
        () => AttendanceChannel.resolveCorrection(
          eventId: widget.event.id,
          approved: approved,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final event = widget.event;
    final existing = widget.existing;
    final estimated = event.estimatedTime;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              event.isEnter ? 'Correct arrival time' : 'Correct leaving time',
              style: text.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(
              'Detected at ${formatTime(event.time)} '
              '(${sourceLabel(event.source).toLowerCase()}).',
              style: text.bodyLarge,
            ),
            if (estimated != null) ...[
              const SizedBox(height: 4),
              Text(
                'Motion history suggests ${formatTime(estimated)}.',
                style: text.bodyLarge,
              ),
            ],
            if (event.note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                event.note,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
            if (existing != null) ...[
              const SizedBox(height: 12),
              Text(
                existing.isPending
                    ? 'Requested ${formatTime(existing.requestedTime)}. '
                        'Waiting for the manager.'
                    : existing.isApproved
                        ? 'Approved: ${formatTime(existing.requestedTime)}.'
                        : 'Rejected: ${formatTime(existing.requestedTime)}.',
                style: text.bodyMedium?.copyWith(
                  color: existing.isRejected ? scheme.error : scheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule),
              title: const Text('Actual time'),
              trailing: Text(formatTime(_requested), style: text.titleMedium),
              onTap: _busy ? null : _pickTime,
            ),
            TextField(
              controller: _reason,
              enabled: !_busy,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'For example: phone battery was empty',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(
                existing == null ? 'Send to manager' : 'Send a new request',
              ),
            ),
            if (existing != null && existing.isPending) ...[
              const Divider(height: 32),
              Text('Manager decision (demo only)', style: text.titleSmall),
              const SizedBox(height: 4),
              Text(
                'In the company app this is the manager, on the dashboard.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _resolve(false),
                      child: const Text('Reject'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _busy ? null : () => _resolve(true),
                      child: const Text('Approve'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
