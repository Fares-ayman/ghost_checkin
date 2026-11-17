import CoreLocation
import Foundation

// Shared constants and local storage for the attendance feature.

let attTypeEnter = "ENTER"
let attTypeExit = "EXIT"
let attStatusPending = "pending"
let attStatusConfirmed = "confirmed"
let attStatusDiscarded = "discarded"
let attPresenceInside = "inside"
let attPresenceOutside = "outside"
let attSourceGeofence = "geofence"
let attSourceInitial = "initial"
let attSourceManual = "manual"
let attRegionId = "office"

func attMillis(_ date: Date) -> Int64 {
  return Int64(date.timeIntervalSince1970 * 1000)
}

func attDate(_ value: Any?) -> Date? {
  guard let number = value as? NSNumber else { return nil }
  return Date(timeIntervalSince1970: TimeInterval(number.int64Value) / 1000)
}

func attTime(_ date: Date) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.dateFormat = "HH:mm"
  return formatter.string(from: date)
}

/// Local storage. Events are kept as plain dictionaries, which is also the
/// payload that would be posted to the attendance API.
final class AttendanceStore {
  static let shared = AttendanceStore()

  private let defaults = UserDefaults.standard
  private let maxEvents = 500

  private func int(_ key: String, _ fallback: Int) -> Int {
    return defaults.object(forKey: key) as? Int ?? fallback
  }

  private func bool(_ key: String, _ fallback: Bool) -> Bool {
    return defaults.object(forKey: key) as? Bool ?? fallback
  }

  var confirmSeconds: Int {
    get { return int("confirm_seconds", 300) }
    set { defaults.set(min(max(newValue, 5), 3600), forKey: "confirm_seconds") }
  }

  var breakMinutes: Int {
    get { return int("break_minutes", 60) }
    set { defaults.set(min(max(newValue, 1), 600), forKey: "break_minutes") }
  }

  var radiusMeters: Int {
    get { return int("radius_m", 150) }
    set { defaults.set(min(max(newValue, 50), 2000), forKey: "radius_m") }
  }

  var reminderHour: Int {
    get { return int("reminder_hour", 12) }
    set { defaults.set(min(max(newValue, 0), 23), forKey: "reminder_hour") }
  }

  var reminderMinute: Int {
    get { return int("reminder_minute", 0) }
    set { defaults.set(min(max(newValue, 0), 59), forKey: "reminder_minute") }
  }

  var motionFastConfirm: Bool {
    get { return bool("motion_fast_confirm", true) }
    set { defaults.set(newValue, forKey: "motion_fast_confirm") }
  }

  var eventNotifications: Bool {
    get { return bool("event_notifications", true) }
    set { defaults.set(newValue, forKey: "event_notifications") }
  }

  /// Stored for parity with Android. iOS cannot run the arrival nudge while
  /// the app is closed, because motion does not wake the app.
  var arrivalNudge: Bool {
    get { return bool("arrival_nudge", true) }
    set { defaults.set(newValue, forKey: "arrival_nudge") }
  }

  /// Work days as Calendar weekday values (Sunday = 1). Default Sunday to Thursday.
  var workdays: [Int] {
    get { return defaults.array(forKey: "workdays") as? [Int] ?? [1, 2, 3, 4, 5] }
    set {
      let days = Array(Set(newValue.filter { (1...7).contains($0) })).sorted()
      if !days.isEmpty { defaults.set(days, forKey: "workdays") }
    }
  }

  func isWorkday(_ date: Date) -> Bool {
    return workdays.contains(Calendar.current.component(.weekday, from: date))
  }

