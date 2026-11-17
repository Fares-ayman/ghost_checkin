import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/attendance_event.dart';
import '../models/native_state.dart';

/// The single bridge to the native attendance code.
///
/// Geofencing, motion, storage and alarms all live on the native side so they
/// keep working while the Flutter engine is not running.
class AttendanceChannel {
  AttendanceChannel._();

  static const _channel = MethodChannel('attendance/native');

  static Future<NativeState> _state(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    final map = await _channel.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    );
    return NativeState.fromMap(map ?? const {});
  }

  static Future<NativeState> getState() => _state('getState');

  /// [name] is location, backgroundLocation, activity or notifications.
  static Future<NativeState> requestPermission(String name) =>
      _state('requestPermission', {'name': name});

  /// Uses the phone's current position as the office and starts monitoring.
  static Future<NativeState> setOfficeHere() => _state('setOfficeHere');

  static Future<NativeState> updateSettings({
    int? confirmSeconds,
    int? breakMinutes,
    int? radiusMeters,
    int? reminderHour,
    int? reminderMinute,
    bool? motionFastConfirm,
    bool? eventNotifications,
    bool? arrivalNudge,
    List<int>? workdays,
  }) =>
      _state('updateSettings', {
        if (confirmSeconds != null) 'confirmSeconds': confirmSeconds,
        if (breakMinutes != null) 'breakMinutes': breakMinutes,
        if (radiusMeters != null) 'radiusMeters': radiusMeters,
        if (reminderHour != null) 'reminderHour': reminderHour,
        if (reminderMinute != null) 'reminderMinute': reminderMinute,
        if (motionFastConfirm != null) 'motionFastConfirm': motionFastConfirm,
        if (eventNotifications != null)
          'eventNotifications': eventNotifications,
        if (arrivalNudge != null) 'arrivalNudge': arrivalNudge,
        if (workdays != null) 'workdays': workdays,
      });

  /// The old manual flow, kept as the fallback.
  static Future<NativeState> manualTransition({required bool enter}) =>
      _state('manualTransition', {'type': enter ? 'ENTER' : 'EXIT'});

  static Future<NativeState> refreshMonitoring() => _state('refreshMonitoring');

  static Future<NativeState> clearData() => _state('clearData');

  static Future<void> openAppSettings() =>
      _channel.invokeMethod<void>('openAppSettings');

  static Future<void> openLocationSettings() =>
      _channel.invokeMethod<void>('openLocationSettings');

  static Future<void> requestBatteryExemption() =>
      _channel.invokeMethod<void>('requestBatteryExemption');

  static Future<List<AttendanceEvent>> getEvents() async {
    final raw = await _channel.invokeMethod<String>('getEvents');
    return _decodeList(raw).map(AttendanceEvent.fromJson).toList();
  }

  static Future<List<CorrectionRequest>> getCorrections() async {
    final raw = await _channel.invokeMethod<String>('getCorrections');
    return _decodeList(raw).map(CorrectionRequest.fromJson).toList();
  }

  /// Asks for the recorded time of an event to be changed.
  static Future<void> requestCorrection({
    required String eventId,
    required DateTime requestedTime,
    required String reason,
  }) =>
      _channel.invokeMethod<void>('requestCorrection', {
        'eventId': eventId,
        'requestedTs': requestedTime.millisecondsSinceEpoch,
        'reason': reason,
      });

  /// The manager's decision. In the demo it is made on the same phone.
  static Future<void> resolveCorrection({
    required String eventId,
    required bool approved,
  }) =>
      _channel.invokeMethod<void>('resolveCorrection', {
        'eventId': eventId,
        'approved': approved,
      });

  static Future<List<MotionEntry>> getMotionLog() async {
    final raw = await _channel.invokeMethod<String>('getActivityLog');
    return _decodeList(raw).map(MotionEntry.fromJson).toList();
  }

  static List<Map<String, dynamic>> _decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }
}
