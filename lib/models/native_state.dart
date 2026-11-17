/// A snapshot of what the native side knows right now.
class NativeState {
  const NativeState({
    required this.locationPermission,
    required this.backgroundLocationPermission,
    required this.activityPermission,
    required this.notificationsPermission,
    required this.batteryUnrestricted,
    required this.locationEnabled,
    required this.geofenceActive,
    required this.geofenceError,
    required this.isInside,
    required this.officeLat,
    required this.officeLng,
    required this.pending,
    required this.motion,
    required this.motionSince,
    required this.settings,
    required this.isIos,
    required this.suggestion,
  });

  final bool locationPermission;
  final bool backgroundLocationPermission;
  final bool activityPermission;
  final bool notificationsPermission;
  final bool batteryUnrestricted;
  final bool locationEnabled;

  final bool geofenceActive;
  final String? geofenceError;
  final bool isInside;

  final double? officeLat;
  final double? officeLng;

  /// An entry or exit that is still inside its confirmation window.
  final PendingTransition? pending;

  final String? motion;
  final DateTime? motionSince;

  final AttendanceSettings settings;

  /// iOS has no battery optimisation setting to ask for.
  final bool isIos;

  /// Today's check-in when motion suggests an earlier arrival and no
  /// correction was requested yet.
  final ArrivalSuggestion? suggestion;

  bool get hasOffice => officeLat != null && officeLng != null;

  /// Everything automatic check-in needs is in place.
  bool get readyForAutomatic =>
      locationPermission &&
      backgroundLocationPermission &&
      locationEnabled &&
      hasOffice;

  factory NativeState.fromMap(Map<String, dynamic> map) {
    final permissions = _map(map['permissions']);
    final office = _map(map['office']);
    final pending = _map(map['pending']);
    final motion = _map(map['motion']);

    return NativeState(
      locationPermission: permissions['location'] == true,
      backgroundLocationPermission: permissions['backgroundLocation'] == true,
      activityPermission: permissions['activity'] == true,
      notificationsPermission: permissions['notifications'] == true,
      batteryUnrestricted: permissions['batteryUnrestricted'] == true,
      locationEnabled: map['locationEnabled'] == true,
      geofenceActive: map['geofenceActive'] == true,
      geofenceError: map['geofenceError'] as String?,
      isInside: map['presence'] == 'inside',
      officeLat: (office['lat'] as num?)?.toDouble(),
      officeLng: (office['lng'] as num?)?.toDouble(),
      pending: pending.isEmpty ? null : PendingTransition.fromMap(pending),
      motion: motion['type'] as String?,
      motionSince: _date(motion['ts']),
      settings: AttendanceSettings.fromMap(_map(map['settings'])),
      isIos: map['platform'] == 'ios',
      suggestion: ArrivalSuggestion.fromMap(_map(map['suggestion'])),
    );
  }
}

class ArrivalSuggestion {
  const ArrivalSuggestion({
    required this.eventId,
    required this.recorded,
    required this.estimated,
  });

  final String eventId;
  final DateTime recorded;
  final DateTime estimated;

  static ArrivalSuggestion? fromMap(Map<String, dynamic> map) {
    final id = map['eventId'];
    final recorded = _date(map['ts']);
    final estimated = _date(map['estimatedTs']);
    if (id is! String || recorded == null || estimated == null) return null;
    return ArrivalSuggestion(eventId: id, recorded: recorded, estimated: estimated);
  }
}

class PendingTransition {
  const PendingTransition({
    required this.isEnter,
    required this.detectedAt,
    required this.confirmAt,
  });

  final bool isEnter;
  final DateTime detectedAt;
  final DateTime confirmAt;

  factory PendingTransition.fromMap(Map<String, dynamic> map) =>
      PendingTransition(
        isEnter: map['type'] == 'ENTER',
        detectedAt: _date(map['ts']) ?? DateTime.now(),
        confirmAt: _date(map['confirmAt']) ?? DateTime.now(),
      );
}

class AttendanceSettings {
  const AttendanceSettings({
    this.confirmSeconds = 300,
    this.breakMinutes = 60,
    this.radiusMeters = 150,
    this.reminderHour = 12,
    this.reminderMinute = 0,
    this.motionFastConfirm = true,
    this.eventNotifications = true,
    this.arrivalNudge = true,
    this.workdays = const [1, 2, 3, 4, 5],
  });

  /// How long someone must stay inside or outside before it counts.
  final int confirmSeconds;

  /// Away for less than this is a break. Longer is a check-out.
  final int breakMinutes;
  final int radiusMeters;
  final int reminderHour;
  final int reminderMinute;
  final bool motionFastConfirm;
  final bool eventNotifications;

  /// Android only: a nudge to turn Location on when motion shows an arrival.
  final bool arrivalNudge;

  /// Weekdays as 1 = Sunday … 7 = Saturday.
  final List<int> workdays;

  Duration get breakLimit => Duration(minutes: breakMinutes);

  factory AttendanceSettings.fromMap(Map<String, dynamic> map) =>
      AttendanceSettings(
        confirmSeconds: (map['confirmSeconds'] as num?)?.toInt() ?? 300,
        breakMinutes: (map['breakMinutes'] as num?)?.toInt() ?? 60,
        radiusMeters: (map['radiusMeters'] as num?)?.toInt() ?? 150,
        reminderHour: (map['reminderHour'] as num?)?.toInt() ?? 12,
        reminderMinute: (map['reminderMinute'] as num?)?.toInt() ?? 0,
        motionFastConfirm: map['motionFastConfirm'] != false,
        eventNotifications: map['eventNotifications'] != false,
        arrivalNudge: map['arrivalNudge'] != false,
        workdays: map['workdays'] is List
            ? [
                for (final d in map['workdays'] as List)
                  if (d is num) d.toInt(),
              ]
            : const [1, 2, 3, 4, 5],
      );
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

DateTime? _date(Object? value) =>
    value is num ? DateTime.fromMillisecondsSinceEpoch(value.toInt()) : null;
