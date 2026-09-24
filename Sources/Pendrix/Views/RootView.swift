import SwiftUI

/// One window. Home, review and standup slide in and out; Settings stays a system window.
struct RootView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var config: Config
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            switch hub.route {
            case .home:
                DashboardView().transition(.move(edge: .leading).combined(with: .opacity))
            case .standup:
                StandupView().transition(.move(edge: .trailing).combined(with: .opacity))
            case .review(let ref):
                ReviewView(model: ReviewModel(ref: ref, host: hub.host(for: ref), kind: config.host(ref.hostID)?.kind ?? .gitlab))
                    .id(ref)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .background { WindowBackdrop() }
        .background {
            // Esc goes home from any sub-screen.
            Button("") { if hub.route != .home, !hub.escapeOwnedBySubview { hub.back() } }.keyboardShortcut(.escape, modifiers: []).hidden()
        }
        .onAppear {
            hub.requestNotificationPermission()
            AppDelegate.openChange = { ref in hub.go(.review(ref)); openWindow(id: "main") }
            AppDelegate.installUpdate = { Task { await hub.updates.installUpdate() } }
            AppDelegate.openStandup = { if Features.standup { hub.go(.standup); openWindow(id: "main") } }
        }
    }
}

/// Quiet text control; sits at the start of a sub-screen header.
struct BackButton: View {
    @EnvironmentObject var hub: Hub
    var body: some View {
        Button("Back") { hub.back() }
            .buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
            .help("Back to inbox (Esc)")
    }
}
