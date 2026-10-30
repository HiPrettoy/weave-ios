import UIKit

enum ImageTool {
    /// 长边压到 1600px，JPEG 质量 0.72：够 OCR，也不至于把 JSON 撑爆。
    /// 这是纯 CPU 活（重绘 + 编码），调用方要放到后台队列，别在主线程直接跑。
    static func compressed(_ image: UIImage, maxDimension: CGFloat = 1600) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return image.jpegData(compressionQuality: 0.72)
        }

        // 相机原图方向常带 EXIF 标记，重绘时统一拉正，免得 OCR 与显示各朝向
        let longest = max(size.width, size.height)
        var target = image
        if longest > maxDimension || image.imageOrientation != .up {
            let scale = longest > maxDimension ? maxDimension / longest : 1
            let newSize = CGSize(width: (size.width * scale).rounded(),
                                 height: (size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            target = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        return target.jpegData(compressionQuality: 0.72)
    }
}
