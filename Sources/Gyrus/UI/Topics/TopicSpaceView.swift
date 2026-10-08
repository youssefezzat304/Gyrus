import SwiftUI

struct TopicSpaceView: View {
    let topic: Topic
    @ObservedObject var store: TopicStore
    @StateObject private var interaction = KeywordInteraction()
    @State private var isAdding = false

    var body: some View {
        GeometryReader { geometry in
            let size = SIMD2(Float(geometry.size.width), Float(geometry.size.height))
            let frame = TopicProjection.frame(size: size, orbit: interaction.orbit)
            ZStack {
                TopicMetalView(topic: topic, interaction: interaction, store: store)
                Text(topic.name)
                    .font(.system(size: 24, weight: .medium)).tracking(0.3)
                    .multilineTextAlignment(.center).lineLimit(2).frame(maxWidth: 340)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 - 56)
                    .allowsHitTesting(false)
                if let keyword = topic.keywords.first(where: { $0.id == interaction.selected }),
                   let point = InteractionController.project(keyword.position, frame: frame, size: size) {
                    Text(keyword.name)
                        .font(.system(size: 15, weight: .medium)).lineLimit(2)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 6))
                        .frame(maxWidth: 240)
                        .position(x: CGFloat(point.x), y: max(24, CGFloat(point.y) - 36))
                        .allowsHitTesting(false)
                    if interaction.connectionSource == nil {
                        Button("Connect", action: interaction.beginConnection)
                            .buttonStyle(SpaceButtonStyle())
                            .position(x: CGFloat(point.x), y: min(geometry.size.height - 100, CGFloat(point.y) + 44))
                    }
                }
                VStack {
                    Spacer()
                    if interaction.connectionSource != nil {
                        ConnectionSearchView(topic: topic, interaction: interaction, store: store)
                            .padding(.bottom, 18)
                    }
                    Button { isAdding = true; interaction.cancelConnection() } label: {
                        Label("Add Keywords", systemImage: "plus")
                    }
                    .buttonStyle(SpaceButtonStyle())
                    .padding(.bottom, 32)
                }
            }
        }
        .sheet(isPresented: $isAdding) { AddKeywordsDialog(topicID: topic.id, store: store) }
    }
}

private struct ConnectionSearchView: View {
    let topic: Topic
    @ObservedObject var interaction: KeywordInteraction
    @ObservedObject var store: TopicStore
    @FocusState private var focused: Bool
    private var matches: [Keyword] { interaction.matches(in: topic) }
    private func connect(_ keyword: Keyword) { interaction.select(keyword.id, topicID: topic.id, store: store) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connect to a keyword").font(.system(size: 14, weight: .medium))
                Spacer()
                Button(action: interaction.cancelConnection) { Image(systemName: "xmark").padding(4) }
                    .buttonStyle(.plain).accessibilityLabel("Cancel connection")
            }
            TextField("Search keywords…", text: $interaction.query).modifier(SpaceField()).focused($focused)
                .accessibilityLabel("Search keywords to connect")
                .onSubmit { if let first = matches.first { connect(first) } }
            if matches.isEmpty {
                Text(topic.keywords.count < 2 ? "Add another keyword to connect." : "No available matching keywords.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(matches) { keyword in
                            Button { connect(keyword) } label: {
                                HStack {
                                    Image(systemName: "triangle").font(.system(size: 10)).foregroundStyle(SpaceTheme.accent)
                                    Text(keyword.name).lineLimit(2)
                                    Spacer()
                                    Image(systemName: "link").foregroundStyle(.white.opacity(0.5))
                                }.font(.system(size: 13)).padding(10).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(height: min(140, CGFloat(matches.count) * 38))
            }
            Text("Or click another triangle in the space.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(18).frame(width: 330)
        .background(SpaceTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.16)))
        .task {
            do { try await Task.sleep(for: .milliseconds(80)); focused = true }
            catch { /* The field disappeared before focus was ready. */ }
        }
        .onExitCommand(perform: interaction.cancelConnection)
    }
}
