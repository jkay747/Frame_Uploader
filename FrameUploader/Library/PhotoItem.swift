import CoreGraphics
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum PhotoOrigin: Hashable, Sendable {
    case file(URL)
    /// An Apple Photos asset, by its PhotoKit local identifier.
    case library(String)
}

enum UploadStatus: Equatable, Sendable {
    case pending
    case waiting
    case preparing
    case uploading
    case uploaded
    case alreadyOnTV
    case failed(String)

    var failureReason: String? {
        if case .failed(let reason) = self { return reason }
        return nil
    }
}

struct PhotoItem: Identifiable, Sendable {
    let id = UUID()
    let origin: PhotoOrigin
    let name: String
    /// Where it came from, shown under the name (folder or album).
    let group: String
    var isIncluded = true
    var status: UploadStatus = .pending
    /// How the photo fills the screen, if the user changed it.
    var adjustment = PhotoAdjustment()
}

enum PhotoLoader {
    /// The original file bytes; also what duplicate detection hashes.
    static func data(for origin: PhotoOrigin) async throws -> Data {
        switch origin {
        case .file(let url):
            return try await Task.detached(priority: .userInitiated) {
                do {
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                } catch {
                    throw PhotoFileError(url: url, underlying: error)
                }
            }.value
        case .library(let identifier):
            return try await PhotoLibrary.imageData(for: identifier)
        }
    }

    static func previewImage(for origin: PhotoOrigin, maxPixelSize: Int) async throws -> CGImage {
        switch origin {
        case .file(let url):
            return try await Task.detached(priority: .utility) {
                try ImageLoader.image(from: url, maxPixelSize: maxPixelSize)
            }.value
        case .library(let identifier):
            return try await PhotoLibrary.previewImage(for: identifier, maxPixelSize: maxPixelSize)
        }
    }

    static func fingerprint(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Explains why a photo file couldn't be read, in terms the user can act on.
struct PhotoFileError: LocalizedError {
    let url: URL
    let underlying: Error

    var errorDescription: String? {
        if !FileManager.default.fileExists(atPath: url.path) {
            return "The file was moved or deleted after it was added."
        }
        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
        if let status, status != .current {
            return "This file is stored in iCloud and couldn't be downloaded. Download it in Finder (right-click › Download Now), then try again."
        }
        return "Couldn't read the file: \(underlying.localizedDescription)"
    }
}

/// The photos found in what the user added, plus counts of what was left out and why.
struct FolderScanResult {
    var files: [URL] = []
    var videos = 0
    var unsupported = 0
    var cloudOnly = 0

    /// A short note about skipped files, or nil when nothing was skipped.
    var skippedSummary: String? {
        var parts: [String] = []
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        if unsupported > 0 { parts.append("\(unsupported) file\(unsupported == 1 ? "" : "s") in formats the TV can't show as a still (GIF, SVG, PDF)") }
        if cloudOnly > 0 { parts.append("\(cloudOnly) photo\(cloudOnly == 1 ? "" : "s") stored only in iCloud (download \(cloudOnly == 1 ? "it" : "them") in Finder first)") }
        guard !parts.isEmpty else { return nil }
        return "Skipped " + parts.joined(separator: ", ") + "."
    }
}

enum FolderScanner {
    /// Animated and vector formats don't make sense as a still on the TV.
    private static let excludedTypes: [UTType] = [.gif, .svg, .pdf, .ico, .icns]

    /// Image files in the given files and folders (searching subfolders), in Finder order.
    static func scan(_ urls: [URL]) -> FolderScanResult {
        var result = FolderScanResult()
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else {
                classify(url, into: &result)
                continue
            }
            var found = FolderScanResult()
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentTypeKey],
                options: [.skipsPackageDescendants]
            )
            while let file = enumerator?.nextObject() as? URL {
                let name = file.lastPathComponent
                if name.hasPrefix(".") {
                    // Hidden files are skipped, except older iCloud placeholders (".IMG_1234.jpg.icloud").
                    if name.hasSuffix(".icloud") {
                        found.cloudOnly += 1
                    } else if (try? file.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                        enumerator?.skipDescendants()
                    }
                    continue
                }
                classify(file, into: &found)
            }
            found.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            result.files += found.files
            result.videos += found.videos
            result.unsupported += found.unsupported
            result.cloudOnly += found.cloudOnly
        }
        return result
    }

    private static func classify(_ url: URL, into result: inout FolderScanResult) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
              values.isRegularFile == true,
              let type = values.contentType
        else {
            return
        }
        if type.conforms(to: .movie) {
            result.videos += 1
        } else if type.conforms(to: .image) {
            if excludedTypes.contains(where: { type.conforms(to: $0) }) {
                result.unsupported += 1
            } else {
                result.files.append(url)
            }
        }
        // Anything else (sidecar .AAE/.XMP files, documents) isn't a photo and isn't worth mentioning.
    }
}
