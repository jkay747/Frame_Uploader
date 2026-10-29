import Foundation
import os
import SwiftUI

struct UploadSummary: Identifiable {
    let id = UUID()
    var uploaded = 0
    var alreadyOnTV = 0
    var removed = 0
    var slideshowMessage: String?
    var notes: [String] = []
    var stopReason: String?
    var cancelled = false
    var bytesSent = 0
    var elapsed: Duration = .zero
    var reconnects = 0
    /// Each photo that didn't make it, with the reason.
    var failures: [(name: String, reason: String)] = []

    var failed: Int { failures.count }

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
        if failed > 0 {
            lines.append("\(failed) photo\(failed == 1 ? "" : "s") didn't upload:")
            let shown = 8
            for failure in failures.prefix(shown) {
                lines.append("• \(failure.name): \(failure.reason)")
            }
            if failures.count > shown {
                lines.append("• …and \(failures.count - shown) more. Each one is marked in the window with its reason.")
            }
        }
        if uploaded > 0 {
            let megabytes = Double(bytesSent) / 1_000_000
            let seconds = Double(elapsed.components.seconds)
            let perPhoto = seconds / Double(uploaded + alreadyOnTV)
            lines.append(String(format: "Sent %.1f MB in %.0f s (about %.1f s per photo).", megabytes, seconds, perPhoto))
        }
        if removed > 0 { lines.append("Removed \(removed) photo\(removed == 1 ? "" : "s") from your previous upload.") }
        if let slideshowMessage { lines.append(slideshowMessage) }
        if reconnects > 0 {
            lines.append("The connection to the TV dropped and was restored \(reconnects == 1 ? "once" : "\(reconnects) times").")
        }
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
    var failedCount: Int { items.filter { $0.isIncluded && $0.status.failureReason != nil }.count }

    // MARK: - Adding and removing photos

    func add(urls: [URL]) {
        guard !urls.isEmpty else { return }
        isScanning = true
        Task {
            let scan = await Task.detached(priority: .userInitiated) {
                FolderScanner.scan(urls)
            }.value
            let newItems = scan.files.map { url in
                PhotoItem(origin: .file(url), name: url.lastPathComponent, group: url.deletingLastPathComponent().lastPathComponent)
            }
            append(newItems)
            isScanning = false
            if scan.files.isEmpty {
                statusText = "No photos found in what you added."
            }
            if let skipped = scan.skippedSummary {
                statusText += " " + skipped
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
        start(targets: items.filter(\.isIncluded), options: .current())
    }

    /// Uploads only the photos that failed last time.
    func retryFailed() {
        var options = UploadOptions.current()
        // A retry is a partial batch: "replace previous" would delete the photos that did upload.
        options.replacePrevious = false
        start(targets: items.filter { $0.isIncluded && $0.status.failureReason != nil }, options: options)
    }

    private func start(targets: [PhotoItem], options: UploadOptions) {
        guard uploadTask == nil, !targets.isEmpty else { return }
        uploadTask = Task {
            await runUpload(targets: targets, options: options)
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

    private func runUpload(targets: [PhotoItem], options: UploadOptions) async {
        isWorking = true
        progress = 0
        defer { isWorking = false }

        let clock = ContinuousClock()
        let started = clock.now
        for item in targets { setStatus(item.id, .waiting) }

        var summary = UploadSummary()
        var client: FrameArtClient?
        var nextPhoto: Task<PreparedPhoto, Error>?
        var bytesSent = 0

        do {
            statusText = "Connecting to your TV… The first time, select Allow on the TV with your remote."
            let (firstConnection, host) = try await connectToTV(host: options.host)
            var connected = firstConnection
            client = connected

            statusText = "Checking what's already on the TV…"
            var onTV = Set(try await connected.contentIDs())
            registry.prune(host: host, keepingOnly: onTV)

            // Everything in this batch, whether uploaded now or already there.
            var batchIDs: [String] = []
            var matteID = options.matteID
            var reconnectsLeft = 5

            /// Opens a fresh connection after the TV dropped the old one (it dozes off or restarts its art app).
            func reconnect(after error: Error) async throws {
                guard reconnectsLeft > 0 else { throw error }
                reconnectsLeft -= 1
                log.error("Reconnecting after: \(error.localizedDescription, privacy: .public)")
                let previousStatus = statusText
                statusText = "Lost the connection to the TV. Reconnecting…"
                await connected.disconnect()
                connected = try await FrameArtClient.connected(to: host)
                client = connected
                summary.reconnects += 1
                statusText = previousStatus
            }

            /// Runs a TV command, reconnecting and trying once more if the connection dropped.
            func withReconnect<T>(_ operation: (FrameArtClient) async throws -> T) async throws -> T {
                do {
                    return try await operation(connected)
                } catch let error as FrameTVError where error.isConnectionDrop {
                    try await reconnect(after: error)
                    return try await operation(connected)
                }
            }

            /// Uploads one photo and returns its content ID on the TV.
            func send(_ jpeg: Data) async throws -> String {
                do {
                    return try await withReconnect { try await $0.upload(jpeg: jpeg, matteID: matteID) }
                } catch FrameTVError.uploadNotConfirmed {
                    // Start a fresh session so a late confirmation can't be credited to the next photo,
                    // then check whether the TV saved the photo without saying so.
                    try await reconnect(after: FrameTVError.uploadNotConfirmed)
                    let newOnTV = Set(try await connected.contentIDs()).subtracting(onTV)
                    if newOnTV.count == 1, let contentID = newOnTV.first {
                        log.info("Upload confirmed late via the content list")
                        return contentID
                    }
                    throw FrameTVError.uploadNotConfirmed
                } catch FrameTVError.tvError("send_image", let code) where matteID != "none" {
                    // Maybe the mat is the problem. If the photo also fails without one, report that error.
                    let rejected = matteID
                    let contentID = try await withReconnect { try await $0.upload(jpeg: jpeg, matteID: "none") }
                    matteID = "none"
                    summary.notes.append("The TV didn't accept the mat “\(Matte.displayName(rejected))” (Samsung error \(code)), so photos were uploaded without a mat.")
                    return contentID
                }
            }

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
                            let mat = matteID
                            try await withReconnect { try await $0.changeMatte(contentID: existing.contentID, matteID: mat) }
                            registry.updateMatte(contentID: existing.contentID, matteID: matteID, for: host)
                        }
                        batchIDs.append(existing.contentID)
                        summary.alreadyOnTV += 1
                        setStatus(item.id, .alreadyOnTV)

                    case .ready(let fingerprint, let jpeg):
                        setStatus(item.id, .uploading)
                        let contentID = try await send(jpeg)
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
                    // Reconnecting already failed; the photos left are marked once the batch winds down.
                    throw error
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log.error("\(item.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    summary.failures.append((item.name, error.localizedDescription))
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
                    try await withReconnect { try await $0.delete(contentIDs: previous) }
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
        // Photos the batch never got to: say why instead of quietly resetting them.
        for item in targets {
            guard let current = items.first(where: { $0.id == item.id }),
                  [.waiting, .preparing, .uploading].contains(current.status)
            else {
                continue
            }
            if let stopReason = summary.stopReason {
                summary.failures.append((item.name, "Not sent because the upload stopped."))
                setStatus(item.id, .failed("Not sent because the upload stopped: \(stopReason)"))
            } else {
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
