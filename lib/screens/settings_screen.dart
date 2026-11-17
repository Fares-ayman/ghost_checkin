import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/native_state.dart';
import '../native/attendance_channel.dart';
import '../widgets/format.dart';

/// Every threshold is adjustable so the whole flow can be shown in a few
/// minutes. The real values are 5 minutes to confirm and 60 minutes for a
/// break.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AttendanceSettings? _settings;

  @override
  void initState() {
    super.initState();
    _apply(AttendanceChannel.getState);
  }

  Future<void> _apply(Future<NativeState> Function() action) async {
    try {
      final state = await action();
      if (!mounted) return;
      setState(() => _settings = state.settings);
    } on PlatformException catch (e) {
      _showMessage(e.message ?? e.code);
    } on MissingPluginException {
      _showMessage('The native attendance code is not available on this platform.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _pickReminderTime(AttendanceSettings settings) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: settings.reminderHour,
        minute: settings.reminderMinute,
      ),
    );
    if (picked == null) return;
    await _apply(
      () => AttendanceChannel.updateSettings(
        reminderHour: picked.hour,
        reminderMinute: picked.minute,
      ),
    );
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear stored events?'),
        content: const Text(
          'Removes all stored events and motion history from this phone. '
          'Settings and the office location are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _apply(AttendanceChannel.clearData);
    _showMessage('Stored events cleared.');
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: settings == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: () => _apply(
                            () => AttendanceChannel.updateSettings(
                              confirmSeconds: 60,
                              breakMinutes: 10,
                            ),
                          ),
                          child: const Text('Demo values'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: () => _apply(
                            () => AttendanceChannel.updateSettings(
                              confirmSeconds: 300,
                              breakMinutes: 60,
                            ),
                          ),
                          child: const Text('Real values'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _ChoiceSetting(
                    title: 'Confirmation window',
                    description: 'How long to stay inside or outside before '
                        'an entry or exit counts.',
                    values: const [30, 60, 120, 300],
                    selected: settings.confirmSeconds,
                    labelOf: (v) => formatDuration(Duration(seconds: v)),
                    onSelected: (v) => _apply(
                      () => AttendanceChannel.updateSettings(confirmSeconds: v),
                    ),
                  ),
                  _ChoiceSetting(
                    title: 'Break limit',
                    description: 'Away for less than this is a break. Longer '
                        'is a check-out.',
                    values: const [2, 10, 30, 60],
                    selected: settings.breakMinutes,
                    labelOf: (v) => formatDuration(Duration(minutes: v)),
                    onSelected: (v) => _apply(
                      () => AttendanceChannel.updateSettings(breakMinutes: v),
                    ),
                  ),
                  _ChoiceSetting(
                    title: 'Office radius',
                    description: 'Below 100 m the phone cannot detect the '
                        'boundary reliably.',
                    values: const [100, 150, 200, 300],
                    selected: settings.radiusMeters,
                    labelOf: (v) => '$v m',
                    onSelected: (v) => _apply(
                      () => AttendanceChannel.updateSettings(radiusMeters: v),
                    ),
                  ),
                  const Divider(height: 32),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Check-in reminder'),
                    subtitle: const Text(
                      'One notification a day if no check-in was recorded.',
                    ),
                    trailing: Text(
                      formatTime(
                        DateTime(
                          2000,
                          1,
                          1,
                          settings.reminderHour,
                          settings.reminderMinute,
                        ),
                      ),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    onTap: () => _pickReminderTime(settings),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Confirm faster with motion'),
                    subtitle: const Text(
                      'An entry on foot is confirmed at once. In a vehicle it '
                      'waits for the full window.',
                    ),
                    value: settings.motionFastConfirm,
                    onChanged: (v) => _apply(
                      () => AttendanceChannel.updateSettings(
                        motionFastConfirm: v,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Notify on entry and exit'),
                    subtitle: const Text(
                      'Shows when something was recorded while the app was '
                      'closed. Useful for the demo.',
                    ),
                    value: settings.eventNotifications,
                    onChanged: (v) => _apply(
                      () => AttendanceChannel.updateSettings(
                        eventNotifications: v,
                      ),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Arrival nudge (Android)'),
                    subtitle: const Text(
                      'With Location off, motion shows you got out of a vehicle, '
                      'walked and stopped. On a work day with no check-in, you '
                      'get one nudge to turn Location on.',
                    ),
                    value: settings.arrivalNudge,
                    onChanged: (v) => _apply(
                      () => AttendanceChannel.updateSettings(arrivalNudge: v),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Work days',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    'The reminder and the arrival nudge only run on these days.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (var day = 1; day <= 7; day++)
                        FilterChip(
                          label: Text(_dayNames[day - 1]),
                          selected: settings.workdays.contains(day),
                          onSelected: (on) {
                            final next = {...settings.workdays};
                            on ? next.add(day) : next.remove(day);
                            if (next.isEmpty) return;
                            _apply(
                              () => AttendanceChannel.updateSettings(
                                workdays: next.toList()..sort(),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                  const Divider(height: 32),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await _apply(AttendanceChannel.refreshMonitoring);
                      _showMessage('Monitoring registered again.');
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Register monitoring again'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _confirmClear,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Clear stored events'),
                  ),
                ],
              ),
      ),
    );
  }
}

const _dayNames = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

class _ChoiceSetting extends StatelessWidget {
  const _ChoiceSetting({
    required this.title,
    required this.description,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final String title;
  final String description;
  final List<int> values;
  final int selected;
  final String Function(int value) labelOf;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Keep a value that is not one of the presets visible as its own chip.
    final options = values.contains(selected)
        ? values
        : ([...values, selected]..sort());

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleMedium),
          const SizedBox(height: 2),
          Text(description, style: text.bodySmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final value in options)
                ChoiceChip(
                  label: Text(labelOf(value)),
                  selected: value == selected,
                  onSelected: (_) => onSelected(value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
