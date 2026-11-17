import CoreLocation
import CoreMotion
import Flutter
import UIKit
import UserNotifications

// Geofence, motion, reminders and the method channel for the attendance
// feature. The Flutter UI talks to this through "attendance/native".
//
// How it differs from Android: iOS cannot run code at a set time while the app
// is closed. So a pending entry or exit is confirmed lazily: if no opposite
// signal arrived before its confirmation window ended, it counts as confirmed
// the next time the app wakes up. The recorded time is still the time of the
// original signal.

final class AttendanceBridge: NSObject, CLLocationManagerDelegate {
  static let shared = AttendanceBridge()

  private let store = AttendanceStore.shared
  private let locationManager = CLLocationManager()
  private let motionManager = CMMotionActivityManager()
  private var channel: FlutterMethodChannel?
  private var started = false

  private var awaitingInitialState = false
  private var pendingPermissionResult: FlutterResult?
  private var sawResignActive = false
  private var pendingOfficeResult: FlutterResult?

  private var notificationsAllowed = false
  private var locationServicesOn = true
  private var currentMotion: String?
  private var currentMotionSince: Date?

  // MARK: Start-up

  /// Call from application(_:didFinishLaunchingWithOptions:). The location
  /// manager must exist at launch, because iOS relaunches the app in the
  /// background to deliver region events.
  func start(launchedForLocation: Bool) {
    guard !started else { return }
    started = true
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest

    NotificationCenter.default.addObserver(
      self, selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)

    refreshCachedStatus()
    // When iOS launched the app for a region event, that event is on its way.
    // Asking for the state as well would label it a late detection.
    ensureMonitoring(requestState: !launchedForLocation)
  }

