import SwiftUI

/// Compact list for the menu-bar panel: only what needs me, plus a link to the window.
struct MenuBarView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var config: Config
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private func open(_ i: WorkItem) {
        if let c = i.change { hub.markSeen(i); show(.review(c)) } else { hub.open(i) }
    }
    private func show(_ r: Hub.Route) {
        hub.go(r); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true)
    }
    @Environment(\.isSnapshot) private var isSnapshot

    @State private var cardsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 10) {
            scrollableCards
            footer
        }
        .padding(12)
        .frame(width: 400)
        .sheet(item: $hub.jiraCommentTarget) { JiraCommentSheet(item: $0).environmentObject(hub) }
        .background { WindowBackdrop() }
    }

    /// ScrollView has no intrinsic height inside MenuBarExtra: measure the cards and cap at the screen.
    @ViewBuilder
    private var scrollableCards: some View {
        if isSnapshot {
            cards
        } else {
            let maxH = (NSScreen.main?.visibleFrame.height ?? 900) - 140
            ScrollView(.vertical, showsIndicators: false) {
                cards.background(GeometryReader { g in Color.clear.preference(key: MenuHeightKey.self, value: g.size.height) })
            }
            .onPreferenceChange(MenuHeightKey.self) { cardsHeight = $0 }
            .frame(height: min(max(cardsHeight, 60), maxH))
        }
    }

    private var cards: some View {
        VStack(spacing: 10) {
            GlassGroup(spacing: 10) {
                if !config.jiraReady && !config.anyHostReady && !hub.isDemo {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NOT CONNECTED").font(Type.section).foregroundStyle(.secondary).kerning(0.8)
                        Text("Add your Jira site and a GitLab or GitHub token to start watching.").font(Type.meta).foregroundStyle(.secondary)
                        Button("Open Settings") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                            .buttonStyle(.plain).font(Type.title).foregroundStyle(WorkItem.Tone.active.color)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).glass(tint: WorkItem.Tone.active.color)
                }
                if !hub.visibleReviews.isEmpty || !hub.visibleTodos.isEmpty {
                    SectionCard(title: "Waiting on you", count: hub.attentionCount, tint: hub.agingCount > 0 ? WorkItem.Tone.danger.color : WorkItem.Tone.active.color) {
                        ForEach(hub.visibleReviews + hub.visibleTodos) { i in
                            ItemRow(item: i, isNew: hub.unseen.contains(i.id), open: { open(i) }, links: hub.linkedJira(for: i), openLink: open, aging: hub.isAging(i))
                        }
                    }
                }
                if config.anyHostReady, hub.visibleReviews.isEmpty, hub.visibleTodos.isEmpty {
                    SectionCard(title: "Waiting on you", count: 0, error: hub.anyHostError, empty: "Nobody is waiting on you") { EmptyView() }
                }
                if config.jiraReady || hub.isDemo {
                SectionCard(title: "Jira", count: hub.visibleJira.count, error: hub.jiraError, empty: "No open tasks") {
                    ForEach(hub.visibleJira.prefix(6)) { i in
                        ItemRow(item: i, isNew: hub.unseen.contains(i.id), open: { open(i) },
                                links: hub.linkedChanges(for: i), openLink: open,
                                menu: AnyView(JiraMenu(item: i).environmentObject(hub)))
                    }
                }
                }
            }
        }
    }

    private var footer: some View {
            HStack {
                if let t = hub.lastRefresh { Text("updated \(t.relative)").font(Type.meta).foregroundStyle(.tertiary) }
                Spacer()
                if let v = hub.updates.latest {
                    Button("Update to \(v)") { Task { await hub.updates.installUpdate() } }
                        .buttonStyle(.plain).font(Type.meta).foregroundStyle(WorkItem.Tone.done.color)
                }
                if Features.standup {
                    Button("Standup") { show(.standup) }
                        .buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
                }
                Button("Settings") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
                Button("Open Pendrix") { show(.home) }
                    .buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(Type.meta).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
    }
}

/// Menu-bar glyph: the open ring with its dot, as a template image so it follows the bar's tint.
enum MenuBarIcon {
    static let image: NSImage = {
        let size: CGFloat = 16
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let g = NSGraphicsContext.current!.cgContext
            let c = CGPoint(x: rect.midX, y: rect.midY + 0.5), R: CGFloat = 5.2
            g.setLineWidth(1.7); g.setLineCap(.round); g.setStrokeColor(NSColor.black.cgColor)
            g.addArc(center: c, radius: R, startAngle: -.pi * 0.25, endAngle: .pi * 1.25, clockwise: false); g.strokePath()
            g.setFillColor(NSColor.black.cgColor)
            let r: CGFloat = 1.5
            g.addEllipse(in: CGRect(x: c.x - r, y: c.y - R - r, width: r * 2, height: r * 2)); g.fillPath()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

private struct MenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
