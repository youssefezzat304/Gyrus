import Foundation
import Combine

@MainActor
final class BrainSession: ObservableObject {
    @Published var canGoBack = false
    @Published private(set) var phase: BrainPhase = .brain
    @Published private(set) var pendingAnchor: BrainAnchor?
    @Published private(set) var currentTopicID: UUID?
    @Published var isSearchPresented = false
    var onBack: (() -> Void)?
    var onEnter: ((BrainAnchor) -> BrainPhase?)?

    var canSearch: Bool { phase == .brain && pendingAnchor == nil }
    var isInSpace: Bool { phase == .empty && currentTopicID != nil }

    func requestTopic(at anchor: BrainAnchor, store: TopicStore) {
        guard canSearch, !isSearchPresented else { return }
        if let topic = store.topic(at: anchor) { open(topic, store: store) }
        else { pendingAnchor = anchor }
    }

    @discardableResult
    func nameTopic(_ name: String, store: TopicStore) -> Bool {
        guard let anchor = pendingAnchor, TopicText.validName(name), onEnter != nil,
              let id = store.create(name: name, anchor: anchor), let topic = store.topic(id: id) else { return false }
        pendingAnchor = nil
        open(topic, store: store)
        return true
    }

    func cancelNaming() { pendingAnchor = nil }

    func open(_ topic: Topic, store: TopicStore) {
        guard phase == .brain, let actual = store.topic(id: topic.id), let next = onEnter?(actual.anchor) else { return }
        currentTopicID = actual.id
        phase = next
        isSearchPresented = false
    }

    func updatePhase(_ phase: BrainPhase) {
        self.phase = phase
        if phase == .brain { currentTopicID = nil }
    }

    func goBack() { onBack?() }
    func showSearch() { if canSearch { isSearchPresented = true } }
}