  func attach(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "attendance/native", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result)
    }
    self.channel = channel
  }

  @objc private func appWillResignActive() {
    sawResignActive = true
  }

  @objc private func appDidBecomeActive() {
    refreshCachedStatus()
    reconcile()
    if pendingPermissionResult != nil && sawResignActive {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.finishPermissionRequest()
      }
    }
  }

  private func refreshCachedStatus() {
    UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
      let allowed =
        settings.authorizationStatus == .authorized
        || settings.authorizationStatus == .provisional
      DispatchQueue.main.async { self?.notificationsAllowed = allowed }
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let enabled = CLLocationManager.locationServicesEnabled()
      DispatchQueue.main.async { self?.locationServicesOn = enabled }
    }
  }

  private func authorizationStatus() -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) {
      return locationManager.authorizationStatus
    }
    return CLLocationManager.authorizationStatus()
  }

  private var hasLocationPermission: Bool {
    let status = authorizationStatus()
    return status == .authorizedWhenInUse || status == .authorizedAlways
  }

  private var hasAlwaysPermission: Bool {
    return authorizationStatus() == .authorizedAlways
  }

  private var hasMotionPermission: Bool {
    return CMMotionActivityManager.authorizationStatus() == .authorized
  }

  private var geofenceActive: Bool {
    return hasAlwaysPermission
      && locationManager.monitoredRegions.contains { $0.identifier == attRegionId }
  }

  // MARK: Monitoring

  /// Registers the office region and the reminders. Safe to call often.
  func ensureMonitoring(requestState: Bool) {
    reconcile()
    rolloverDay()
    scheduleReminders()

    guard let office = store.office else {
      store.geofenceError = "Office location is not set."
      return
    }
    guard hasAlwaysPermission else {
      store.geofenceError = "Location permission must be \"Always\"."
      return
    }
    if #available(iOS 14.0, *), locationManager.accuracyAuthorization != .fullAccuracy {
      store.geofenceError = "Precise Location is turned off for this app."
      return
    }
    guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
      store.geofenceError = "This device cannot monitor regions."
      return
    }

    let radius = min(Double(store.radiusMeters), locationManager.maximumRegionMonitoringDistance)
    let region = CLCircularRegion(center: office, radius: radius, identifier: attRegionId)
    region.notifyOnEntry = true
    region.notifyOnExit = true
    locationManager.startMonitoring(for: region)
    store.geofenceError = nil

    if requestState {
      // Reports where the phone is right now, which covers "already at the
      // office when monitoring started".
      awaitingInitialState = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.locationManager.requestState(for: region)
      }
    }
  }

  func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    guard region.identifier == attRegionId else { return }
    handleSignal(type: attTypeEnter, source: attSourceGeofence)
  }

  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    guard region.identifier == attRegionId else { return }
    handleSignal(type: attTypeExit, source: attSourceGeofence)
  }

  func locationManager(
    _ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion
  ) {
    // iOS also calls this on every boundary crossing. Only the answer to our
    // own requestState is used here.
    guard region.identifier == attRegionId, awaitingInitialState else { return }
    awaitingInitialState = false
    switch state {
    case .inside:
      handleSignal(type: attTypeEnter, source: attSourceInitial)
    case .outside:
      handleSignal(type: attTypeExit, source: attSourceInitial)
    default:
      break
    }
  }

  func locationManager(
    _ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error
  ) {
    store.geofenceError = error.localizedDescription
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    ensureMonitoring(requestState: true)
  }

  func locationManager(
    _ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus
  ) {
    if #available(iOS 14.0, *) { return }
    ensureMonitoring(requestState: true)
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let result = pendingOfficeResult, let location = locations.last else { return }
    pendingOfficeResult = nil
    store.office = location.coordinate
    ensureMonitoring(requestState: true)
    var state = buildState()
    state["accuracy"] = location.horizontalAccuracy
    result(state)
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard let result = pendingOfficeResult else { return }
    pendingOfficeResult = nil
    result(
      FlutterError(code: "location_failed", message: error.localizedDescription, details: nil))
  }

  // MARK: Engine

  /// Keeps the app alive long enough to store the event and read motion.
  private func handleSignal(type: String, source: String) {
    var task: UIBackgroundTaskIdentifier = .invalid
    let finish = {
      if task != .invalid {
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
      }
    }
    task = UIApplication.shared.beginBackgroundTask(expirationHandler: finish)
    onTransition(type: type, source: source, completion: finish)
  }

  private func onTransition(type: String, source: String, completion: @escaping () -> Void) {
    reconcile()
    rolloverDay()

    let now = Date()
    let manual = source == attSourceManual

    if let pending = store.pendingEvent() {
      let pendingId = pending["id"] as? String ?? ""
      if (pending["type"] as? String) == type {
        // Same signal again. A manual action confirms it right away.
        if manual { confirm(id: pendingId, at: now, notifyNow: true) }
        completion()
        return
      }
      let reason =
        type == attTypeExit
        ? "Left again before the confirmation window ended (passing by)."
        : "Came back before the confirmation window ended (brief exit ignored)."
      store.updateEvent(id: pendingId) { event in
        event["status"] = attStatusDiscarded
        event["note"] = self.joinNotes(event["note"] as? String ?? "", reason)
      }
      store.pendingId = nil
      cancelEventNotification(id: pendingId)
      scheduleReminders()
      completion()
      return
    }

    let resulting = type == attTypeEnter ? attPresenceInside : attPresenceOutside
    if resulting == store.presence {
      completion()
      return
    }

    let id = UUID().uuidString
    var notes: [String] = []
    if manual { notes.append("Recorded manually.") }
    if source == attSourceInitial && type == attTypeEnter {
      notes.append("Detected when monitoring (re)started, so the real arrival may be earlier.")
    }
    if source == attSourceInitial && type == attTypeExit {
      notes.append("Detected when monitoring (re)started, so the real departure may be earlier.")
    }
    let lastConfirmed = store.events.last { ($0["status"] as? String) == attStatusConfirmed }
    let sessionStart = attDate(lastConfirmed?["ts"]) ?? .distantPast

    // The wait always runs from when the signal arrived, even when the
    // recorded time ends up earlier.
    let confirmAt = now.addingTimeInterval(TimeInterval(store.confirmSeconds))
    let event: [String: Any] = [
      "id": id,
      "type": type,
      "ts": attMillis(now),
      "confirmAfter": attMillis(confirmAt),
      "source": source,
      "status": attStatusPending,
      "synced": false,
      "note": notes.joined(separator: " "),
    ]
    store.addEvent(event)
    store.pendingId = id

    if manual {
      confirm(id: id, at: now, notifyNow: true)
      completion()
      return
    }

    // The app will most likely be suspended when the window ends, so the
    // notification is scheduled now and removed if the event is discarded.
    scheduleEventNotification(id: id, type: type, eventTime: now, fireAt: confirmAt)
    if type == attTypeEnter { scheduleReminders() }

    let startOfDay = Calendar.current.startOfDay(for: now)
    let from = source == attSourceInitial ? startOfDay : now.addingTimeInterval(-45 * 60)
    queryMotion(from: from) { [weak self] activities in
      guard let self = self, self.store.pendingId == id else {
        completion()
        return
      }
      let summary = self.summarize(activities)
      self.currentMotion = summary.current
      self.currentMotionSince = summary.since

      // Found inside the office: if the phone has not moved since it last
      // stopped, it has been in the office since then. That time is recorded.
      // Anything earlier stays a suggestion for the manager.
      let floor = max(startOfDay, sessionStart)
      var recorded = now
      var vehicleEstimate: Date?
      if source == attSourceInitial, type == attTypeEnter {
        if summary.current == "still", let still = summary.since, still > floor,
          now.timeIntervalSince(still) >= 5 * 60
        {
          recorded = still
        }
        if let vehicleEnd = summary.lastVehicleEnd, vehicleEnd > floor,
          recorded.timeIntervalSince(vehicleEnd) >= 5 * 60
        {
          vehicleEstimate = vehicleEnd
        }
      }

      self.store.updateEvent(id: id) { event in
        if let motion = summary.current { event["motion"] = motion }
        if recorded != now {
          event["ts"] = attMillis(recorded)
          event["detectedTs"] = attMillis(now)
          event["note"] = self.joinNotes(
            event["note"] as? String ?? "",
            "Found inside at \(attTime(now)). The phone had not moved since "
              + "\(attTime(recorded)), so the check-in is set to \(attTime(recorded)).")
        }
        if let vehicleEnd = vehicleEstimate {
          event["estimatedTs"] = attMillis(vehicleEnd)
          event["note"] = self.joinNotes(
            event["note"] as? String ?? "",
            "Motion history suggests arrival around \(attTime(vehicleEnd)).")
        }
        if source == attSourceInitial, type == attTypeExit,
          let vehicleStart = summary.lastVehicleStart, vehicleStart >= sessionStart
        {
          event["estimatedTs"] = attMillis(vehicleStart)
          event["note"] = self.joinNotes(
            event["note"] as? String ?? "",
            "Motion history suggests leaving around \(attTime(vehicleStart)).")
        }
      }

      if recorded != now || vehicleEstimate != nil {
        // Same notification id: replaces the one scheduled above.
        self.scheduleEventNotification(
          id: id, type: type, eventTime: recorded, fireAt: confirmAt, estimated: vehicleEstimate)
      }

      let onFoot = summary.current == "walking" || summary.current == "running"
      let justStopped =
        summary.current == "still"
        && Date().timeIntervalSince(summary.since ?? .distantPast) <= 10 * 60
      if type == attTypeEnter, source == attSourceGeofence, self.store.motionFastConfirm,
        onFoot || justStopped
      {
        self.store.updateEvent(id: id) { event in
          event["note"] = self.joinNotes(
            event["note"] as? String ?? "",
            "Confirmed immediately: motion sensor reports \(summary.current ?? "on foot").")
        }
        self.confirm(id: id, at: Date(), notifyNow: true)
      }
      completion()
    }
  }

  private func joinNotes(_ existing: String, _ extra: String) -> String {
    return existing.isEmpty ? extra : "\(existing) \(extra)"
  }

  private func confirm(id: String, at date: Date, notifyNow: Bool) {
    guard let pending = store.pendingEvent(), (pending["id"] as? String) == id else { return }
    let type = pending["type"] as? String ?? attTypeEnter
    let eventTime = attDate(pending["ts"]) ?? date

    store.updateEvent(id: id) { event in
      event["status"] = attStatusConfirmed
      event["confirmedAt"] = attMillis(date)
    }
    store.pendingId = nil
    store.presence = type == attTypeEnter ? attPresenceInside : attPresenceOutside

    if notifyNow {
      scheduleEventNotification(
        id: id, type: type, eventTime: eventTime, fireAt: Date().addingTimeInterval(1),
        estimated: attDate(pending["estimatedTs"]))
    }
  }

  /// A new day starts outside. Without this, someone whose exit was never
  /// recorded would still count as "inside" the next morning, and that day's
  /// entry would be ignored.
  ///
  /// The missed exit is filled in from motion when possible: the last time
  /// that day the phone got into a vehicle after the check-in. It is stored
  /// as an estimate and can be corrected.
  private func rolloverDay() {
    guard store.presence == attPresenceInside, store.pendingEvent() == nil else { return }
    let confirmed = store.events.last { ($0["status"] as? String) == attStatusConfirmed }
    guard let last = attDate(confirmed?["ts"]) else { return }
    let calendar = Calendar.current
    guard last < calendar.startOfDay(for: Date()) else { return }
    store.presence = attPresenceOutside

    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last))
    else { return }
    queryMotion(from: last, to: nextDay.addingTimeInterval(-1)) { [weak self] activities in
      guard let self = self, let left = self.summarize(activities).lastVehicleStart else { return }
      self.store.addEvent([
        "id": UUID().uuidString,
        "type": attTypeExit,
        "ts": attMillis(left),
        "source": "motion",
        "status": attStatusConfirmed,
        "confirmedAt": attMillis(Date()),
        "motion": "in_vehicle",
        "synced": false,
        "note": "No exit was detected that day. Estimated from motion: got into a vehicle at "
          + "\(attTime(left)).",
      ])
    }
  }

  /// Confirms a pending event whose window has already passed.
  private func reconcile() {
    guard let pending = store.pendingEvent(), let id = pending["id"] as? String,
      let due = confirmDue(pending)
    else { return }
    if Date() >= due {
      confirm(id: id, at: due, notifyNow: false)
    }
  }

  private func confirmDue(_ event: [String: Any]) -> Date? {
    if let after = attDate(event["confirmAfter"]) { return after }
    return attDate(event["ts"])?.addingTimeInterval(TimeInterval(store.confirmSeconds))
  }

  // MARK: Motion

  private func queryMotion(
    from start: Date, to end: Date = Date(), completion: @escaping ([CMMotionActivity]) -> Void
  ) {
    guard CMMotionActivityManager.isActivityAvailable(), hasMotionPermission else {
      completion([])
      return
    }
    motionManager.queryActivityStarting(from: start, to: end, to: OperationQueue.main) {
      activities, _ in
      completion(activities ?? [])
    }
  }

  private func label(_ activity: CMMotionActivity) -> String? {
    if activity.automotive { return "in_vehicle" }
    if activity.cycling { return "on_bicycle" }
    if activity.running { return "running" }
    if activity.walking { return "walking" }
    if activity.stationary { return "still" }
    return nil
  }

  private func summarize(_ activities: [CMMotionActivity])
    -> (current: String?, since: Date?, lastVehicleEnd: Date?, lastVehicleStart: Date?)
  {
    var current: String?
    var since: Date?
    var lastVehicleEnd: Date?
    var lastVehicleStart: Date?
    for activity in activities {
      guard let name = label(activity), name != current else { continue }
      if current == "in_vehicle" { lastVehicleEnd = activity.startDate }
      if name == "in_vehicle" { lastVehicleStart = activity.startDate }
      current = name
      since = activity.startDate
    }
    return (current, since, lastVehicleEnd, lastVehicleStart)
  }

  /// Motion changes for the log screen, in the same shape Android stores.
  private func motionLog(_ activities: [CMMotionActivity]) -> [[String: Any]] {
    var log: [[String: Any]] = []
    var previous: String?
    for activity in activities {
      guard let name = label(activity), name != previous else { continue }
      previous = name
      log.append(["type": name, "transition": "enter", "ts": attMillis(activity.startDate)])
    }
    return log
  }

  // MARK: Notifications

  private func scheduleEventNotification(
    id: String, type: String, eventTime: Date, fireAt: Date, estimated: Date? = nil
  ) {
    guard store.eventNotifications else { return }
    let content = UNMutableNotificationContent()
    if type == attTypeEnter, let estimated = estimated,
      eventTime.timeIntervalSince(estimated) >= 5 * 60
    {
      content.title = "Entered the office"
      content.body =
        "Recorded at \(attTime(eventTime)). Motion suggests you arrived around "
        + "\(attTime(estimated)). Open the app to send the real time to your manager."
    } else if type == attTypeEnter {
      content.title = "Entered the office"
      content.body = "Recorded at \(attTime(eventTime))."
    } else {
      content.title = "Left the office"
      content.body =
        "Recorded at \(attTime(eventTime)). Counts as a break if you return within "
        + "\(store.breakMinutes) minutes."
    }
    let trigger = UNTimeIntervalNotificationTrigger(
      timeInterval: max(1, fireAt.timeIntervalSinceNow), repeats: false)
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "event-\(id)", content: content, trigger: trigger))
  }

  private func cancelEventNotification(id: String) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(
      withIdentifiers: ["event-\(id)"])
  }

  /// Schedules the daily reminder for the next week, minus today when an
  /// entry already exists. iOS shows a scheduled notification without running
  /// any code, so "remind only if not checked in" is done by removing today's
  /// reminder as soon as an entry is detected.
  private func scheduleReminders() {
    let center = UNUserNotificationCenter.current()
    let calendar = Calendar.current
    let now = Date()
    let today = calendar.startOfDay(for: now)
    let enteredToday = store.hasEnterToday()

    for offset in 0..<7 {
      guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
      var components = calendar.dateComponents([.year, .month, .day], from: day)
      components.hour = store.reminderHour
      components.minute = store.reminderMinute
      let identifier =
        "reminder-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"

      // Work days only. In the company app, also skip leave days.
      let skip = (offset == 0 && enteredToday) || !store.isWorkday(day)
      guard let fireDate = calendar.date(from: components), fireDate > now, !skip else {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        continue
      }

      let content = UNMutableNotificationContent()
      content.title = "Check-in reminder"
      content.body =
        "You have not checked in today. Turn on Location for automatic check-in, or "
        + "check in manually from the app."
      content.sound = .default
      let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
      center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
  }

  // MARK: Method channel

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "getState":
      reconcile()
      rolloverDay()
      result(buildState())

    case "getEvents":
      result(jsonString(store.events))

    case "getActivityLog":
      let startOfDay = Calendar.current.startOfDay(for: Date())
      queryMotion(from: startOfDay) { [weak self] activities in
        guard let self = self else {
          result("[]")
          return
        }
        result(self.jsonString(self.motionLog(activities)))
      }

    case "getCorrections":
      result(jsonString(store.corrections))

    case "requestCorrection":
      guard let eventId = args["eventId"] as? String,
        let requestedTs = (args["requestedTs"] as? NSNumber)?.int64Value
      else {
        result(
          FlutterError(
            code: "bad_request", message: "eventId and requestedTs are required.", details: nil))
        return
      }
      store.requestCorrection(
        eventId: eventId, requestedTs: requestedTs, reason: args["reason"] as? String ?? "")
      result(nil)

    case "resolveCorrection":
      guard let eventId = args["eventId"] as? String else {
        result(FlutterError(code: "bad_request", message: "eventId is required.", details: nil))
        return
      }
      store.resolveCorrection(eventId: eventId, approved: args["approved"] as? Bool ?? false)
      result(nil)

    case "requestPermission":
      requestPermission(args["name"] as? String ?? "", result)

    case "openAppSettings", "openLocationSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      result(nil)

    case "requestBatteryExemption":
      result(nil)

    case "setOfficeHere":
      guard hasLocationPermission else {
        result(
          FlutterError(
            code: "no_permission", message: "Location permission is missing.", details: nil))
        return
      }
      pendingOfficeResult = result
      locationManager.requestLocation()

    case "updateSettings":
      let oldRadius = store.radiusMeters
      if let value = (args["confirmSeconds"] as? NSNumber)?.intValue {
        store.confirmSeconds = value
      }
      if let value = (args["breakMinutes"] as? NSNumber)?.intValue { store.breakMinutes = value }
      if let value = (args["radiusMeters"] as? NSNumber)?.intValue { store.radiusMeters = value }
      if let value = (args["reminderHour"] as? NSNumber)?.intValue { store.reminderHour = value }
      if let value = (args["reminderMinute"] as? NSNumber)?.intValue {
        store.reminderMinute = value
      }
      if let value = args["motionFastConfirm"] as? Bool { store.motionFastConfirm = value }
      if let value = args["eventNotifications"] as? Bool { store.eventNotifications = value }
      if let value = args["arrivalNudge"] as? Bool { store.arrivalNudge = value }
      if let value = args["workdays"] as? [NSNumber] { store.workdays = value.map { $0.intValue } }
      ensureMonitoring(requestState: oldRadius != store.radiusMeters)
      result(buildState())

    case "manualTransition":
      let type = (args["type"] as? String) == attTypeExit ? attTypeExit : attTypeEnter
      onTransition(type: type, source: attSourceManual) { [weak self] in
        result(self?.buildState() ?? [:])
      }

    case "refreshMonitoring":
      ensureMonitoring(requestState: true)
      result(buildState())

    case "clearData":
      if let id = store.pendingId { cancelEventNotification(id: id) }
      store.clearData()
      ensureMonitoring(requestState: true)
      result(buildState())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value),
      let text = String(data: data, encoding: .utf8)
    else { return "[]" }
    return text
  }

  private func buildState() -> [String: Any] {
    var state: [String: Any] = [
      "platform": "ios",
      "permissions": [
        "location": hasLocationPermission,
        "backgroundLocation": hasAlwaysPermission,
        "activity": hasMotionPermission,
        "notifications": notificationsAllowed,
        "batteryUnrestricted": true,
      ] as [String: Any],
      "settings": [
        "confirmSeconds": store.confirmSeconds,
        "breakMinutes": store.breakMinutes,
        "radiusMeters": store.radiusMeters,
        "reminderHour": store.reminderHour,
        "reminderMinute": store.reminderMinute,
        "motionFastConfirm": store.motionFastConfirm,
        "eventNotifications": store.eventNotifications,
        "arrivalNudge": store.arrivalNudge,
        "workdays": store.workdays,
      ] as [String: Any],
      "locationEnabled": locationServicesOn,
      "exactAlarms": true,
      "geofenceActive": geofenceActive,
      "presence": store.presence,
    ]
    if let error = store.geofenceError { state["geofenceError"] = error }
    if let office = store.office {
      state["office"] = ["lat": office.latitude, "lng": office.longitude] as [String: Any]
    }
    if let pending = store.pendingEvent(), let time = attDate(pending["ts"]) {
      state["pending"] = [
        "type": pending["type"] as? String ?? attTypeEnter,
        "ts": attMillis(time),
        "confirmAt": attMillis(confirmDue(pending) ?? time),
      ] as [String: Any]
    }
    if let motion = currentMotion {
      var entry: [String: Any] = ["type": motion]
      if let since = currentMotionSince { entry["ts"] = attMillis(since) }
      state["motion"] = entry
    }
    if let suggestion = store.arrivalSuggestion(), let id = suggestion["id"] as? String,
      let ts = attDate(suggestion["ts"]), let estimated = attDate(suggestion["estimatedTs"])
    {
      state["suggestion"] =
        ["eventId": id, "ts": attMillis(ts), "estimatedTs": attMillis(estimated)] as [String: Any]
    }
    return state
  }

  // MARK: Permissions

  private func requestPermission(_ name: String, _ result: @escaping FlutterResult) {
    switch name {
    case "location":
      if authorizationStatus() == .notDetermined {
        awaitPermission(result)
        locationManager.requestWhenInUseAuthorization()
      } else {
        result(buildState())
      }

    case "backgroundLocation":
      // iOS only offers "Always" as an upgrade from "While Using".
      if authorizationStatus() == .authorizedWhenInUse {
        awaitPermission(result)
        locationManager.requestAlwaysAuthorization()
      } else {
        result(buildState())
      }

    case "activity":
      guard CMMotionActivityManager.isActivityAvailable() else {
        result(buildState())
        return
      }
      // The first query is what shows the Motion & Fitness prompt.
      let now = Date()
      motionManager.queryActivityStarting(
        from: now.addingTimeInterval(-60), to: now, to: OperationQueue.main
      ) { [weak self] _, _ in
        result(self?.buildState() ?? [:])
      }

    case "notifications":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
        [weak self] granted, _ in
        DispatchQueue.main.async {
          self?.notificationsAllowed = granted
          self?.scheduleReminders()
          result(self?.buildState() ?? [:])
        }
      }

    default:
      result(buildState())
    }
  }

  /// Answers the Flutter side once the system prompt has been dismissed.
  private func awaitPermission(_ result: @escaping FlutterResult) {
    pendingPermissionResult?(buildState())
    pendingPermissionResult = result
    sawResignActive = false
    // No prompt appeared (already answered before): reply without waiting.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self, !self.sawResignActive else { return }
      self.finishPermissionRequest()
    }
  }

  private func finishPermissionRequest() {
    guard let result = pendingPermissionResult else { return }
    pendingPermissionResult = nil
    ensureMonitoring(requestState: true)
    result(buildState())
  }
}
