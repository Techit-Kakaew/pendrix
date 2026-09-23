import Foundation
import SwiftUI
import AppKit
import UserNotifications

/// Debug: render the dashboard or menu panel with demo data to a PNG. No credentials or window needed.
///   Pendrix --snapshot out.png            dashboard
///   Pendrix --snapshot out.png --menu     menu-bar panel
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    Keychain.disabled = true
    let menu = CommandLine.arguments.contains("--menu")
    let review = CommandLine.arguments.contains("--review")
    let standup = CommandLine.arguments.contains("--standup")
    let light = CommandLine.arguments.contains("--light")
    Task { @MainActor in
        let hub = Hub(demo: true)
        let bg = light ? Color(red: 0.90, green: 0.91, blue: 0.94) : Color(red: 0.10, green: 0.10, blue: 0.13)
        if standup { await hub.buildStandup() }
        let view: AnyView = standup
            ? AnyView(StandupView().environmentObject(hub).environmentObject(Config.shared).frame(width: 620))
            : review
            ? AnyView(ReviewView(model: ReviewModel(demo: Hub.demoDetail())).environmentObject(hub).environmentObject(Config.shared).frame(width: 1180, height: 760))
            : menu
            ? AnyView(MenuBarView().environmentObject(hub).environmentObject(Config.shared))
            : AnyView(DashboardView().environmentObject(hub).environmentObject(Config.shared).frame(width: 960))
        let r = ImageRenderer(content: view.background(bg)
            .environment(\.colorScheme, light ? .light : .dark).environment(\.isSnapshot, true))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: out); print("wrote \(out.path)")
        } else { print("render failed") }
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--notify-test") {
    // Run from the installed bundle: dist/Pendrix.app/Contents/MacOS/Pendrix --notify-test
    import_notify_test()
    RunLoop.main.run()
}

PendrixApp.main()

func import_notify_test() {
    Task { @MainActor in
        let c = UNUserNotificationCenter.current()
        let granted = try? await c.requestAuthorization(options: [.alert, .sound, .badge])
        let st = await c.notificationSettings()
        print("bundle: \(Bundle.main.bundleIdentifier ?? "none")  granted: \(granted ?? false)  auth: \(st.authorizationStatus.rawValue) (0 notDetermined 1 denied 2 authorized)  alerts: \(st.alertSetting.rawValue)")
        let n = UNMutableNotificationContent(); n.title = "Pendrix test"; n.body = "Notifications work."; n.sound = .default
        try? await c.add(UNNotificationRequest(identifier: "test", content: n, trigger: nil))
        print("sent")
        try? await Task.sleep(for: .seconds(1)); exit(0)
    }
}
