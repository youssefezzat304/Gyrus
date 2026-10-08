import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var session = BrainSession()
    @ObservedObject var store: TopicStore
    @State private var showsSaveError = false

    var body: some View {
        ZStack {
            BrainView(session: session, store: store)
            if session.isInSpace, let topic = store.topic(id: session.currentTopicID) {
                TopicSpaceView(topic: topic, store: store).id(topic.id)
            }
            if session.isSearchPresented {
                Color.black.opacity(0.45).onTapGesture { session.isSearchPresented = false }
                VStack { TopicSearchView(session: session, store: store).padding(.top, 110); Spacer() }
            }
        }
            .overlay(alignment: .topLeading) {
                if session.canGoBack {
                    Button(action: session.goBack) {
                        Label("Back", systemImage: "arrow.left")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.white.opacity(0.06), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 28)
                    .padding(.top, 52)
                    .accessibilityHint("Return to the particle brain")
                }
            }
            .overlay(alignment: .topTrailing) {
                if session.canSearch && !session.isSearchPresented {
                    Button(action: session.showSearch) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                            Text("Search topics")
                            Text("⌃F").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }
                    }.buttonStyle(SpaceButtonStyle()).padding(.trailing, 28).padding(.top, 52)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if store.persistenceError != nil {
                    Button("Changes aren't being saved") { showsSaveError = true }
                        .buttonStyle(SpaceButtonStyle()).padding(24)
                }
            }
            .sheet(isPresented: Binding(get: { session.pendingAnchor != nil }, set: { if !$0 { session.cancelNaming() } })) {
                TopicNameDialog(session: session, store: store)
            }
            .alert(store.canRetrySaving ? "Topics could not be saved" : "Saved topics could not be opened", isPresented: $showsSaveError) {
                if store.canRetrySaving {
                    Button("Try Saving Again", action: store.retrySaving)
                } else if let url = store.savedFileURL {
                    Button("Show Saved File") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("OK", role: .cancel) {}
            } message: { Text(store.persistenceError ?? "") }
            .focusedSceneValue(\.topicSearchAction, session.canSearch ? { session.showSearch() } : nil)
            .frame(minWidth: 900, minHeight: 600)
            .ignoresSafeArea()
            .background(Color(red: 3 / 255, green: 3 / 255, blue: 5 / 255))
            .preferredColorScheme(.dark)
    }
}
