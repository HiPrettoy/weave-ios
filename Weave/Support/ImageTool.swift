import UIKit

enum ImageTool {
    /// 长边压到 1280 **像素**，JPEG 质量 0.68：OCR 够用，单张约 150~200 KB。
    ///
    /// 之前这里踩过一个坑：判断长度用的是 `image.size`，那是 **point** 不是像素。
    /// 相机出的图常见 1200×1600 pt，而 scale 是 3，实际 3600×4800 像素 ——
    /// `longest > 1600` 比下来 1600 不大于 1600，于是整张原图（3.1 MB）被原样存进 JSON。
    /// 现在一律按 `cgImage` 的像素尺寸判断。
    ///
    /// 这是纯 CPU 活（重绘 + 编码），调用方要放到后台队列，别在主线程直接跑。
    static func compressed(_ image: UIImage,
                           maxDimension: CGFloat = 1280,
                           quality: CGFloat = 0.68) -> Data? {
        let pixels = pixelSize(of: image)
        guard pixels.width > 0, pixels.height > 0 else {
            return image.jpegData(compressionQuality: quality)
        }

        // 相机原图方向常带 EXIF 标记，重绘时统一拉正，免得 OCR 与显示各朝向
        let longest = max(pixels.width, pixels.height)
        var target = image
        if longest > maxDimension || image.imageOrientation != .up {
            let scale = longest > maxDimension ? maxDimension / longest : 1
            let newSize = CGSize(width: (pixels.width * scale).rounded(),
                                 height: (pixels.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat.default()
            // scale = 1 让「1 point 就是 1 像素」，尺寸才和上面的像素数对得上
            format.scale = 1
            // 先铺白底再画：截图类图片带 alpha，直接转 JPEG 会让透明区变黑
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            target = renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: newSize))
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        return target.jpegData(compressionQuality: quality)
    }

    /// 真正的像素尺寸。没有 cgImage 时退回 `size * scale` 估算。
    static func pixelSize(of image: UIImage) -> CGSize {
        if let cgImage = image.cgImage {
            return CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        }
        let scale = image.scale > 0 ? image.scale : 1
        return CGSize(width: (image.size.width * scale).rounded(),
                      height: (image.size.height * scale).rounded())
    }
}
