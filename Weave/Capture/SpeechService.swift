import Foundation
import Speech
import AVFoundation

/// 用系统 Speech 框架做实时转写。所有 @Published 的写入都派发到主线程，
/// 因此这个类本身不加 @MainActor，避免在 View 的属性初始值里踩隔离检查。
final class SpeechService: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?
    @Published var permissionDenied = false
    @Published var level: Double = 0

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false

    func requestPermissions() async -> Bool {
        let speechGranted: Bool = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        let micGranted: Bool = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        let granted = speechGranted && micGranted
        DispatchQueue.main.async {
            self.permissionDenied = !granted
            if !granted {
                self.errorMessage = "需要在系统设置里允许「语音识别」和「麦克风」"
            }
        }
        return granted
    }

    func start() {
        guard !isRecording else { return }
        DispatchQueue.main.async {
            self.errorMessage = nil
            self.transcript = ""
        }

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        self.recognizer = recognizer
        guard let recognizer, recognizer.isAvailable else {
            DispatchQueue.main.async {
                self.errorMessage = "语音识别暂不可用，请检查网络，或在系统设置里开启听写"
            }
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            if tapInstalled {
                input.removeTap(onBus: 0)
                tapInstalled = false
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    DispatchQueue.main.async { self.transcript = text }
                }
                if error != nil {
                    DispatchQueue.main.async {
                        if self.isRecording { self.stop() }
                    }
                }
            }

            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "录音启动失败：\(error.localizedDescription)"
            }
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        DispatchQueue.main.async { self.isRecording = false }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
