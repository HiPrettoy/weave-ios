import Foundation
import UIKit
import Vision

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

/// 防止 continuation 被 resume 两次导致崩溃
private final class ResumeGuard {
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
