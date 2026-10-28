import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

enum FitMode: Sendable {
    /// Landscape photos fill the screen, cropped around the subject.
    case smartCrop
    /// Portrait and square photos are shown whole over a blurred copy of themselves.
    case blurredBackground

    var label: String {
        switch self {
        case .smartCrop: return "Smart crop"
        case .blurredBackground: return "Blurred fill"
        }
    }

    var systemImage: String {
        switch self {
        case .smartCrop: return "crop"
        case .blurredBackground: return "rectangle.center.inset.filled"
        }
    }
}

enum PhotoProcessingError: LocalizedError {
    case unreadableImage
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "This file couldn't be read as an image."
        case .renderFailed: return "The photo couldn't be resized."
        }
    }
}

/// Turns any photo into a 3840×2160 image for the Frame TV.
final class PhotoProcessor: @unchecked Sendable {
    static let shared = PhotoProcessor()

    /// The Frame's native resolution.
    static let tvSize = CGSize(width: 3840, height: 2160)
    static let previewSize = CGSize(width: 480, height: 270)

    private let colorSpace: CGColorSpace
    private let ciContext: CIContext

    init() {
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        ciContext = CIContext(options: [.workingColorSpace: colorSpace])
    }

    // MARK: - Entry points

    /// Full-quality JPEG ready to upload.
    func makeTVImage(from data: Data) throws -> (jpeg: Data, mode: FitMode) {
        let image = try ImageLoader.image(from: data, maxPixelSize: nil)
        let (rendered, mode) = try render(image, outputSize: Self.tvSize)
        return (try jpegData(rendered, quality: 0.92), mode)
    }

    /// Small version of exactly what the TV will show.
    func makePreview(from image: CGImage) throws -> (image: CGImage, mode: FitMode) {
        try render(image, outputSize: Self.previewSize)
    }

    // MARK: - Rendering

    func render(_ image: CGImage, outputSize: CGSize) throws -> (CGImage, FitMode) {
        let isLandscape = image.width > image.height
        guard let context = CGContext(
            data: nil,
            width: Int(outputSize.width),
            height: Int(outputSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw PhotoProcessingError.renderFailed
        }
        context.interpolationQuality = .high
        let canvas = CGRect(origin: .zero, size: outputSize)

        if isLandscape {
            try drawSmartCrop(image, in: context, canvas: canvas)
        } else {
            try drawBlurredFill(image, in: context, canvas: canvas)
        }

        guard let result = context.makeImage() else { throw PhotoProcessingError.renderFailed }
        return (result, isLandscape ? .smartCrop : .blurredBackground)
    }

    private func drawSmartCrop(_ image: CGImage, in context: CGContext, canvas: CGRect) throws {
        let focus = SubjectDetector.focusRegion(in: image)
        let crop = CropPlanner.cropRect(
            imageSize: CGSize(width: image.width, height: image.height),
            aspect: canvas.width / canvas.height,
            focus: focus?.rect,
            focusIsFaces: focus?.isFaces ?? false
        )
        guard let cropped = image.cropping(to: crop) else { throw PhotoProcessingError.renderFailed }
        context.draw(cropped, in: canvas)
    }

    private func drawBlurredFill(_ image: CGImage, in context: CGContext, canvas: CGRect) throws {
        // Blur at quarter size: it's invisible once stretched and far faster than blurring at 4K.
        let background = try blurredBackground(for: image, size: CGSize(width: canvas.width / 4, height: canvas.height / 4))
        context.draw(background, in: canvas)

        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let frame = CGRect(
            x: ((canvas.width - fitted.width) / 2).rounded(),
            y: ((canvas.height - fitted.height) / 2).rounded(),
            width: fitted.width.rounded(),
            height: fitted.height.rounded()
        )

        // A soft shadow lifts the photo off its background.
        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: canvas.height * 0.03,
            color: CGColor(gray: 0, alpha: 0.55)
        )
        context.draw(image, in: frame)
        context.restoreGState()
    }

    private func blurredBackground(for image: CGImage, size: CGSize) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let scale = max(size.width / input.extent.width, size.height / input.extent.height)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY
        ))

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = centered.clampedToExtent()
        blur.radius = Float(size.width * 0.035)

        let tone = CIFilter.colorControls()
        tone.inputImage = blur.outputImage
        tone.saturation = 1.1
        tone.brightness = -0.06

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = tone.outputImage
        exposure.ev = -0.5

        guard let output = exposure.outputImage,
              let rendered = ciContext.createCGImage(
                  output,
                  from: CGRect(origin: .zero, size: size),
                  format: .RGBA8,
                  colorSpace: colorSpace
              )
        else {
            throw PhotoProcessingError.renderFailed
        }
        return rendered
    }

    private func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoProcessingError.renderFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoProcessingError.renderFailed }
        return data as Data
    }
}

/// Decodes JPEG, PNG, HEIC, TIFF, RAW and anything else ImageIO understands, with EXIF rotation applied.
enum ImageLoader {
    static func image(from data: Data, maxPixelSize: Int?) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoProcessingError.unreadableImage
        }
        return try image(from: source, maxPixelSize: maxPixelSize)
    }

    static func image(from url: URL, maxPixelSize: Int?) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotoProcessingError.unreadableImage
        }
        return try image(from: source, maxPixelSize: maxPixelSize)
    }

    private static func image(from source: CGImageSource, maxPixelSize: Int?) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let fullSize = max(width, height)
        // Very large images (e.g. stitched panoramas) are capped; 4K output never needs more.
        let limit = min(maxPixelSize ?? fullSize, 12_000)

        // The thumbnail API is the simplest way to get an upright, decoded image at a chosen size.
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if limit > 0 {
            options[kCGImageSourceThumbnailMaxPixelSize] = limit
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoProcessingError.unreadableImage
        }
        return image
    }
}
