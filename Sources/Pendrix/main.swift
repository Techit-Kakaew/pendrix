import Foundation
import SwiftUI
import AppKit

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

PendrixApp.main()
