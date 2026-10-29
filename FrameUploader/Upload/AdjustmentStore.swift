import Foundation

/// Remembers each photo's fit and crop between sessions, so adding the same photo again restores it.
/// Finder photos are matched by file path, Apple Photos ones by their library identifier.
@MainActor
final class AdjustmentStore: ObservableObject {
    static let shared = AdjustmentStore()

    @Published private(set) var adjustments: [String: PhotoAdjustment] = [:]

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FrameUploader", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.fileURL = support.appendingPathComponent("adjustments.json")
        }
        load()
    }

    var count: Int { adjustments.count }

    func adjustment(for origin: PhotoOrigin) -> PhotoAdjustment {
        adjustments[Self.key(for: origin)] ?? PhotoAdjustment()
    }

    func set(_ adjustment: PhotoAdjustment, for origin: PhotoOrigin) {
        let key = Self.key(for: origin)
        // Only changes are stored; going back to Automatic forgets the photo.
        adjustments[key] = adjustment.isDefault ? nil : adjustment
        save()
    }

    func forgetAll() {
        adjustments = [:]
        save()
    }

    private static func key(for origin: PhotoOrigin) -> String {
        switch origin {
        case .file(let url): return "file:" + url.standardizedFileURL.path
        case .library(let identifier): return "photos:" + identifier
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        adjustments = (try? JSONDecoder().decode([String: PhotoAdjustment].self, from: data)) ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(adjustments) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
