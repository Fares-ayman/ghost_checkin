const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _two(int value) => value.toString().padLeft(2, '0');

/// 9:05 AM
String formatTime(DateTime time) {
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  return '$hour:${_two(time.minute)} ${time.hour < 12 ? 'AM' : 'PM'}';
}

/// 9:05:42 AM, for the raw event list.
String formatTimeWithSeconds(DateTime time) {
  final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
  return '$hour:${_two(time.minute)}:${_two(time.second)} '
      '${time.hour < 12 ? 'AM' : 'PM'}';
}

/// Sun, 15 Nov 2026
String formatDay(DateTime day) =>
    '${_weekdays[day.weekday - 1]}, ${day.day} ${_months[day.month - 1]} '
    '${day.year}';

/// 45s, 12 min, 1h 05m
String formatDuration(Duration duration) {
  if (duration.inSeconds < 60) return '${duration.inSeconds}s';
  if (duration.inMinutes < 60) return '${duration.inMinutes} min';
  return '${duration.inHours}h ${_two(duration.inMinutes % 60)}m';
}

/// 4:59 countdown.
String formatCountdown(Duration duration) {
  final safe = duration.isNegative ? Duration.zero : duration;
  return '${safe.inMinutes}:${_two(safe.inSeconds % 60)}';
}

String motionLabel(String? motion) {
  switch (motion) {
    case 'in_vehicle':
      return 'In a vehicle';
    case 'on_bicycle':
      return 'On a bicycle';
    case 'walking':
      return 'Walking';
    case 'running':
      return 'Running';
    case 'still':
      return 'Still';
    default:
      return 'Unknown';
  }
}

String sourceLabel(String source) {
  switch (source) {
    case 'geofence':
      return 'Geofence';
    case 'initial':
      return 'Late detection';
    case 'manual':
      return 'Manual';
    case 'motion':
      return 'Estimated from motion';
    default:
      return source;
  }
}
