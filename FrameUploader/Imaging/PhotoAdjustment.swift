import CoreGraphics

/// The user's per-photo choice of how it fills the screen.
struct PhotoAdjustment: Equatable, Sendable {
    enum Fit: String, CaseIterable, Sendable {
        /// Landscape photos are smart-cropped, portrait and square ones get a blurred fill.
        case automatic
        case smartCrop
        case blurredBackground

        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .smartCrop: return "Smart crop"
            case .blurredBackground: return "Blurred fill"
            }
        }
    }

    var fit: Fit = .automatic
    /// A crop chosen by hand, normalized to the upright photo with a top-left origin. Nil means the
    /// crop is picked automatically around faces and subjects.
    var crop: CGRect?

    var isDefault: Bool { fit == .automatic && crop == nil }

    /// The mode actually used for a photo of `size`.
    func resolvedMode(for size: CGSize) -> FitMode {
        switch fit {
        case .smartCrop: return .smartCrop
        case .blurredBackground: return .blurredBackground
        case .automatic:
            // A hand-placed crop implies cropping, even for a portrait photo.
            if crop != nil { return .smartCrop }
            return size.width > size.height ? .smartCrop : .blurredBackground
        }
    }

    /// Stable text identifying the adjustment, so a re-cropped photo counts as a different upload.
    /// Empty for the default, which keeps records made before adjustments existed valid.
    var key: String {
        guard !isDefault else { return "" }
        var key = "fit=\(fit.rawValue)"
        if let crop {
            key += String(format: ";crop=%.4f,%.4f,%.4f", crop.minX, crop.minY, crop.width)
        }
        return key
    }
}

extension CropPlanner {
    /// Widest crop of `aspect` that fits in the image, as a fraction of the image's width.
    static func maxCropWidthFraction(imageSize: CGSize, aspect: CGFloat) -> CGFloat {
        min(1, imageSize.height * aspect / imageSize.width)
    }

    /// The crop's height fraction for a given width fraction, keeping `aspect` in pixels.
    static func cropHeightFraction(widthFraction: CGFloat, imageSize: CGSize, aspect: CGFloat) -> CGFloat {
        widthFraction * imageSize.width / aspect / imageSize.height
    }

    /// Turns a normalized crop into pixels, keeping exactly `aspect` and staying inside the image.
    static func pixelRect(normalized crop: CGRect, imageSize: CGSize, aspect: CGFloat) -> CGRect {
        let maxWidth = maxCropWidthFraction(imageSize: imageSize, aspect: aspect) * imageSize.width
        let width = min(max(crop.width * imageSize.width, 16), maxWidth).rounded(.down)
        let height = min((width / aspect).rounded(.down), imageSize.height)
        let centerX = crop.midX * imageSize.width
        let centerY = crop.midY * imageSize.height
        let x = min(max(centerX - width / 2, 0), imageSize.width - width)
        let y = min(max(centerY - height / 2, 0), imageSize.height - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    /// Normalizes a pixel crop to fractions of the image.
    static func normalized(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: rect.minX / imageSize.width,
            y: rect.minY / imageSize.height,
            width: rect.width / imageSize.width,
            height: rect.height / imageSize.height
        )
    }
}
