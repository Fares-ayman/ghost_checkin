import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/native_state.dart';
import '../native/attendance_channel.dart';
import '../widgets/format.dart';
import '../widgets/suggestion_card.dart';
import 'correction_sheet.dart';
import 'log_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  NativeState? _state;
  String? _loadError;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    // Keeps the status and the confirmation countdown current.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    try {
      final state = await AttendanceChannel.getState();
      if (!mounted) return;
      setState(() {
        _state = state;
        _loadError = null;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.message ?? e.code);
    } on MissingPluginException {
      if (!mounted) return;
      setState(() => _loadError = 'The native attendance code is not available on this platform.');
    }
  }

  /// Runs a native action and shows its error, if any.
  Future<NativeState?> _run(Future<NativeState> Function() action) async {
    setState(() => _busy = true);
    try {
      final state = await action();
      if (!mounted) return state;
      setState(() => _state = state);
      return state;
    } on PlatformException catch (e) {
      _showMessage(e.message ?? e.code);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _requestPermission(
    String name,
    bool Function(NativeState) isGranted,
  ) async {
    final state = await _run(() => AttendanceChannel.requestPermission(name));
    if (state == null || isGranted(state)) return;
    _showMessage(
      'Not granted. You can allow it from the app settings.',
      action: const SnackBarAction(
        label: 'Open settings',
        onPressed: AttendanceChannel.openAppSettings,
      ),
    );
  }

  Future<void> _setOfficeHere() async {
    final state = await _run(AttendanceChannel.setOfficeHere);
    if (state != null) {
      _showMessage('Office set to your current location. Monitoring started.');
    }
  }

  Future<void> _sendSuggestion(ArrivalSuggestion suggestion) async {
    final events = await AttendanceChannel.getEvents();
    final matches = events.where((e) => e.id == suggestion.eventId);
    if (matches.isEmpty || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CorrectionSheet(event: matches.first, existing: null),
    );
    _refresh();
  }

  Future<void> _openLog() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LogScreen()),
    );
    _refresh();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Auto Attendance'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.tune),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: state == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _loadError == null
                      ? const CircularProgressIndicator()
                      : Text(_loadError!, textAlign: TextAlign.center),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _StatusCard(state: state),
                  if (state.suggestion != null) ...[
                    const SizedBox(height: 12),
                    SuggestionCard(
                      recorded: state.suggestion!.recorded,
                      estimated: state.suggestion!.estimated,
                      onSend: () => _sendSuggestion(state.suggestion!),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _openLog,
                    icon: const Icon(Icons.timeline),
                    label: const Text("Today's log"),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(
                              () => AttendanceChannel.manualTransition(
                                enter: !state.isInside,
                              ),
                            ),
                    icon: Icon(state.isInside ? Icons.logout : Icons.login),
                    label: Text(
                      state.isInside
                          ? 'Manual check-out'
                          : 'Manual check-in',
                    ),
                  ),
                  const SizedBox(height: 16),
                  _MonitoringCard(
                    state: state,
                    busy: _busy,
                    onSetOfficeHere: _setOfficeHere,
                  ),
                  const SizedBox(height: 16),
                  _SetupCard(
                    state: state,
                    busy: _busy,
                    onRequest: _requestPermission,
                    onOpenLocationSettings:
                        AttendanceChannel.openLocationSettings,
                    onBatteryExemption:
                        AttendanceChannel.requestBatteryExemption,
                    onSetOfficeHere: _setOfficeHere,
                  ),
                ],
              ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});

  final NativeState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final inside = state.isInside;
    final background =
        inside ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final foreground = inside ? scheme.onPrimaryContainer : scheme.onSurface;
    final pending = state.pending;

    return Card(
      color: background,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  inside ? Icons.apartment : Icons.directions_walk,
                  size: 36,
                  color: foreground,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    inside ? 'At the office' : 'Away from the office',
                    style: text.headlineSmall?.copyWith(color: foreground),
                  ),
                ),
              ],
            ),
            if (pending != null) ...[
              const SizedBox(height: 16),
              Text(
                '${pending.isEnter ? 'Entry' : 'Exit'} detected at '
                '${formatTime(pending.detectedAt)}.',
                style: text.bodyLarge?.copyWith(color: foreground),
              ),
              const SizedBox(height: 4),
              Text(
                'Confirming in '
                '${formatCountdown(pending.confirmAt.difference(DateTime.now()))}'
                '. It is dropped if you '
                '${pending.isEnter ? 'leave' : 'come back'} before then.',
                style: text.bodyMedium?.copyWith(color: foreground),
              ),
            ],
            if (state.motion != null) ...[
              const SizedBox(height: 12),
              Text(
                'Motion: ${motionLabel(state.motion)}'
                '${state.motionSince == null ? '' : ' since ${formatTime(state.motionSince!)}'}',
                style: text.bodyMedium?.copyWith(color: foreground),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MonitoringCard extends StatelessWidget {
  const _MonitoringCard({
    required this.state,
    required this.busy,
    required this.onSetOfficeHere,
  });

  final NativeState state;
  final bool busy;
  final VoidCallback onSetOfficeHere;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final active = state.geofenceActive;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  active ? Icons.radar : Icons.error_outline,
                  color: active ? scheme.primary : scheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    active
                        ? 'Automatic check-in is on'
                        : 'Automatic check-in is off',
                    style: text.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              active
                  ? 'The phone watches the office area and records entry and '
                      'exit, even when this app is closed.'
                  : state.geofenceError ?? 'Finish the setup below.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              state.hasOffice
                  ? 'Office: ${state.officeLat!.toStringAsFixed(5)}, '
                      '${state.officeLng!.toStringAsFixed(5)}'
                      '  ·  radius ${state.settings.radiusMeters} m'
                  : 'Office location is not set yet.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: busy ? null : onSetOfficeHere,
              icon: const Icon(Icons.my_location),
              label: const Text('Use my current location as the office'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupCard extends StatelessWidget {
  const _SetupCard({
    required this.state,
    required this.busy,
    required this.onRequest,
    required this.onOpenLocationSettings,
    required this.onBatteryExemption,
    required this.onSetOfficeHere,
  });

  final NativeState state;
  final bool busy;
  final Future<void> Function(String name, bool Function(NativeState) isGranted)
      onRequest;
  final VoidCallback onOpenLocationSettings;
  final VoidCallback onBatteryExemption;
  final VoidCallback onSetOfficeHere;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;

    final rows = <_SetupRow>[
      _SetupRow(
        done: state.locationPermission,
        title: 'Location permission',
        subtitle: 'Precise location, to know where the office boundary is.',
        actionLabel: 'Allow',
        onPressed: () => onRequest('location', (s) => s.locationPermission),
      ),
      _SetupRow(
        done: state.backgroundLocationPermission,
        title: state.isIos ? 'Always allow location' : 'Allow all the time',
        subtitle: 'Lets the phone record entry and exit while the app is '
            'closed.',
        actionLabel: 'Allow',
        onPressed: state.locationPermission
            ? () => onRequest(
                  'backgroundLocation',
                  (s) => s.backgroundLocationPermission,
                )
            : null,
      ),
      _SetupRow(
        done: state.locationEnabled,
        title: 'Location turned on',
        subtitle: state.isIos
            ? 'Location Services in the phone settings.'
            : 'The Location switch in the phone quick settings.',
        actionLabel: 'Open',
        onPressed: onOpenLocationSettings,
      ),
      _SetupRow(
        done: state.hasOffice,
        title: 'Office location',
        subtitle: 'For the demo, use wherever you are standing now.',
        actionLabel: 'Set',
        onPressed: state.locationPermission ? onSetOfficeHere : null,
      ),
      _SetupRow(
        done: state.activityPermission,
        title: 'Physical activity',
        subtitle: 'Motion as a second signal: walking, in a vehicle, still.',
        actionLabel: 'Allow',
        onPressed: () => onRequest('activity', (s) => s.activityPermission),
      ),
      _SetupRow(
        done: state.notificationsPermission,
        title: 'Notifications',
        subtitle: 'The check-in reminder, and a note when entry or exit is '
            'recorded.',
        actionLabel: 'Allow',
        onPressed: () =>
            onRequest('notifications', (s) => s.notificationsPermission),
      ),
      if (!state.isIos)
        _SetupRow(
          done: state.batteryUnrestricted,
          title: 'No battery restriction',
          subtitle: 'Recommended, so the phone does not stop the app in the '
              'background.',
          actionLabel: 'Open',
          onPressed: onBatteryExemption,
        ),
    ];
    final doneCount = rows.where((r) => r.done).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Setup', style: text.titleMedium),
            const SizedBox(height: 4),
            Text(
              '$doneCount of ${rows.length} done. Needed once.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final row in rows) _SetupTile(row: row, busy: busy),
          ],
        ),
      ),
    );
  }
}

class _SetupRow {
  const _SetupRow({
    required this.done,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onPressed,
  });

  final bool done;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback? onPressed;
}

class _SetupTile extends StatelessWidget {
  const _SetupTile({required this.row, required this.busy});

  final _SetupRow row;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        row.done ? Icons.check_circle : Icons.radio_button_unchecked,
        color: row.done ? scheme.primary : scheme.outline,
      ),
      title: Text(row.title),
      subtitle: Text(row.subtitle),
      trailing: row.done
          ? null
          : TextButton(
              onPressed: busy ? null : row.onPressed,
              child: Text(row.actionLabel),
            ),
    );
  }
}