  var office: CLLocationCoordinate2D? {
    get {
      guard let lat = defaults.object(forKey: "office_lat") as? Double,
        let lng = defaults.object(forKey: "office_lng") as? Double
      else { return nil }
      return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
    set {
      if let value = newValue {
        defaults.set(value.latitude, forKey: "office_lat")
        defaults.set(value.longitude, forKey: "office_lng")
      } else {
        defaults.removeObject(forKey: "office_lat")
        defaults.removeObject(forKey: "office_lng")
      }
    }
  }

  var presence: String {
    get { return defaults.string(forKey: "presence") ?? attPresenceOutside }
    set { defaults.set(newValue, forKey: "presence") }
  }

  var geofenceError: String? {
    get { return defaults.string(forKey: "geofence_error") }
    set {
      if let value = newValue {
        defaults.set(value, forKey: "geofence_error")
      } else {
        defaults.removeObject(forKey: "geofence_error")
      }
    }
  }

  var pendingId: String? {
    get { return defaults.string(forKey: "pending_id") }
    set {
      if let value = newValue {
        defaults.set(value, forKey: "pending_id")
      } else {
        defaults.removeObject(forKey: "pending_id")
      }
    }
  }

  var events: [[String: Any]] {
    get { return defaults.array(forKey: "events") as? [[String: Any]] ?? [] }
    set { defaults.set(Array(newValue.suffix(maxEvents)), forKey: "events") }
  }

  func addEvent(_ event: [String: Any]) {
    var all = events
    all.append(event)
    events = all
  }

  func updateEvent(id: String, change: (inout [String: Any]) -> Void) {
    var all = events
    guard let index = all.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
    change(&all[index])
    events = all
  }

  /// The event that is still inside its confirmation window, if any.
  func pendingEvent() -> [String: Any]? {
    guard let id = pendingId else { return nil }
    let match = events.first { ($0["id"] as? String) == id }
    guard let event = match, (event["status"] as? String) == attStatusPending else {
      pendingId = nil
      return nil
    }
    return event
  }

  /// A confirmed or still-pending entry today. Either one cancels the reminder.
  func hasEnterToday() -> Bool {
    let start = Calendar.current.startOfDay(for: Date())
    return events.contains { event in
      guard (event["type"] as? String) == attTypeEnter,
        (event["status"] as? String) != attStatusDiscarded,
        let time = attDate(event["ts"])
      else { return false }
      return time >= start
    }
  }

  var corrections: [[String: Any]] {
    get { return defaults.array(forKey: "corrections") as? [[String: Any]] ?? [] }
    set { defaults.set(newValue, forKey: "corrections") }
  }

  /// One request per event. A new request replaces the previous one.
  func requestCorrection(eventId: String, requestedTs: Int64, reason: String) {
    var all = corrections.filter { ($0["eventId"] as? String) != eventId }
    all.append([
      "eventId": eventId,
      "requestedTs": requestedTs,
      "reason": reason,
      "status": "pending",
      "createdAt": attMillis(Date()),
    ])
    corrections = all
  }

  /// In the demo the manager's decision is made on the same phone.
  func resolveCorrection(eventId: String, approved: Bool) {
    var all = corrections
    for index in all.indices where (all[index]["eventId"] as? String) == eventId {
      all[index]["status"] = approved ? "approved" : "rejected"
      all[index]["resolvedAt"] = attMillis(Date())
    }
    corrections = all
  }

  func hasCorrection(eventId: String) -> Bool {
    return corrections.contains { ($0["eventId"] as? String) == eventId }
  }

  /// Today's check-in when motion suggests an earlier arrival and no
  /// correction has been requested for it yet.
  func arrivalSuggestion() -> [String: Any]? {
    let start = Calendar.current.startOfDay(for: Date())
    let first = events.first { event in
      guard (event["type"] as? String) == attTypeEnter,
        (event["status"] as? String) == attStatusConfirmed,
        let time = attDate(event["ts"])
      else { return false }
      return time >= start
    }
    guard let event = first, let id = event["id"] as? String,
      let time = attDate(event["ts"]), let estimated = attDate(event["estimatedTs"]),
      time.timeIntervalSince(estimated) >= 5 * 60, !hasCorrection(eventId: id)
    else { return nil }
    return event
  }

  /// Clears events. Settings and the office are kept.
  func clearData() {
    defaults.removeObject(forKey: "events")
    defaults.removeObject(forKey: "corrections")
    defaults.removeObject(forKey: "pending_id")
    presence = attPresenceOutside
  }
}
