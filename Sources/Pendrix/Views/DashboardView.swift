import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var config: Config
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showFilters = false

    private func open(_ i: WorkItem) {
        if let c = i.change { hub.markSeen(i); hub.go(.review(c)) } else { hub.open(i) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isSnapshot { columns } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) { columns }
                        .onChange(of: hub.selectedID) { _, id in if let id { withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } } }
                }
            }
        }
        .modifier(Keys(enabled: !isSnapshot, hub: hub, open: open))
        .sheet(item: $hub.jiraCommentTarget) { JiraCommentSheet(item: $0).environmentObject(hub) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await hub.refresh() }
        }
    }

    private var columns: some View {
        GlassGroup(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                jiraColumn.frame(maxWidth: .infinity)
                gitlabColumn.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 18).padding(.bottom, 18)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("Pendrix").font(.system(size: 15, weight: .semibold))
            if hub.attentionCount > 0 {
                Text("\(hub.attentionCount) waiting on you").font(Type.meta).foregroundStyle(.secondary)
                if hub.agingCount > 0 {
                    Text("\(hub.agingCount) overdue").font(Type.meta).foregroundStyle(WorkItem.Tone.danger.color)
                }
            } else if setupNeeded {
                Text("Connect Jira, GitLab or GitHub in Settings").font(Type.meta).foregroundStyle(.secondary)
            } else {
                Text("You're clear").font(Type.meta).foregroundStyle(.secondary)
            }
            Spacer()
            if let f = hub.flash { Text(f).font(Type.meta).foregroundStyle(WorkItem.Tone.done.color) }
            if hub.refreshing {
                ProgressView().controlSize(.small)
            } else if let t = hub.lastRefresh {
                Text("updated \(t.relative)").font(Type.meta).foregroundStyle(.tertiary).monospacedDigit()
            }
            if Features.standup {
                Button("Standup") { hub.go(.standup) }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
            }
            Button(hub.hiddenCount > 0 ? "Filter · \(hub.hiddenCount) hidden" : "Filter") { showFilters.toggle() }
                .keyboardShortcut("f").buttonStyle(.plain).font(Type.meta)
                .foregroundStyle(hub.hiddenCount > 0 ? AnyShapeStyle(WorkItem.Tone.active.color) : AnyShapeStyle(.secondary))
                .popover(isPresented: $showFilters, arrowEdge: .bottom) { FilterPopover().environmentObject(config).environmentObject(hub) }
            Button("Refresh") { Task { await hub.refresh() } }
                .keyboardShortcut("r").buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
            if hub.unseenCount > 0 {
                Button("Mark seen") { hub.markAllSeen() }.buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
            }
            Button("Settings") { openSettings() }
                .keyboardShortcut(",").buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    }

    /// Flat list, or repo sub-headers when grouping is on.
    @ViewBuilder
    private func grouped(_ items: [WorkItem], @ViewBuilder row: @escaping (WorkItem) -> some View) -> some View {
        if config.groupByRepo {
            let groups = Dictionary(grouping: items, by: Hub.group(of:)).sorted { $0.key < $1.key }
            ForEach(groups, id: \.key) { g in
                Text(g.key).font(Type.key).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(g.value) { row($0) }
            }
        } else {
            ForEach(items) { row($0) }
        }
    }

    private var setupNeeded: Bool { !config.jiraReady && !config.anyHostReady }

    private var jiraColumn: some View {
        SectionCard(title: "Jira · my tasks", count: hub.visibleJira.count,
                    error: hub.jiraError,
                    empty: config.jiraReady ? "No open tasks" : "Not connected") {
            ForEach(hub.visibleJira) { i in
                ItemRow(item: i, isNew: hub.unseen.contains(i.id), open: { open(i) },
                        links: hub.linkedChanges(for: i), openLink: open,
                        menu: AnyView(JiraMenu(item: i).environmentObject(hub)), selected: hub.selectedID == i.id)
            }
        }
    }

    private var gitlabColumn: some View {
        VStack(spacing: 14) {
            SectionCard(title: "Review requests", count: hub.visibleReviews.count,
                        tint: hub.visibleReviews.isEmpty ? nil : (hub.agingCount > 0 ? WorkItem.Tone.danger.color : WorkItem.Tone.active.color),
                        error: hub.anyHostError,
                        empty: config.anyHostReady ? "Nobody is waiting on you" : "Not connected") {
                grouped(hub.visibleReviews) { i in
                    ItemRow(item: i, isNew: hub.unseen.contains(i.id), open: { open(i) }, links: hub.linkedJira(for: i), openLink: open,
                            selected: hub.selectedID == i.id, aging: hub.isAging(i))
                }
            }
            if config.anyHostReady || hub.isDemo, hub.anyHostError == nil {
                SectionCard(title: "Mentions & todos", count: hub.visibleTodos.count, empty: "Inbox zero") {
                    ForEach(hub.visibleTodos) { i in ItemRow(item: i, isNew: hub.unseen.contains(i.id), open: { open(i) }, selected: hub.selectedID == i.id) }
                }
            }
            if config.anyHostReady || hub.isDemo, hub.anyHostError == nil {
                SectionCard(title: "My merge requests", count: hub.visibleOwn.count, empty: "No open MRs") {
                    grouped(hub.visibleOwn) { i in
                        ItemRow(item: i, isNew: false, open: { open(i) }, links: hub.linkedJira(for: i), openLink: open, selected: hub.selectedID == i.id)
                    }
                }
            }
        }
    }
}


/// Inbox filters. Same values live in Settings → Inbox.
struct FilterPopover: View {
    @EnvironmentObject var config: Config
    @EnvironmentObject var hub: Hub
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Hide draft MRs", isOn: $config.hideDrafts)
            Toggle("Hide bot authors", isOn: $config.hideBots)
            Toggle("Group by repo", isOn: $config.groupByRepo)
            Divider()
            Text("Only projects / repos containing").font(Type.meta).foregroundStyle(.secondary)
            TextField("pay, core/sdk, MAR", text: $config.projectFilter).textFieldStyle(.roundedBorder).font(Type.meta)
            Divider()
            HStack {
                Text("Overdue review after").font(Type.meta)
                Picker("", selection: $config.agingHours) {
                    Text("Off").tag(0); Text("4h").tag(4); Text("8h").tag(8); Text("24h").tag(24); Text("48h").tag(48)
                }.labelsHidden().frame(width: 80)
            }
            Text("j / k or arrows move · Enter opens · a approves · ⌘F filters").font(Type.meta).foregroundStyle(.tertiary)
        }
        .padding(14).frame(width: 280)
    }
}


/// j/k/arrows/Enter/a on the inbox. Skipped under ImageRenderer, where focus machinery has no window and hangs.
private struct Keys: ViewModifier {
    let enabled: Bool
    let hub: Hub
    let open: (WorkItem) -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusable().focusEffectDisabled().focused($focused)
                .onAppear { focused = true }
                .onKeyPress(characters: .init(charactersIn: "jkaJK"), phases: .down) { press in
                    switch press.characters.lowercased() {
                    case "j": hub.moveSelection(1)
                    case "k": hub.moveSelection(-1)
                    case "a": if let i = hub.selectedItem { Task { await hub.quickApprove(i) } }
                    default: return .ignored
                    }
                    return .handled
                }
                .onKeyPress(.return) { if let i = hub.selectedItem { open(i); return .handled }; return .ignored }
                .onKeyPress(.downArrow) { hub.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { hub.moveSelection(-1); return .handled }
        } else {
            content
        }
    }
}
