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
}

struct PhotoItem: Identifiable, Sendable {
    let id = UUID()
    let origin: PhotoOrigin
    let name: String
    /// Where it came from, shown under the name (folder or album).
    let group: String
    var isIncluded = true
    var status: UploadStatus = .pending
}

enum PhotoLoader {
    /// The original file bytes; also what duplicate detection hashes.
    static func data(for origin: PhotoOrigin) async throws -> Data {
        switch origin {
        case .file(let url):
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
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

enum FolderScanner {
    /// Image files in the given files and folders (searching subfolders), in Finder order.
    static func imageFiles(in urls: [URL]) -> [URL] {
        var results: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                var found: [URL] = []
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let file = enumerator?.nextObject() as? URL {
                    if isSupportedImage(file) { found.append(file) }
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                results += found
            } else if isSupportedImage(url) {
                results.append(url)
            }
        }
        return results
    }

    static func isSupportedImage(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
              values.isRegularFile == true,
              let type = values.contentType
        else {
            return false
        }
        // Animated and vector formats don't make sense as a still on the TV.
        let excluded: [UTType] = [.gif, .svg, .pdf, .ico, .icns]
        return type.conforms(to: .image) && !excluded.contains { type.conforms(to: $0) }
    }
}
