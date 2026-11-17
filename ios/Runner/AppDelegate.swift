import Flutter
import UIKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      AttendanceBridge.shared.attach(messenger: controller.binaryMessenger)
    }
    AttendanceBridge.shared.start(launchedForLocation: launchOptions?[.location] != nil)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
