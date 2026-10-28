import AppKit

/// A small render of exactly what the TV will show for one photo.
final class PhotoPreview: @unchecked Sendable {
    let image: NSImage
    let mode: FitMode

    init(image: NSImage, mode: FitMode) {
        self.image = image
        self.mode = mode
    }
}

/// Builds previews lazily as grid cells appear, a few at a time, keeping a bounded cache.
final class PreviewLoader: @unchecked Sendable {
    private let cache = NSCache<NSString, PhotoPreview>()
    private let limiter = ConcurrencyLimiter(limit: 4)

    init() {
        cache.countLimit = 400
    }

    func preview(for item: PhotoItem) async -> PhotoPreview? {
        let key = item.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }

        await limiter.acquire()
        defer { Task { await limiter.release() } }
        guard !Task.isCancelled else { return nil }

        do {
            let source = try await PhotoLoader.previewImage(for: item.origin, maxPixelSize: 1024)
            let (rendered, mode) = try await Task.detached(priority: .utility) {
                try PhotoProcessor.shared.makePreview(from: source)
            }.value
            let preview = PhotoPreview(
                image: NSImage(cgImage: rendered, size: NSSize(width: rendered.width, height: rendered.height)),
                mode: mode
            )
            cache.setObject(preview, forKey: key)
            return preview
        } catch {
            return nil
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}

actor ConcurrencyLimiter {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = limit
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}
