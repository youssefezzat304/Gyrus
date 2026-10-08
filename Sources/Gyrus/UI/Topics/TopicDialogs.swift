import SwiftUI

struct TopicNameDialog: View {
    @ObservedObject var session: BrainSession
    @ObservedObject var store: TopicStore
    @State private var name = ""
    @FocusState private var focused: Bool

    private func enter() { if session.nameTopic(name, store: store) { focused = false } }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name your topic").font(.system(size: 24, weight: .medium))
                Text("Your topic will open in its own space.").foregroundStyle(.white.opacity(0.6))
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Topic name", text: $name).modifier(SpaceField())
                    .focused($focused).onSubmit(enter).accessibilityLabel("Topic name")
                if name.count > 120 {
                    Text("Use 120 characters or fewer.").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: session.cancelNaming).keyboardShortcut(.cancelAction)
                    .buttonStyle(SpaceButtonStyle())
                Button("Enter space", action: enter).buttonStyle(SpaceButtonStyle(prominent: true))
                    .disabled(!TopicText.validName(name))
            }
        }
        .padding(32).frame(width: 460)
        .background(SpaceTheme.surface)
        .preferredColorScheme(.dark)
        .task {
            do { try await Task.sleep(for: .milliseconds(80)); focused = true }
            catch { /* The field disappeared before focus was ready. */ }
        }
    }
}

struct AddKeywordsDialog: View {
    let topicID: UUID
    @ObservedObject var store: TopicStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = KeywordDraft()
    @FocusState private var focused: Bool

    private var existing: [Keyword] { store.topic(id: topicID)?.keywords ?? [] }
    private func stage() { _ = draft.stage(existing: existing); focused = true }
    private func add() {
        if !TopicText.cleaned(draft.text).isEmpty, !draft.stage(existing: existing) { return }
        guard !draft.names.isEmpty else { return }
        _ = store.addKeywords(draft.names, to: topicID)
        dismiss()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add keywords").font(.system(size: 24, weight: .medium))
            Text("Press Return to add each keyword to the list.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            TextField("Type a keyword", text: $draft.text)
                .modifier(SpaceField()).focused($focused).onSubmit(stage)
                .accessibilityLabel("Keyword")
            if let error = draft.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
            }
            if !draft.names.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(draft.names.enumerated()), id: \.offset) { index, name in
                            HStack {
                                Image(systemName: "triangle").font(.system(size: 10)).foregroundStyle(SpaceTheme.accent)
                                Text(name).lineLimit(2)
                                Spacer()
                                Button { draft.remove(at: index) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).padding(6)
                                    .accessibilityLabel("Remove \(name)")
                            }
                            .font(.system(size: 13)).padding(10)
                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(height: min(220, CGFloat(draft.names.count) * 44))
            }
            HStack {
                Text("\(draft.names.count) queued").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(SpaceButtonStyle())
                // Return belongs exclusively to the input's staging action, never this button.
                Button("Add", action: add).buttonStyle(SpaceButtonStyle(prominent: true))
                    .disabled(draft.names.isEmpty && TopicText.cleaned(draft.text).isEmpty)
            }
        }
        .padding(32).frame(width: 480)
        .background(SpaceTheme.surface).preferredColorScheme(.dark)
        .task {
            do { try await Task.sleep(for: .milliseconds(80)); focused = true }
            catch { /* The field disappeared before focus was ready. */ }
        }
    }
}
