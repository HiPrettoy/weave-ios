import Foundation
import UIKit
// Vision 的类型还没标 Sendable，但 VNImageRequestHandler.perform 本身是线程安全的
// 一次性调用。用 @preconcurrency 压掉「捕获到非 Sendable 的 request」这类噪音警告，
// 而不是把整个模块的并发检查关掉。
@preconcurrency import Vision

/// 端上 OCR：Vision 的文字识别，中文英文都能认，完全离线。
enum OCRService {
    static func recognize(in image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }

        return await withCheckedContinuation { continuation in
            let guardFlag = ResumeGuard()

            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                guardFlag.resumeOnce(continuation, with: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                    try handler.perform([request])
                } catch {
                    guardFlag.resumeOnce(continuation, with: "")
                }
            }
        }
    }
}

/// 防止 continuation 被 resume 两次导致崩溃。
/// 内部状态全部由 NSLock 保护，跨线程传递是安全的，但编译器看不出来，
/// 所以显式声明 @unchecked Sendable（这个"unchecked"是我们自己保证的）。
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func resumeOnce(_ continuation: CheckedContinuation<String, Never>, with value: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        continuation.resume(returning: value)
    }
}
