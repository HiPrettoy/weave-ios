import SwiftUI

struct VoiceCaptureView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var speech = SpeechService()
    @State private var edited = ""
    @State private var tagText = ""
    @State private var requestedPermission = false

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
                edited = newValue
            }
            .onDisappear {
                speech.stop()
            }
        }
    }

    private var waveform: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !speech.isRecording)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<28, id: \.self) { index in
                    let wave = sin(phase * 4 + Double(index) * 0.55)
                    let height = speech.isRecording ? CGFloat(14 + abs(wave) * 40) : 6
                    Capsule()
                        .fill(speech.isRecording
                              ? Theme.accent.opacity(0.35 + abs(wave) * 0.55)
                              : Theme.inkSoft.opacity(0.2))
                        .frame(width: 3.5, height: height)
                }
            }
            .frame(height: 56)
        }
    }

    private var recordButton: some View {
        Button {
            Haptics.tap()
            if speech.isRecording {
                speech.stop()
                edited = speech.transcript
            } else {
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

    private func save() {
        let text = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        speech.stop()
        _ = store.add(content: text, tags: parseTags(tagText), source: .voice)
        Haptics.success()
        dismiss()
    }
}
