import UIKit

enum ImageTool {
    /// 长边压到 1600px，JPEG 质量 0.72：够 OCR，也不至于把 JSON 撑爆
    static func compressed(_ image: UIImage, maxDimension: CGFloat = 1600) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return image.jpegData(compressionQuality: 0.72)
        }

        let longest = max(size.width, size.height)
        var target = image
        if longest > maxDimension {
            let scale = maxDimension / longest
            let newSize = CGSize(width: (size.width * scale).rounded(),
                                 height: (size.height * scale).rounded())
            let renderer = UIGraphicsImageRenderer(size: newSize)
            target = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        return target.jpegData(compressionQuality: 0.72)
    }
}
