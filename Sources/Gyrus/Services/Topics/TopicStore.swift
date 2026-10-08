import Foundation
import Combine

@MainActor
final class TopicStore: ObservableObject {
    @Published private(set) var topics: [Topic] = []
    @Published private(set) var persistenceError: String?
    private let archiveURL: URL?
    private var canWrite = true
    var canRetrySaving: Bool { canWrite }
    var savedFileURL: URL? { archiveURL }
    private struct Archive: Codable { let version: Int; let topics: [Topic] }

    nonisolated static var defaultArchiveURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Gyrus", isDirectory: true).appendingPathComponent("topics.json")
    }

    init(archiveURL: URL? = TopicStore.defaultArchiveURL) {
        self.archiveURL = archiveURL
        guard let archiveURL, FileManager.default.fileExists(atPath: archiveURL.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: archiveURL))
            guard archive.version == 1, Self.isValid(archive.topics) else { throw CocoaError(.fileReadCorruptFile) }
            topics = archive.topics
        } catch {
            canWrite = false
            persistenceError = "Your saved topics could not be opened. The saved file has been preserved. New changes will remain in this session."
        }
    }

    private static func isValid(_ topics: [Topic]) -> Bool {
        guard Set(topics.map(\.id)).count == topics.count,
              Set(topics.map { $0.anchor.particleID }).count == topics.count else { return false }
        return topics.allSatisfy { topic in
            let ids = Set(topic.keywords.map(\.id))
            return TopicText.validName(topic.name) && topic.anchor.particleID >= 0
                && topic.anchor.particleID < VisualConfiguration.particleCount + VisualConfiguration.activeRegionCount
                && topic.anchor.position.x.isFinite && topic.anchor.position.y.isFinite && topic.anchor.position.z.isFinite
                && abs(topic.anchor.position.x) <= 5 && abs(topic.anchor.position.y) <= 5 && abs(topic.anchor.position.z) <= 5
                && topic.anchor.normal.x.isFinite && topic.anchor.normal.y.isFinite && topic.anchor.normal.z.isFinite
                && ids.count == topic.keywords.count
                && Set(topic.keywords.map { TopicText.key($0.name) }).count == topic.keywords.count
                && topic.keywords.allSatisfy {
                    TopicText.validName($0.name) && $0.position.x.isFinite && $0.position.y.isFinite
                        && $0.position.z.isFinite && $0.phase.isFinite
                        && abs($0.position.x) <= 5 && abs($0.position.y) <= 5 && abs($0.position.z) <= 5
                }
                && Set(topic.connections).count == topic.connections.count
                && topic.connections.allSatisfy {
                    $0.first != $0.second && ids.contains($0.first) && ids.contains($0.second)
                        && $0 == KeywordConnection($0.first, $0.second)
                }
        }
    }

    func retrySaving() { save() }

    private func save() {
        guard let archiveURL, canWrite else { return }
        do {
            let data = try JSONEncoder().encode(Archive(version: 1, topics: topics))
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: archiveURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = "Your changes are still here, but could not be saved on this Mac. Check available storage and folder access, then try saving again."
        }
    }

    func topic(id: UUID?) -> Topic? { topics.first { $0.id == id } }
    func topic(at anchor: BrainAnchor) -> Topic? { topics.first { $0.anchor.particleID == anchor.particleID } }

    @discardableResult
    func create(name: String, anchor: BrainAnchor) -> UUID? {
        guard TopicText.validName(name) else { return nil }
        if let existing = topic(at: anchor) { return existing.id }
        let topic = Topic(id: UUID(), name: TopicText.cleaned(name), anchor: anchor)
        topics.append(topic)
        save()
        return topic.id
    }

    func search(_ query: String) -> [Topic] {
        let key = TopicText.key(query)
        return topics.filter { key.isEmpty || TopicText.key($0.name).contains(key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func addKeywords(_ names: [String], to topicID: UUID) -> [UUID] {
        guard let index = topics.firstIndex(where: { $0.id == topicID }) else { return [] }
        var used = Set(topics[index].keywords.map { TopicText.key($0.name) }), added: [UUID] = []
        for input in names {
            let name = TopicText.cleaned(input)
            guard TopicText.validName(name), used.insert(TopicText.key(name)).inserted else { continue }
            let keyword = Keyword(id: UUID(), name: name,
                position: KeywordPlacement.next(avoiding: topics[index].keywords), phase: Float.random(in: 0..<(2 * .pi)))
            topics[index].keywords.append(keyword)
            added.append(keyword.id)
        }
        if !added.isEmpty { save() }
        return added
    }

    @discardableResult
    func connect(_ first: UUID, to second: UUID, in topicID: UUID) -> Bool {
        guard first != second, let index = topics.firstIndex(where: { $0.id == topicID }),
              topics[index].keywords.contains(where: { $0.id == first }),
              topics[index].keywords.contains(where: { $0.id == second }) else { return false }
        let connection = KeywordConnection(first, second)
        guard !topics[index].connections.contains(connection) else { return false }
        topics[index].connections.append(connection)
        save()
        return true
    }
}
