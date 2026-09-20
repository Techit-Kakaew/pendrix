import SwiftUI
import UserNotifications
import AppKit

struct PendrixApp: App {
    @StateObject private var hub = Hub()
    @StateObject private var config = Config.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Pendrix", id: "main") {
            RootView().environmentObject(hub).environmentObject(config)
        }
        .defaultSize(width: 1100, height: 720)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarView().environmentObject(hub).environmentObject(config)
        } label: {
            HStack(spacing: 4) {
                Image(nsImage: MenuBarIcon.image).renderingMode(.template)
                if hub.attentionCount > 0 {
                    Text("\(hub.attentionCount)").font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(hub).environmentObject(config)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    /// Closing the window keeps the app alive in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static var openChange: ((ChangeRef) -> Void)?
    static var openStandup: (() -> Void)?
    static var installUpdate: (() -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if response.notification.request.identifier == UpdateChecker.notificationId, let install = Self.installUpdate {
            await MainActor.run { install() }
        } else if info["standup"] != nil, let open = Self.openStandup {
            await MainActor.run { open(); NSApp.activate(ignoringOtherApps: true) }
        } else if let raw = info["change"] as? String, let ref = try? JSONDecoder().decode(ChangeRef.self, from: Data(raw.utf8)), let open = Self.openChange {
            await MainActor.run { open(ref); NSApp.activate(ignoringOtherApps: true) }
        } else if let s = info["url"] as? String, let u = URL(string: s) {
            await MainActor.run { NSWorkspace.shared.open(u) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
