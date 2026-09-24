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

if let i = CommandLine.arguments.firstIndex(of: "--hl-test"), i + 1 < CommandLine.arguments.count {
    // Debug: Pendrix --hl-test path/to/file → how many lines got colour, per detected language.
    let path = CommandLine.arguments[i + 1]
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let patch = "@@ -1,\(text.split(separator: "\n").count) +1,\(text.split(separator: "\n").count) @@\n" + text.split(separator: "\n", omittingEmptySubsequences: false).map { " " + $0 }.joined(separator: "\n")
    let hunks = DiffParser.parse(patch)
    let f = FileDiff(oldPath: path, newPath: path, status: .modified, hunks: hunks, additions: 0, deletions: 0, binary: false)
    Task {
        let t0 = Date()
        let out = await Highlighting.shared.lines(for: f, dark: true)
        let total = hunks.flatMap(\.lines).count
        print("lang=\(Highlighting.language(for: path) ?? "nil") lines=\(total) colored=\(out.count) in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        // per line: number of distinct foreground colours (1 = plain)
        for l in hunks.flatMap(\.lines) where l.kind != .meta {
            guard let a = out[l.id] else { continue }
            var colors = Set<String>()
            for run in a.runs { if let c = run.appKit.foregroundColor { colors.insert(c.description) } }
            print(String(format: "%2d colours | %@", colors.count, l.text))
        }
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.contains("--ai-test") {
    // Debug: run the AI review pass on the demo change through the claude CLI and print the drafts.
    Task { @MainActor in
        do {
            let r = try await AIReviewer.review(Hub.demoDetail())
            print("summary:", r.summary)
            for d in r.drafts { print("- [\(d.severity.rawValue)] \(d.path ?? "-"):\(d.anchor?.newLine ?? d.anchor?.oldLine ?? 0) \(d.title)\n    \(d.body.prefix(160))") }
            print("skipped:", r.skipped)
        } catch { print("ERROR:", error.localizedDescription) }
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
