import Foundation

public struct DistanceReference: Codable, Sendable, Identifiable {
    public var startMarker: String
    public var endMarker: String
    public var meters: Double
    public var source: String
    public var id: String { startMarker + ":" + endMarker }
    public init(startMarker: String, endMarker: String, meters: Double, source: String) {
        self.startMarker = startMarker; self.endMarker = endMarker; self.meters = meters; self.source = source
    }
}

public struct RecordingInfo: Codable, Sendable {
    public var title = ""
    public var note = ""
    public var references: [DistanceReference] = []
    public init() {}
}

public struct RecordingEntry: Identifiable, Sendable {
    public var url: URL
    public var info: RecordingInfo
    public var createdAt: Date
    public var bytes: Int64
    public var id: String { url.lastPathComponent }
    public var title: String { info.title.isEmpty ? createdAt.formatted(date: .abbreviated, time: .shortened) : info.title }
}

/// Raw logs are immutable; names, notes and railway references live in separate atomic sidecars.
public struct RecordingStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var trash: URL { directory.appendingPathComponent("RecentlyDeleted", isDirectory: true) }
    private func infoURL(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("notes.json") }

    public func info(for url: URL) throws -> RecordingInfo {
        let path = infoURL(url)
        guard FileManager.default.fileExists(atPath: path.path) else { return RecordingInfo() }
        return try JSONDecoder().decode(RecordingInfo.self, from: Data(contentsOf: path))
    }

    public func save(_ info: RecordingInfo, for url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
        guard info.references.allSatisfy({ $0.meters.isFinite && $0.meters > 0 }) else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: infoURL(url), options: .atomic)
    }

    public func entries(deleted: Bool = false) throws -> [RecordingEntry] {
        let root = deleted ? trash : directory
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .isRegularFileKey])
            .filter { $0.pathExtension == "jsonl" }
            .map { url in
                let attributes = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                return RecordingEntry(url: url, info: try info(for: url),
                    createdAt: attributes.creationDate ?? .distantPast, bytes: Int64(attributes.fileSize ?? 0))
            }.sorted { $0.createdAt > $1.createdAt }
    }

    public func moveToTrash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try movePair(url, to: trash.appendingPathComponent(url.lastPathComponent))
    }

    public func restore(_ url: URL) throws {
        try movePair(url, to: directory.appendingPathComponent(url.lastPathComponent))
    }

    private func movePair(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path), !fm.fileExists(atPath: infoURL(destination).path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.moveItem(at: source, to: destination)
        do {
            if fm.fileExists(atPath: infoURL(source).path) { try fm.moveItem(at: infoURL(source), to: infoURL(destination)) }
        } catch {
            try? fm.moveItem(at: destination, to: source)
            throw error
        }
    }
}
