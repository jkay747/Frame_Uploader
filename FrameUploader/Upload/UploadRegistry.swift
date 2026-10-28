import Foundation

struct UploadRecord: Codable, Hashable {
    var contentID: String
    /// SHA-256 of the original photo file, used to spot duplicates.
    var fingerprint: String
    var matteID: String
    var sourceName: String
    var uploadedAt: Date
}

/// Remembers which photos on each TV this app uploaded, so it can skip duplicates and
/// remove earlier uploads without touching anything else in the TV's My Photos.
@MainActor
final class UploadRegistry: ObservableObject {
    static let shared = UploadRegistry()

    /// host → content ID → record
    @Published private(set) var recordsByHost: [String: [String: UploadRecord]] = [:]

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FrameUploader", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("uploads.json")
        }
        load()
    }

    func records(for host: String) -> [UploadRecord] {
        Array((recordsByHost[host] ?? [:]).values)
    }

    func record(for host: String, fingerprint: String) -> UploadRecord? {
        recordsByHost[host]?.values.first { $0.fingerprint == fingerprint }
    }

    func add(_ record: UploadRecord, for host: String) {
        recordsByHost[host, default: [:]][record.contentID] = record
        save()
    }

    func updateMatte(contentID: String, matteID: String, for host: String) {
        recordsByHost[host]?[contentID]?.matteID = matteID
        save()
    }

    func remove(contentIDs: [String], for host: String) {
        for contentID in contentIDs {
            recordsByHost[host]?[contentID] = nil
        }
        save()
    }

    /// Drops records for photos that were deleted on the TV itself.
    func prune(host: String, keepingOnly contentIDsOnTV: Set<String>) {
        guard let records = recordsByHost[host] else { return }
        let kept = records.filter { contentIDsOnTV.contains($0.key) }
        if kept.count != records.count {
            recordsByHost[host] = kept
            save()
        }
    }

    func forget(host: String) {
        recordsByHost[host] = nil
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        recordsByHost = (try? decoder.decode([String: [String: UploadRecord]].self, from: data)) ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(recordsByHost) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
