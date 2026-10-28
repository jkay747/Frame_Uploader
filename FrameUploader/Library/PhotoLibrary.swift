import AppKit
import Photos

struct PhotoAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
}

enum PhotoLibraryError: LocalizedError {
    case accessDenied
    case assetMissing
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Frame Uploader doesn't have access to your Photos library. Allow it in System Settings › Privacy & Security › Photos."
        case .assetMissing:
            return "This photo is no longer in your Photos library."
        case .loadFailed(let reason):
            return "Couldn't load the photo from Photos (\(reason))."
        }
    }
}

/// Apple Photos access through PhotoKit.
enum PhotoLibrary {
    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Favorites plus every user album (including ones inside folders and shared albums).
    static func albums() -> [PhotoAlbum] {
        var albums: [PhotoAlbum] = []
        let imagesOnly = PHFetchOptions()
        imagesOnly.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        func collect(_ result: PHFetchResult<PHAssetCollection>) {
            result.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: imagesOnly).count
                guard count > 0 else { return }
                albums.append(PhotoAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled album",
                    count: count
                ))
            }
        }

        collect(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil))
        let userAlbums = PHFetchOptions()
        userAlbums.sortDescriptors = [NSSortDescriptor(key: "localizedTitle", ascending: true)]
        collect(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: userAlbums))
        return albums
    }

    /// The photos in an album, as (local identifier, file name).
    static func assets(inAlbum albumID: String) -> [(id: String, name: String)] {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else {
            return []
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        var assets: [(id: String, name: String)] = []
        PHAsset.fetchAssets(in: album, options: options).enumerateObjects { asset, _, _ in
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "Photo"
            assets.append((asset.localIdentifier, name))
        }
        return assets
    }

    static func albumTitle(_ albumID: String) -> String {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
            .firstObject?.localizedTitle ?? "Photos"
    }

    /// Full-resolution bytes of the current (edited) version, downloading from iCloud if needed.
    static func imageData(for identifier: String) async throws -> Data {
        let asset = try asset(identifier)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: loadError(from: info))
                }
            }
        }
    }

    static func previewImage(for identifier: String, maxPixelSize: Int) async throws -> CGImage {
        let asset = try asset(identifier)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast

        let size = CGSize(width: maxPixelSize, height: maxPixelSize)
        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(throwing: loadError(from: info))
                }
            }
        }
    }

    private static func asset(_ identifier: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw PhotoLibraryError.assetMissing
        }
        return asset
    }

    private static func loadError(from info: [AnyHashable: Any]?) -> Error {
        if let error = info?[PHImageErrorKey] as? Error {
            return PhotoLibraryError.loadFailed(error.localizedDescription)
        }
        if (info?[PHImageCancelledKey] as? Bool) == true {
            return CancellationError()
        }
        return PhotoLibraryError.loadFailed("no image data")
    }
}
