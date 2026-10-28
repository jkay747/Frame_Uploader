import CoreGraphics

/// Pure geometry for choosing the 16:9 crop of a photo.
enum CropPlanner {
    /// Returns the largest `aspect`-shaped rectangle inside an image of `imageSize`, positioned to keep
    /// `focus` (normalized, top-left origin) in frame. Faces sit a little above center, like a portrait.
    static func cropRect(imageSize: CGSize, aspect: CGFloat, focus: CGRect?, focusIsFaces: Bool) -> CGRect {
        let width = imageSize.width
        let height = imageSize.height
        var cropWidth = width
        var cropHeight = height
        if width / height > aspect {
            cropWidth = (height * aspect).rounded(.down)
        } else {
            cropHeight = (width / aspect).rounded(.down)
        }

        guard let focus = focus?.standardized, focus.width > 0, focus.height > 0 else {
            return CGRect(
                x: ((width - cropWidth) / 2).rounded(),
                y: ((height - cropHeight) / 2).rounded(),
                width: cropWidth,
                height: cropHeight
            )
        }

        let subject = CGRect(
            x: focus.minX * width,
            y: focus.minY * height,
            width: focus.width * width,
            height: focus.height * height
        )

        var x = subject.midX - cropWidth / 2
        var y = subject.midY - cropHeight * (focusIsFaces ? 0.42 : 0.5)

        // When the subject fits, nudge the crop so none of it is cut off.
        if subject.width <= cropWidth {
            x = min(max(x, subject.maxX - cropWidth), subject.minX)
        }
        if subject.height <= cropHeight {
            y = min(max(y, subject.maxY - cropHeight), subject.minY)
        }

        x = min(max(x, 0), width - cropWidth)
        y = min(max(y, 0), height - cropHeight)
        return CGRect(x: x.rounded(), y: y.rounded(), width: cropWidth, height: cropHeight)
    }
}
