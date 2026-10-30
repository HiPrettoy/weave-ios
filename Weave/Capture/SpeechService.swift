import Foundation
import Speech
import AVFoundation

/// 用系统 Speech 框架做实时转写。所有 @Published 的写入都派发到主线程，
/// 因此这个类本身不加 @MainActor，避免在 View 的属性初始值里踩隔离检查。
///
/// Sendable：识别回调、音频 tap 线程、通知中心都会碰这个对象，编译器看不见
/// 我们靠主线程派发 + stateLock 维持的约定，所以显式声明 @unchecked，
/// 并把真正跨线程共享的可变状态（isFinishing / smoothedLevel）全部过锁。
final class SpeechService: ObservableObject, @unchecked Sendable {
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
    /// 用户已经按了停止：此后识别回调一律不再写 transcript。
    /// 否则 cancel 之后迟到的空结果会把已经识别出来的文字抹掉。
    /// 只在 stateLock 内读写 —— start/stop 与识别回调可能不在同一线程。
    private var isFinishing = false
    /// 保护 isFinishing 与 smoothedLevel
    private let stateLock = NSLock()
    /// 音频中断（来电、闹钟、其他 App 抢占）与耳机拔插的观察者
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?

    /// 电平用指数平滑，避免波形跟着单个 buffer 抖成噪点
    private var smoothedLevel: Double = 0

    deinit {
        removeSessionObservers()
    }

    // MARK: - 跨线程共享状态

    /// 标记进入收尾，返回「之前是否已经在收尾」
    private func beginFinishing() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let wasFinishing = isFinishing
        isFinishing = true
        return wasFinishing
    }

    private func resetFinishing() {
        stateLock.lock()
        defer { stateLock.unlock() }
        isFinishing = false
    }

    /// 输入一份新电平样本，返回平滑后的值
    private func absorbLevel(_ sample: Double) -> Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        smoothedLevel = smoothedLevel * 0.72 + sample * 0.28
        return smoothedLevel
    }

    private func resetLevel() {
        stateLock.lock()
        defer { stateLock.unlock() }
        smoothedLevel = 0
    }

    private func observeSession() {
        removeSessionObservers()
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
            switch type {
            case .began:
                // 来电时麦克风会被系统收走，引擎继续跑只会静默录到空音频，
                // 必须主动停下并告诉用户，否则看起来就是「说了半天没反应」。
                if self.isRecording {
                    self.stop(autoStopped: true)
                    self.errorMessage = String(localized: "被来电或其他 App 打断了，已经把识别到的内容保留下来")
                }
            case .ended:
                // 不自动续录：用户得自己决定还说不说，避免出现一段意外的空白录音
                break
            @unknown default:
                break
            }
        }
        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isRecording else { return }
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) else { return }
            // 拔耳机后系统会把输入切回听筒，采样率变了再往旧 request 里塞 buffer 会崩，
            // 这里干脆停下来让用户重按一次。
            if reason == .oldDeviceUnavailable {
                self.stop(autoStopped: true)
                self.errorMessage = String(localized: "音频设备变了，录音已停止，内容保留在上方")
            }
        }
    }

    private func removeSessionObservers() {
        let center = NotificationCenter.default
        if let interruptionObserver { center.removeObserver(interruptionObserver) }
        if let routeObserver { center.removeObserver(routeObserver) }
        interruptionObserver = nil
        routeObserver = nil
    }

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
                self.errorMessage = String(localized: "需要在系统设置里允许「语音识别」和「麦克风」")
            }
        }
        return granted
    }

    func start() {
        guard !isRecording else { return }
        resetFinishing()
        DispatchQueue.main.async {
            self.errorMessage = nil
            self.transcript = ""
        }

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
        self.recognizer = recognizer
        guard let recognizer, recognizer.isAvailable else {
            DispatchQueue.main.async {
                self.errorMessage = String(localized: "语音识别暂不可用，请检查网络，或在系统设置里开启听写")
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
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                // 真实电平：原来 level 声明了却从没赋值，波形是一条跟声音无关的正弦。
                guard let self else { return }
                let level = Self.rmsLevel(buffer)
                // 平滑放在回调线程算，只有最终值回主线程，避免每个 buffer 都派发一次
                let value = self.absorbLevel(level)
                DispatchQueue.main.async { self.level = value }
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
            observeSession()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    // 空结果一律不覆盖：短音频收尾时系统偶尔会回一条空的终稿，
                    // 直接写进去就会表现为「一按停止，刚说的话全没了」。
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DispatchQueue.main.async { self.transcript = text }
                    }
                }
                if error != nil {
                    DispatchQueue.main.async {
                        if self.isRecording { self.stop(autoStopped: true) }
                    }
                }
            }

            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = String(localized: "录音启动失败：\(error.localizedDescription)")
            }
            stop()
        }
    }

    /// autoStopped 表示是被系统中断/出错顺带停的，此时保留已经识别到的文字；
    /// 手动停止与自动停止都不清空 transcript，清空只发生在下一次 start()。
    func stop(autoStopped: Bool = false) {
        let alreadyStopping = beginFinishing()
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        // endAudio 后给识别任务一点时间交出终稿，再取消；直接 cancel 会丢掉最后一段
        if !autoStopped && !alreadyStopping {
            let pending = task
            task = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                pending?.cancel()
            }
        } else {
            task?.cancel()
            task = nil
        }
        request = nil
        removeSessionObservers()
        resetLevel()
        DispatchQueue.main.async {
            self.isRecording = false
            self.level = 0
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 归一化 RMS：取各声道平均，再映射到 0…1（-50dBFS 当作静音）。
    private static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Double = 0
        for index in 0..<frames {
            let sample = Double(channel[index])
            sum += sample * sample
        }
        let rms = (sum / Double(frames)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let normalized = (decibels + 50) / 50
        return min(1, max(0, normalized))
    }
}
