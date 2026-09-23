import SwiftUI
import ServiceManagement
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var config: Config
    @EnvironmentObject var hub: Hub
    @State private var unlocked = false

    var body: some View {
        Group {
            if unlocked || !config.requireAuth { form } else { locked }
        }
        .frame(width: 560)
        .task { if !unlocked { unlocked = await Auth.require("Pendrix: open Settings") } }
    }

    private var locked: some View {
        VStack(spacing: 12) {
            Text("Settings are locked").font(.headline)
            Text("Tokens and account URLs need Touch ID or your password.").font(.caption).foregroundStyle(.secondary)
            Button("Unlock") { Task { unlocked = await Auth.require("Pendrix: open Settings") } }
        }
        .frame(height: 220)
    }

    private var form: some View {
        Form {
            Section("General") {
                LaunchAtLoginToggle()
                Toggle("Check for updates automatically", isOn: $config.autoUpdate)
                TextField("Update source (GitHub owner/repo)", text: $config.updateRepo)
                HStack {
                    Button("Check now") { Task { await hub.updates.check(manual: true) } }
                    if hub.updates.checking { ProgressView().controlSize(.small) }
                    else if let r = hub.updates.lastResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text("v\(hub.updates.current)").font(.caption).foregroundStyle(.tertiary)
                }
                if hub.updates.latest != nil { UpdateRow().environmentObject(hub) }
            }
            Section("Jira Cloud") {
                TextField("Site", text: $config.jiraSite, prompt: Text("7-solutions.atlassian.net"))
                TextField("Email", text: $config.jiraEmail, prompt: Text("you@company.com"))
                SecureField("API token", text: $config.jiraToken)
                TextField("JQL", text: $config.jiraJQL, axis: .vertical).lineLimit(2...4).font(.system(.body, design: .monospaced))
                HStack {
                    Link("Create an API token", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!).font(.caption)
                    Spacer()
                    if let e = hub.jiraError { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                    else if config.jiraReady, hub.lastRefresh != nil { Text("OK · \(hub.jira.count) tasks").font(.caption).foregroundStyle(.secondary) }
                }
            }
            ForEach($config.hosts) { $h in
                Section {
                    TextField("Base URL", text: $h.baseURL, prompt: Text(h.kind == .github ? "https://github.com" : "https://git.7.solutions"))
                    TokenField(host: h)
                    Toggle("Show my own \(h.kind.noun)s", isOn: $h.showOwn)
                    Toggle("Show mentions & todos", isOn: $h.showTodos)
                    HStack {
                        Text(h.kind == .gitlab ? "Token scope: `api` for review actions, `read_api` for inbox only"
                                               : "Token: classic `repo`, or fine-grained with Pull requests read/write")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let e = hub.hostErrors[h.id] { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        else if h.ready, hub.lastRefresh != nil { Text("OK").font(.caption).foregroundStyle(.secondary) }
                        Button("Remove", role: .destructive) { config.removeHost(h.id) }.controlSize(.small)
                    }
                } header: {
                    Text(h.kind.label + (h.host.isEmpty ? "" : " · \(h.host)"))
                }
            }
            Section {
                HStack {
                    Button("Add GitLab") { config.addHost(.gitlab) }
                    Button("Add GitHub") { config.addHost(.github) }
                }
            }
            Section("Inbox") {
                Toggle("Hide draft MRs", isOn: $config.hideDrafts)
                Toggle("Hide bot authors (renovate, dependabot, …)", isOn: $config.hideBots)
                Toggle("Group by repo", isOn: $config.groupByRepo)
                TextField("Only projects / repos containing", text: $config.projectFilter, prompt: Text("pay, core/sdk, MAR"))
                Picker("Overdue review after", selection: $config.agingHours) {
                    Text("Off").tag(0); Text("4 hours").tag(4); Text("8 hours").tag(8); Text("24 hours").tag(24); Text("48 hours").tag(48)
                }
                Text("Overdue requests get a red pill, turn the card red, and notify once.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Polling") {
                Picker("Refresh every", selection: $config.pollMinutes) {
                    Text("1 min").tag(1); Text("2 min").tag(2); Text("5 min").tag(5); Text("10 min").tag(10)
                }
                Toggle("Notify on new items", isOn: $config.notify)
                NotificationStatusRow()
            }
            if Features.standup { Section("Standup") {
                Toggle("Remind me on weekdays", isOn: $config.standupReminder)
                DatePicker("At", selection: Binding(
                    get: { Calendar.current.date(bySettingHour: config.standupMinutes / 60, minute: config.standupMinutes % 60, second: 0, of: Date()) ?? Date() },
                    set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); config.standupMinutes = (c.hour ?? 9) * 60 + (c.minute ?? 30) }),
                    displayedComponents: .hourAndMinute)
                Text("Summary covers yesterday (Friday on Mondays): Jira moves and comments, pushes, MRs opened, reviews, merges.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Language", selection: $config.standupLanguage) {
                    ForEach(StandupLanguage.allCases) { Text($0.label).tag($0) }
                }
                Picker("Spoken version by", selection: $config.aiProvider) {
                    ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                }
                if config.aiProvider == .claude {
                    SecureField("Anthropic API key", text: $config.anthropicKey)
                    Text("Sends the bullet list (ticket keys, MR titles) to the Claude API. Model \(ClaudePolisher.model), low effort, with refusal fallback enabled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if config.aiProvider == .onDevice {
                    Text("Runs on this Mac with Apple Intelligence; nothing leaves the device. Thai support depends on the system model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } }
            Section("Security") {
                Toggle("Require Touch ID for Settings and review actions", isOn: $config.requireAuth)
                Text(Auth.available ? "Touch ID or account password. One unlock covers 5 minutes."
                                    : "No Touch ID on this Mac; the account password is used.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Lock now") { Auth.lock(); unlocked = false }.controlSize(.small)
                HStack {
                    Button("Test connection") { Task { await hub.refresh() } }
                    if hub.refreshing { ProgressView().controlSize(.small) }
                    else if hub.lastRefresh != nil, hub.jiraError == nil, hub.hostErrors.isEmpty, config.jiraReady || config.anyHostReady {
                        Text("OK · \(hub.jira.count) tasks, \(hub.reviews.count) reviews, \(hub.todos.count) todos").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Keychain-backed secure field; the token never sits in the Codable HostConfig.
private struct TokenField: View {
    let host: HostConfig
    @State private var value = ""
    var body: some View {
        SecureField("Personal access token", text: $value)
            .onAppear { value = host.token }
            .onChange(of: value) { _, v in host.token = v }
    }
}


/// SMAppService toggle; reflects the real status so a failed register doesn't lie.
struct LaunchAtLoginToggle: View {
    @State private var on = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle("Launch at login", isOn: $on)
            .onChange(of: on) { _, v in
                do { v ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                catch { on = SMAppService.mainApp.status == .enabled }
            }
    }
}

/// "0.2.0 available · Update now" with progress while installing.
struct UpdateRow: View {
    @EnvironmentObject var hub: Hub
    var body: some View {
        let u = hub.updates
        HStack(spacing: 10) {
            switch u.phase {
            case .idle, .failed:
                Text("\(u.latest ?? "") available").font(.caption).foregroundStyle(WorkItem.Tone.done.color)
                Button("Update now") { Task { await u.installUpdate() } }.controlSize(.small)
                Button("Release notes") { u.openReleasePage() }.controlSize(.small)
                if case .failed(let m) = u.phase { Text(m).font(.caption).foregroundStyle(.red).lineLimit(2) }
            case .downloading(let p):
                ProgressView(value: p).frame(width: 120); Text("Downloading…").font(.caption)
            case .verifying: Text("Verifying…").font(.caption)
            case .installing: Text("Installing…").font(.caption)
            case .relaunching: Text("Relaunching…").font(.caption)
            }
        }
    }
}


/// Shows whether macOS lets Pendrix notify, with a jump to the system pane when it doesn't.
struct NotificationStatusRow: View {
    @State private var status: UNAuthorizationStatus = .notDetermined
    var body: some View {
        HStack(spacing: 10) {
            switch status {
            case .authorized, .provisional:
                Text("macOS allows notifications").font(.caption).foregroundStyle(.secondary)
                Button("Send test") { send() }.controlSize(.small)
            case .denied:
                Text("Blocked in System Settings — new review requests will not alert you.").font(.caption).foregroundStyle(.red)
                Button("Open Notification Settings") { openPane() }.controlSize(.small)
            default:
                Text("Not asked yet").font(.caption).foregroundStyle(.secondary)
                Button("Allow notifications") {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in refresh() }
                }.controlSize(.small)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
    private func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { s in DispatchQueue.main.async { status = s.authorizationStatus } }
    }
    private func send() {
        let n = UNMutableNotificationContent(); n.title = "Pendrix"; n.body = "Notifications are working."; n.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: n, trigger: nil)) { _ in }
    }
    private func openPane() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.techit.pendrix")!)
    }
}
