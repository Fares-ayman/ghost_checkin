/// One "entered" or "left" signal recorded by the native side.
///
/// Confirmed events are exactly what would be posted to the attendance API.
class AttendanceEvent {
  const AttendanceEvent({
    required this.id,
    required this.type,
    required this.time,
    required this.source,
    required this.status,
    this.estimatedTime,
    this.originalTime,
    this.detectedTime,
    this.confirmedAt,
    this.motion,
    this.note = '',
  });

  static const typeEnter = 'ENTER';
  static const typeExit = 'EXIT';

  final String id;
  final String type;

  /// When the signal was detected. This is the recorded attendance time.
  final DateTime time;

  /// For late detections: when motion history suggests the person arrived.
  final DateTime? estimatedTime;
  final DateTime? confirmedAt;

  /// Set when an approved correction replaced [time]: the detected time.
  final DateTime? originalTime;

  /// For a late detection set back to when the phone stopped moving: when
  /// the phone was actually found inside.
  final DateTime? detectedTime;

  /// geofence, initial (found inside when monitoring started) or manual.
  final String source;

  /// pending, confirmed or discarded.
  final String status;
  final String? motion;
  final String note;

  bool get isEnter => type == typeEnter;
  bool get isConfirmed => status == 'confirmed';
  bool get isPending => status == 'pending';
  bool get isDiscarded => status == 'discarded';

  factory AttendanceEvent.fromJson(Map<String, dynamic> json) {
    DateTime? date(Object? value) => value is num
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : null;

    final motion = json['motion'];
    return AttendanceEvent(
      id: '${json['id'] ?? ''}',
      type: '${json['type'] ?? typeEnter}',
      time: date(json['ts']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      estimatedTime: date(json['estimatedTs']),
      detectedTime: date(json['detectedTs']),
      confirmedAt: date(json['confirmedAt']),
      source: '${json['source'] ?? 'geofence'}',
      status: '${json['status'] ?? 'pending'}',
      motion: motion is String && motion.isNotEmpty ? motion : null,
      note: '${json['note'] ?? ''}',
    );
  }

  /// The same event with [time] replaced by an approved correction.
  AttendanceEvent withCorrectedTime(DateTime corrected) => AttendanceEvent(
        id: id,
        type: type,
        time: corrected,
        originalTime: time,
        detectedTime: detectedTime,
        estimatedTime: estimatedTime,
        confirmedAt: confirmedAt,
        source: source,
        status: status,
        motion: motion,
        note: note,
      );

  /// The shape the attendance API would receive. Coordinates are never sent.
  /// The timestamp is always the detected one; corrections travel separately.
  Map<String, dynamic> toApiJson() => {
        'id': id,
        'type': type,
        'timestamp': (originalTime ?? time).toUtc().toIso8601String(),
        'source': source,
        if (motion != null) 'motion': motion,
        if (estimatedTime != null)
          'estimated_timestamp': estimatedTime!.toUtc().toIso8601String(),
        if (detectedTime != null)
          'detected_timestamp': detectedTime!.toUtc().toIso8601String(),
        if (note.isNotEmpty) 'note': note,
      };
}

/// An employee's request to change the recorded time of one event. It needs
/// the manager's approval before it affects the timeline.
class CorrectionRequest {
  const CorrectionRequest({
    required this.eventId,
    required this.requestedTime,
    required this.reason,
    required this.status,
    required this.createdAt,
  });

  final String eventId;
  final DateTime requestedTime;
  final String reason;

  /// pending, approved or rejected.
  final String status;
  final DateTime createdAt;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  factory CorrectionRequest.fromJson(Map<String, dynamic> json) {
    DateTime date(Object? value) => DateTime.fromMillisecondsSinceEpoch(
          value is num ? value.toInt() : 0,
        );
    return CorrectionRequest(
      eventId: '${json['eventId'] ?? ''}',
      requestedTime: date(json['requestedTs']),
      reason: '${json['reason'] ?? ''}',
      status: '${json['status'] ?? 'pending'}',
      createdAt: date(json['createdAt']),
    );
  }

  Map<String, dynamic> toApiJson() => {
        'event_id': eventId,
        'requested_timestamp': requestedTime.toUtc().toIso8601String(),
        if (reason.isNotEmpty) 'reason': reason,
        'status': status,
      };
}

/// One motion change reported by the phone (walking, in a vehicle, still).
class MotionEntry {
  const MotionEntry({
    required this.type,
    required this.transition,
    required this.time,
  });

  final String type;

  /// enter or exit.
  final String transition;
  final DateTime time;

  factory MotionEntry.fromJson(Map<String, dynamic> json) {
    final ts = json['ts'];
    return MotionEntry(
      type: '${json['type'] ?? 'unknown'}',
      transition: '${json['transition'] ?? 'enter'}',
      time: DateTime.fromMillisecondsSinceEpoch(ts is num ? ts.toInt() : 0),
    );
  }
}
