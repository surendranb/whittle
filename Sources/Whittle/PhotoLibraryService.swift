import AppKit
import Photos

/// Thin wrapper over PhotoKit: fetching assets, loading images, deleting.
enum PhotoLibraryService {

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func currentAuthorization() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// All image assets in the range, oldest first.
    static func fetchImageAssets(since start: Date?, until end: Date? = nil) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var predicates: [NSPredicate] = [
            NSPredicate(format: "(mediaSubtypes & %d) == 0",
                        PHAssetMediaSubtype.photoScreenshot.rawValue),
        ]
        if let start {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end {
            predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate))
        }
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    static func fetchAssets(withIdentifiers ids: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    /// Loads a downscaled image for an asset. iCloud originals are fetched
    /// over the network when needed.
    static func loadImage(for asset: PHAsset, maxDimension: CGFloat) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxDimension, height: maxDimension),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                // .highQualityFormat delivers exactly once, but guard anyway.
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    /// Total image assets in the library. Count-only fetch: no image loading.
    static func libraryImageCount() -> Int {
        PHAsset.fetchAssets(with: .image, options: nil).count
    }

    /// Total on-disk bytes of the given assets (original resources).
    static func totalFileSize(ofAssetsWithIdentifiers ids: [String]) -> Int64 {
        fetchAssets(withIdentifiers: ids).reduce(into: Int64(0)) { sum, asset in
            let resources = PHAssetResource.assetResources(for: asset)
            let size = (resources.first?.value(forKey: "fileSize") as? Int64) ?? 0
            sum += size
        }
    }

    /// Deletes assets. macOS shows its own confirmation dialog; items go to
    /// Photos' Recently Deleted (recoverable for ~30 days).
    static func deleteAssets(withIdentifiers ids: [String]) async throws {
        let assets = fetchAssets(withIdentifiers: ids)
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}

extension NSImage {
    var cgImageForVision: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func jpegData(quality: CGFloat) -> Data? {
        guard let cg = cgImageForVision else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
