import Foundation
import Combine
import simd

@MainActor
final class KeywordInteraction: ObservableObject {
    @Published var orbit = SIMD2<Float>.zero
    @Published private(set) var selected: UUID?
    @Published private(set) var connectionSource: UUID?
    @Published var query = ""

    func select(_ id: UUID?, topicID: UUID, store: TopicStore) {
        if let source = connectionSource, let id, id != source {
            _ = store.connect(source, to: id, in: topicID)
            cancelConnection()
            return
        }
        guard connectionSource == nil else { return }
        selected = id
    }

    func beginConnection() {
        guard let selected else { return }
        connectionSource = selected
        query = ""
    }

    func cancelConnection() { connectionSource = nil; query = "" }

    func matches(in topic: Topic) -> [Keyword] {
        let source = connectionSource
        let connected = Set(topic.connections.compactMap { edge -> UUID? in
            if edge.first == source { return edge.second }
            if edge.second == source { return edge.first }
            return nil
        })
        return topic.keywords.filter {
            $0.id != source && !connected.contains($0.id)
                && (TopicText.key(query).isEmpty || TopicText.key($0.name).contains(TopicText.key(query)))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
