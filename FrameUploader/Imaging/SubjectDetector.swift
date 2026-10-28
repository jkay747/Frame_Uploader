import CoreGraphics
import Vision

/// The part of a photo that the crop should keep, in normalized coordinates with a top-left origin.
struct FocusRegion {
    let rect: CGRect
    let isFaces: Bool
}

enum SubjectDetector {
    /// Prefers faces; falls back to Vision's attention-based saliency (what a viewer looks at first).
    static func focusRegion(in image: CGImage) -> FocusRegion? {
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([faces, saliency])

        if let faceBoxes = faces.results?.map(\.boundingBox), !faceBoxes.isEmpty {
            // Ignore small faces in the background so they don't pull the crop off the main people.
            let largest = faceBoxes.map(\.height).max() ?? 0
            let prominent = faceBoxes.filter { $0.height >= largest * 0.4 }
            if let union = union(prominent) {
                return FocusRegion(rect: flipped(union), isFaces: true)
            }
        }

        if let objects = saliency.results?.first?.salientObjects,
           let union = union(objects.map(\.boundingBox)) {
            return FocusRegion(rect: flipped(union), isFaces: false)
        }
        return nil
    }

    private static func union(_ rects: [CGRect]) -> CGRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

    /// Vision uses a bottom-left origin; the crop planner uses top-left like CGImage.
    private static func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }
}
