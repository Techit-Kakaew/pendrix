import SwiftUI
import AppKit

/// Yesterday / Today / Blockers, assembled from real activity. Edit in place, copy, done.
struct StandupView: View {
    @EnvironmentObject var hub: Hub
    @EnvironmentObject var config: Config
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var showBullets = false
    @State private var text = ""
    @State private var copied = false
    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if let s = hub.standup {
                    if editing { editor } else { rendered(s) }
                } else if hub.standupBusy {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Nothing yet").font(Type.meta).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 18)
        }
        .task { if hub.standup == nil { await hub.buildStandup() } }
        .onChange(of: hub.standup?.generated) { _, _ in text = hub.standup?.markdown ?? ""; editing = false }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            BackButton()
            Text("Standup").font(.system(size: 15, weight: .semibold))
            if let s = hub.standup {
                Text(s.sinceLabel + " → today").font(Type.meta).foregroundStyle(.secondary)
            }
            Spacer()
            if hub.standupBusy || hub.polishing { ProgressView().controlSize(.mini) }
            if config.aiProvider != .off {
                Picker("", selection: $config.standupLanguage) {
                    ForEach(StandupLanguage.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 130)
                .onChange(of: config.standupLanguage) { _, _ in Task { await hub.polishStandup() } }
            }
            if copied { Text("Copied").font(Type.meta).foregroundStyle(WorkItem.Tone.done.color) }
            headerButton(editing ? "Preview" : "Edit") { text = hub.standup?.polished ?? hub.standup?.markdown ?? text; editing.toggle() }
            headerButton("Regenerate") { Task { await hub.buildStandup() } }
            headerButton("Copy", tone: .active) { copy(markdown: false) }
            headerButton("Copy Markdown") { copy(markdown: true) }
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    }

    private func headerButton(_ title: String, tone: WorkItem.Tone? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Type.meta).fontWeight(tone == nil ? .regular : .medium)
                .foregroundStyle(tone.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain).glass(tint: tone?.color, radius: 8, interactive: true)
    }

    private func rendered(_ s: Standup) -> some View {
        Scrolling {
            GlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    if let p = s.polished {
                        spoken(p)
                        Button(showBullets ? "Hide source bullets" : "Show source bullets") { withAnimation(.snappy(duration: 0.2)) { showBullets.toggle() } }
                            .buttonStyle(.plain).font(Type.meta).foregroundStyle(.tertiary)
                    } else if let e = s.polishError {
                        Text(e).font(Type.meta).foregroundStyle(WorkItem.Tone.danger.color).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12).glass(tint: WorkItem.Tone.danger.color)
                    }
                    if s.polished == nil || showBullets {
                        section(s.sinceLabel, s.yesterday, empty: "Nothing recorded")
                        section("Today", s.today, empty: "Nothing queued")
                        section("Blockers", s.blockers, empty: "None", tint: s.blockers.isEmpty ? nil : WorkItem.Tone.warn.color)
                    }
                }
            }
        }
    }

    /// The read-aloud version. Headings the model was told to emit get the section treatment.
    private func spoken(_ text: String) -> some View {
        let heads: Set<String> = ["เมื่อวาน", "วันนี้", "ติดอะไรไหม", "Yesterday", "Today", "Blockers"]
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if heads.contains(line.trimmingCharacters(in: CharacterSet(charactersIn: ":："))) {
                    Text(line.uppercased()).font(Type.section).foregroundStyle(.secondary).kerning(0.8).padding(.top, 6)
                } else {
                    Text(line).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .glass(tint: WorkItem.Tone.active.color)
    }

    private func section(_ title: String, _ items: [String], empty: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(Type.section).foregroundStyle(.secondary).kerning(0.8)
            if items.isEmpty {
                Text(empty).font(Type.meta).foregroundStyle(.tertiary)
            } else {
                ForEach(items, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(.secondary.opacity(0.5)).frame(width: 4, height: 4).offset(y: -2)
                        Text(line).font(Type.title).textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glass(tint: tint)
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5, design: .monospaced)).scrollContentBackground(.hidden)
            .padding(12).glass()
    }

    private func copy(markdown: Bool) {
        let src = editing ? text : (hub.standup?.polished ?? hub.standup?.markdown ?? "")
        let out = markdown ? src : src.replacingOccurrences(of: "**", with: "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}
