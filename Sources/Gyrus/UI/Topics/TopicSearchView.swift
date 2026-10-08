import SwiftUI

struct TopicSearchView: View {
    @ObservedObject var session: BrainSession
    @ObservedObject var store: TopicStore
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool
    private var matches: [Topic] { store.search(query) }
    private func openHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        session.open(matches[highlighted], store: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                TextField("Search topics…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 17)).focused($focused)
                    .accessibilityLabel("Search topics")
                    .onSubmit(openHighlighted)
                    .onChange(of: query) { highlighted = 0 }
                    .onKeyPress(.downArrow) { highlighted = min(max(0, matches.count - 1), highlighted + 1); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(0, highlighted - 1); return .handled }
                Button { session.isSearchPresented = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12)).padding(7)
                }.buttonStyle(.plain).accessibilityLabel("Close search")
            }.padding(20)
            Divider().overlay(.white.opacity(0.1))
            if matches.isEmpty {
                VStack(spacing: 8) {
                    Text(store.topics.isEmpty ? "No topics yet" : "No matching topics")
                        .font(.system(size: 15, weight: .medium))
                    Text(store.topics.isEmpty ? "Click a white particle to create a topic." : "Try another topic name.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                }.frame(maxWidth: .infinity).padding(32)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, topic in
                                Button { session.open(topic, store: store) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "triangle").foregroundStyle(SpaceTheme.accent)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(topic.name).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                            Text("\(topic.keywords.count) keywords").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                                        }
                                        Spacer()
                                        if highlighted == index { Image(systemName: "return").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)) }
                                    }
                                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(highlighted == index ? .white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(topic.id)
                            }
                        }.padding(8)
                    }.frame(height: min(340, CGFloat(matches.count) * 70 + 16))
                        .onChange(of: highlighted) {
                            if matches.indices.contains(highlighted) { proxy.scrollTo(matches[highlighted].id) }
                        }
                }
            }
        }
        .frame(width: 520)
        .background(SpaceTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.16)))
        .shadow(color: .black.opacity(0.6), radius: 32, y: 12)
        .task {
            do { try await Task.sleep(for: .milliseconds(80)); focused = true }
            catch { /* The field disappeared before focus was ready. */ }
        }
        .onExitCommand { session.isSearchPresented = false }
    }
}
