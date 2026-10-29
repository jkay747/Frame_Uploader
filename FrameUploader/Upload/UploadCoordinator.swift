import Foundation
import os
import SwiftUI

struct UploadSummary: Identifiable {
    let id = UUID()
    var uploaded = 0
    var alreadyOnTV = 0
    var failed = 0
    var removed = 0
    var slideshowMessage: String?
    var notes: [String] = []
    var stopReason: String?
    var cancelled = false
    var bytesSent = 0
    var elapsed: Duration = .zero

    var title: String {
        if cancelled { return "Upload cancelled" }
        if stopReason != nil { return "Upload stopped" }
        if failed > 0 { return "Upload finished with problems" }
        return "Upload complete"
    }

    var message: String {
        var lines: [String] = []
        if let stopReason { lines.append(stopReason) }
        if uploaded > 0 { lines.append("Uploaded \(uploaded) photo\(uploaded == 1 ? "" : "s").") }
        if alreadyOnTV > 0 { lines.append("\(alreadyOnTV) already on the TV, so skipped.") }
        if failed > 0 { lines.append("\(failed) couldn't be uploaded. Hover over the warning icon on each one for details.") }
        if uploaded > 0 {
            let megabytes = Double(bytesSent) / 1_000_000
            let seconds = Double(elapsed.components.seconds)
            let perPhoto = seconds / Double(uploaded + alreadyOnTV)
            lines.append(String(format: "Sent %.1f MB in %.0f s (about %.1f s per photo).", megabytes, seconds, perPhoto))
        }
        if removed > 0 { lines.append("Removed \(removed) photo\(removed == 1 ? "" : "s") from your previous upload.") }
        if let slideshowMessage { lines.append(slideshowMessage) }
        lines += notes
        if lines.isEmpty { lines.append("Nothing was uploaded.") }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class UploadCoordinator: ObservableObject {
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var isWorking = false
    @Published private(set) var isScanning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var statusText = ""
    @Published var summary: UploadSummary?

    let previews = PreviewLoader()
    private let log = Logger(subsystem: "com.kay2ventures.FrameUploader", category: "upload")
    private let registry = UploadRegistry.shared
    private var knownOrigins: Set<PhotoOrigin> = []
    private var uploadTask: Task<Void, Never>?

    var includedCount: Int { items.filter(\.isIncluded).count }

    // MARK: - Adding and removing photos

    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isScanning = true
        Task {
            let files = await Task.detached(priority: .userInitiated) {
                FolderScanner.imageFiles(in: urls)
            }.value
            let newItems = files.map { url in
                PhotoItem(origin: .file(url), name: url.lastPathComponent, group: url.deletingLastPathComponent().lastPathComponent)
            }
            append(newItems)
            isScanning = false
            if files.isEmpty {
                statusText = "No photos found in what you added."
            }
        }
    }

    func addAlbums(_ albumIDs: [String]) {
        let newItems = albumIDs.flatMap { albumID -> [PhotoItem] in
            let title = PhotoLibrary.albumTitle(albumID)
            return PhotoLibrary.assets(inAlbum: albumID).map {
                PhotoItem(origin: .library($0.id), name: $0.name, group: title)
            }
        }
        append(newItems)
    }

    private func append(_ newItems: [PhotoItem]) {
        var added = 0
        for item in newItems where !knownOrigins.contains(item.origin) {
            knownOrigins.insert(item.origin)
            items.append(item)
            added += 1
        }
        if added > 0 {
            statusText = "\(items.count) photo\(items.count == 1 ? "" : "s") ready."
        }
    }

    func toggleIncluded(_ id: PhotoItem.ID) {
        guard !isWorking, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isIncluded.toggle()
    }

    func remove(_ id: PhotoItem.ID) {
        guard !isWorking, let index = items.firstIndex(where: { $0.id == id }) else { return }
        knownOrigins.remove(items[index].origin)
        items.remove(at: index)
    }

    func clear() {
        guard !isWorking else { return }
        items = []
        knownOrigins = []
        previews.removeAll()
        statusText = ""
        progress = 0
    }

    // MARK: - Uploading

    func startUpload() {
        guard uploadTask == nil, includedCount > 0 else { return }
        uploadTask = Task {
            await runUpload(options: .current())
            uploadTask = nil
        }
    }

    func cancelUpload() {
        uploadTask?.cancel()
        statusText = "Stopping…"
    }

    /// A photo made ready for the TV, or found to be on it already.
    private enum PreparedPhoto {
        case alreadyOnTV(UploadRecord)
        case ready(fingerprint: String, jpeg: Data)
    }

    private func prepare(_ item: PhotoItem, host: String, skipDuplicates: Bool, onTV: Set<String>) async throws -> PreparedPhoto {
        let clock = ContinuousClock()
        let started = clock.now
        let data = try await PhotoLoader.data(for: item.origin)
        let fingerprint = await Task.detached(priority: .userInitiated) {
            PhotoLoader.fingerprint(of: data)
        }.value

        if skipDuplicates, let existing = registry.record(for: host, fingerprint: fingerprint), onTV.contains(existing.contentID) {
            return .alreadyOnTV(existing)
        }

        let jpeg = try await Task.detached(priority: .userInitiated) {
            try PhotoProcessor.shared.makeTVImage(from: data).jpeg
        }.value
        let original = data.count / 1024
        let optimized = jpeg.count / 1024
        let elapsed = clock.now - started
        log.info("Prepared \(item.name, privacy: .public): \(original) KB → \(optimized) KB in \(elapsed.description, privacy: .public)")
        return .ready(fingerprint: fingerprint, jpeg: jpeg)
    }

    /// Connects to the saved address. If the TV doesn't answer there (routers often hand out a new
    /// address), looks for it on the network and switches to it, keeping the pairing and history.
    private func connectToTV(host: String) async throws -> (client: FrameArtClient, host: String) {
        do {
            return (try await FrameArtClient.connected(to: host), host)
        } catch let error as FrameTVError where error.isUnreachable {
            statusText = "The TV didn't answer at \(host). Looking for it on the network…"
            let found = await TVDiscovery.findFrameTVs()
            guard found.count == 1, let tv = found.first, tv.host != host else { throw error }

            log.info("TV moved from \(host, privacy: .public) to \(tv.host, privacy: .public)")
            TokenStore.move(from: host, to: tv.host)
            registry.moveHost(from: host, to: tv.host)
            UserDefaults.standard.set(tv.host, forKey: SettingsKey.tvHost)
            statusText = "Found \(tv.name) at \(tv.host). Connecting…"
            return (try await FrameArtClient.connected(to: tv.host), tv.host)
        }
    }

    private func runUpload(options: UploadOptions) async {
        isWorking = true
        progress = 0
        defer { isWorking = false }

        let clock = ContinuousClock()
        let started = clock.now
        let targets = items.filter(\.isIncluded)
        for item in targets { setStatus(item.id, .waiting) }

        var summary = UploadSummary()
        var client: FrameArtClient?
        var nextPhoto: Task<PreparedPhoto, Error>?
        var bytesSent = 0

        do {
            statusText = "Connecting to your TV… The first time, select Allow on the TV with your remote."
            let (connected, host) = try await connectToTV(host: options.host)
            client = connected

            statusText = "Checking what's already on the TV…"
            var onTV = Set(try await connected.contentIDs())
            registry.prune(host: host, keepingOnly: onTV)

            // Everything in this batch, whether uploaded now or already there.
            var batchIDs: [String] = []
            var matteID = options.matteID

            func startPreparing(_ index: Int) -> Task<PreparedPhoto, Error>? {
                guard index < targets.count else { return nil }
                let item = targets[index]
                let snapshot = onTV
                setStatus(item.id, .preparing)
                return Task {
                    try await self.prepare(item, host: host, skipDuplicates: options.skipDuplicates, onTV: snapshot)
                }
            }

            nextPhoto = startPreparing(0)
            for (index, item) in targets.enumerated() {
                try Task.checkCancellation()
                progress = Double(index) / Double(targets.count)
                statusText = "Photo \(index + 1) of \(targets.count): \(item.name)"

                guard let current = nextPhoto else { break }
                // Resize the next photo while this one is on its way to the TV.
                nextPhoto = startPreparing(index + 1)

                do {
                    var prepared = try await withTaskCancellationHandler {
                        try await current.value
                    } onCancel: {
                        current.cancel()
                    }

                    // The same photo twice in one batch is only recognizable once the first has uploaded.
                    if case .ready(let fingerprint, _) = prepared, options.skipDuplicates,
                       let existing = registry.record(for: host, fingerprint: fingerprint),
                       onTV.contains(existing.contentID) {
                        prepared = .alreadyOnTV(existing)
                    }

                    switch prepared {
                    case .alreadyOnTV(let existing):
                        if existing.matteID != matteID {
                            try await connected.changeMatte(contentID: existing.contentID, matteID: matteID)
                            registry.updateMatte(contentID: existing.contentID, matteID: matteID, for: host)
                        }
                        batchIDs.append(existing.contentID)
                        summary.alreadyOnTV += 1
                        setStatus(item.id, .alreadyOnTV)

                    case .ready(let fingerprint, let jpeg):
                        setStatus(item.id, .uploading)
                        let contentID: String
                        do {
                            contentID = try await connected.upload(jpeg: jpeg, matteID: matteID)
                        } catch FrameTVError.tvError(let request, let code) where matteID != "none" {
                            // The chosen mat isn't supported for this photo on this TV; fall back to no mat.
                            summary.notes.append("The TV didn't accept the mat “\(matteID)” (error \(code) on \(request)), so photos were uploaded without a mat.")
                            matteID = "none"
                            contentID = try await connected.upload(jpeg: jpeg, matteID: matteID)
                        }
                        bytesSent += jpeg.count

                        registry.add(UploadRecord(
                            contentID: contentID,
                            fingerprint: fingerprint,
                            matteID: matteID,
                            sourceName: item.name,
                            uploadedAt: Date()
                        ), for: host)
                        onTV.insert(contentID)
                        batchIDs.append(contentID)
                        summary.uploaded += 1
                        setStatus(item.id, .uploaded)
                    }
                } catch let error as FrameTVError where error.isConnectionFatal {
                    setStatus(item.id, .failed(error.localizedDescription))
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    summary.failed += 1
                    setStatus(item.id, .failed(error.localizedDescription))
                }
            }
            progress = 1

            if options.replacePrevious, !batchIDs.isEmpty {
                let keep = Set(batchIDs)
                let previous = registry.records(for: host)
                    .map(\.contentID)
                    .filter { !keep.contains($0) && onTV.contains($0) }
                if !previous.isEmpty {
                    statusText = "Removing \(previous.count) photo\(previous.count == 1 ? "" : "s") from your previous upload…"
                    try await connected.delete(contentIDs: previous)
                    registry.remove(contentIDs: previous, for: host)
                    summary.removed = previous.count
                }
            }

            if !batchIDs.isEmpty {
                statusText = "Updating Art Mode…"
                if options.slideshowEnabled {
                    do {
                        try await connected.setSlideshow(minutes: options.slideshowMinutes, shuffle: options.slideshowShuffle)
                        let order = options.slideshowShuffle ? "shuffled" : "in order"
                        summary.slideshowMessage = "Slideshow is on: My Photos changes \(SlideshowInterval.label(for: options.slideshowMinutes)), \(order)."
                    } catch {
                        summary.notes.append("Couldn't start the slideshow: \(error.localizedDescription)")
                    }
                } else {
                    try? await connected.selectImage(contentID: batchIDs[0])
                }
            }
        } catch is CancellationError {
            summary.cancelled = true
        } catch {
            summary.stopReason = error.localizedDescription
        }

        nextPhoto?.cancel()
        await client?.disconnect()
        for item in targets {
            if let current = items.first(where: { $0.id == item.id }),
               current.status == .waiting || current.status == .preparing || current.status == .uploading {
                setStatus(item.id, .pending)
            }
        }
        summary.bytesSent = bytesSent
        summary.elapsed = clock.now - started
        log.info("Batch finished: \(summary.uploaded) uploaded, \(summary.alreadyOnTV) skipped, \(summary.failed) failed, \(bytesSent / 1024) KB in \(summary.elapsed.description, privacy: .public)")
        statusText = summary.title
        self.summary = summary
    }

    private func setStatus(_ id: PhotoItem.ID, _ status: UploadStatus) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }
}
