import SwiftUI

struct VoiceCaptureView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var speech = SpeechService()
    @StateObject private var ai = AIExtractor()
    @State private var edited = ""
    @State private var tagText = ""
    @State private var requestedPermission = false
    /// 上一次收到的完整转写，用来算增量。
    /// 原来每次回调都拿 prefix + 整段覆盖输入框，录音期间手工改的字会被抹掉；
    /// 改成只追加新识别出来的那一段，用户边录边改也不会丢。
    @State private var lastTranscript = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    waveform
                    recordButton

                    if let error = speech.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Color.red.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }

                    transcriptBox

                    if !speech.isRecording && !edited.isEmpty {
                        aiPanel
                        tagField
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("语音记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        speech.stop()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                guard !requestedPermission else { return }
                requestedPermission = true
                let granted = await speech.requestPermissions()
                if granted { speech.start() }
            }
            .onChange(of: speech.transcript) { newValue in
                absorbTranscript(newValue)
            }
            .onDisappear {
                speech.stop()
            }
        }
    }

    private var waveform: some View {
        // 用真实电平驱动：原来是一条与声音无关的正弦动画，
        // 麦克风没收到任何东西时它也照样跳。
        HStack(spacing: 4) {
            ForEach(0..<28, id: \.self) { index in
                let tap = speech.isRecording ? speech.level : 0
                // 中间高两边低，让电平看起来像一根柱子而不是整排齐平
                let center = 1 - abs(Double(index) - 13.5) / 13.5
                let shape = 0.35 + center * 0.65
                let height = speech.isRecording
                    ? CGFloat(6 + (4 + tap * 46) * shape)
                    : 6
                Capsule()
                    .fill(speech.isRecording
                          ? Theme.accent.opacity(0.35 + tap * 0.55)
                          : Theme.inkSoft.opacity(0.2))
                    .frame(width: 3.5, height: height)
                    .animation(.easeOut(duration: 0.12), value: height)
            }
        }
        .frame(height: 56)
    }

    private var recordButton: some View {
        Button {
            Haptics.tap()
            if speech.isRecording {
                // 停止前把当前累积结果再吸一次：终稿可能在 isRecording 变 false 之后才到
                absorbTranscript(speech.transcript)
                speech.stop()
            } else {
                lastTranscript = ""
                speech.start()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(speech.isRecording ? Color.red.opacity(0.14) : Theme.accentSoft)
                    .frame(width: 96, height: 96)
                Circle()
                    .fill(speech.isRecording ? Color.red : Theme.accent)
                    .frame(width: 68, height: 68)
                Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private var transcriptBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(speech.isRecording ? "正在听…" : "转写结果（可编辑）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                if !edited.isEmpty {
                    Text("\(edited.count) 字")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
            TextEditor(text: $edited)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .font(.body)
        }
        .card()
    }

    private var aiPanel: some View {
        AIExtractPanel(extractor: ai,
                       text: edited,
                       onTags: { merged in appendTags(merged) })
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标签（可选）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSoft)
            TextField("#学习 #会议", text: $tagText)
                .font(.subheadline)
        }
        .card()
    }

    /// 系统实时转写会不断重写前面已经识别过的字，所以不能整段覆盖输入框。
    /// 这里用最长公共前缀挑出「这一轮真正新增的部分」，只把增量追加进去，
    /// 录音中途手工改的字就保住了。停止之后迟到的终稿也走这里（有公共前缀去重，不会重复）。
    private func absorbTranscript(_ full: String) {
        guard !full.isEmpty, full != lastTranscript else { return }
        let common = Self.sharedPrefixLength(full, lastTranscript)
        let addition = String(full.dropFirst(common))
        lastTranscript = full
        guard !addition.isEmpty else { return }
        edited += addition
    }

    private static func sharedPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var left = lhs.makeIterator()
        var right = rhs.makeIterator()
        while let a = left.next(), let b = right.next(), a == b {
            count += 1
        }
        return count
    }

    private func appendTags(_ incoming: [String]) {
        tagText = mergeTags(existing: tagText, incoming: incoming)
    }

    private func save() {
        let text = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        speech.stop()
        _ = store.add(content: text,
                      tags: parseTags(tagText),
                      source: .voice,
                      summary: ai.summary,
                      concepts: ai.concepts)
        Haptics.success()
        dismiss()
    }
}
