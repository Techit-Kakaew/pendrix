import SwiftUI

/// The AI pass as a worklist: summary, then every draft grouped by file. Post / edit / dismiss per item.
struct AIDraftsView: View {
    @ObservedObject var model: ReviewModel
    @State private var summaryDraft = ""
    @State private var postingSummary = false

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let e = model.aiError {
                    Text(e).font(Type.meta).foregroundStyle(WorkItem.Tone.danger.color).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WorkItem.Tone.danger.color.opacity(0.08)))
                }
                if model.aiRunning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Claude is reviewing… diff-only takes 30–90 s, deep review 2–6 min").font(Type.meta).foregroundStyle(.secondary) }
                } else if !model.aiDrafts.isEmpty || !model.aiSummary.isEmpty {
                    summaryBlock
                    let groups = Dictionary(grouping: model.pendingDrafts, by: { $0.path ?? "" }).sorted { $0.key < $1.key }
                    ForEach(groups, id: \.key) { g in
                        Text(g.key.isEmpty ? "GENERAL" : g.key).font(Type.key).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(g.value) { dft in DraftCard(draft: dft, model: model, showJump: true) }
                    }
                    let posted = model.aiDrafts.filter(\.posted).count
                    if posted > 0 { Text("\(posted) posted").font(Type.meta).foregroundStyle(.tertiary) }
                    if model.pendingDrafts.isEmpty, !model.aiDrafts.isEmpty { Text("All drafts handled.").font(Type.meta).foregroundStyle(.tertiary) }
                    if !model.aiSkipped.isEmpty {
                        Text("Skipped (generated or too large): \(model.aiSkipped.joined(separator: ", "))").font(Type.meta).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(18)
        }
        .onAppear { if summaryDraft.isEmpty { summaryDraft = model.aiSummary } }
        .onChange(of: model.aiSummary) { _, s in summaryDraft = s }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("AI DRAFTS").font(Type.section).foregroundStyle(.secondary).kerning(0.8)
            switch model.aiMode {
            case .deep(let repo): Text("Deep review · \((repo as NSString).abbreviatingWithTildeInPath)").font(Type.meta).foregroundStyle(WorkItem.Tone.done.color)
            case .diffOnly: Text("Diff-only · no local clone found under \(RepoLocator.configuredRoots)").font(Type.meta).foregroundStyle(.tertiary)
            case nil: Text("Suggestions from Claude. Edit freely; only Post sends anything.").font(Type.meta).foregroundStyle(.tertiary)
            }
            Spacer()
            Button(model.aiRunning ? "Running…" : "Run again") { Task { await model.runAIReview() } }
                .buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary).disabled(model.aiRunning)
            if !model.pendingDrafts.isEmpty {
                Button("Dismiss all") { for d in model.pendingDrafts { model.dismiss(d) } }
                    .buttonStyle(.plain).font(Type.meta).foregroundStyle(.tertiary)
            }
        }
    }

    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SUMMARY").font(Type.section).foregroundStyle(.secondary).kerning(0.8)
            TextField("Summary", text: $summaryDraft, axis: .vertical).textFieldStyle(.plain).font(Type.title).lineLimit(2...10)
            HStack {
                Spacer()
                Button("Post as comment") {
                    let d = AIDraft(path: nil, anchor: nil, severity: .suggestion, title: "", body: summaryDraft)
                    postingSummary = true
                    Task { await model.post(d); postingSummary = false }
                }
                .buttonStyle(.plain).font(Type.meta).fontWeight(.medium).foregroundStyle(WorkItem.Tone.active.color)
                .disabled(summaryDraft.isEmpty || postingSummary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
    }
}

/// One draft: severity, editable body, Post / Dismiss. Amber dashed border says "not sent yet".
struct DraftCard: View {
    let draft: AIDraft
    @ObservedObject var model: ReviewModel
    var showJump = false
    @State private var body_ = ""
    @State private var editing = false

    private var tone: WorkItem.Tone {
        switch draft.severity { case .blocker: .danger; case .suggestion: .active; case .nit: .neutral; case .question: .warn }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusPill(text: draft.severity.rawValue, tone: tone)
                if !draft.title.isEmpty { Text(draft.title).font(Type.title).fontWeight(.medium).lineLimit(2) }
                Spacer()
                if let a = draft.anchor {
                    Text("L\(a.newLine ?? a.oldLine ?? 0)").font(Type.key).foregroundStyle(.tertiary)
                } else if draft.path != nil {
                    Text("line not found · posts to conversation").font(Type.meta).foregroundStyle(.tertiary)
                }
            }
            if editing {
                TextField("Comment", text: $body_, axis: .vertical).textFieldStyle(.plain).font(Type.title).lineLimit(2...12)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.05)))
            } else {
                Text(markdown(draft.body)).font(Type.title).textSelection(.enabled).lineSpacing(2)
            }
            HStack(spacing: 12) {
                Button("Post") { Task { await model.post(draft) } }
                    .buttonStyle(.plain).font(Type.meta).fontWeight(.medium).foregroundStyle(WorkItem.Tone.done.color)
                Button(editing ? "Done" : "Edit") {
                    if editing { model.update(draft, body: body_) } else { body_ = draft.body }
                    editing.toggle()
                }.buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
                if showJump, draft.anchor != nil {
                    Button("Show line") { model.jump(to: draft) }.buttonStyle(.plain).font(Type.meta).foregroundStyle(.secondary)
                }
                Button("Dismiss") { model.dismiss(draft) }.buttonStyle(.plain).font(Type.meta).foregroundStyle(.tertiary)
                Spacer()
                Text("draft").font(Type.meta).foregroundStyle(WorkItem.pendingColor)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WorkItem.pendingColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(WorkItem.pendingColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
