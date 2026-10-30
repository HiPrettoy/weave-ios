import SwiftUI
import PhotosUI
import UIKit

struct PhotoCaptureView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var compressed: Data?
    @State private var text = ""
    @State private var tagText = ""
    @StateObject private var ai = AIExtractor()
    @State private var isRecognizing = false
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var hint: String?
    @State private var showFullImage = false
    @State private var autoOpenedCamera = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    preview
                    actions
                    if let hint {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if image != nil {
                        editor
                        if !isRecognizing {
                            aiPanel
                            tagField
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("拍照记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .fontWeight(.semibold)
                        .disabled(isRecognizing)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(onImage: { picked in
                    showCamera = false
                    Task { await handle(picked) }
                }, onCancel: {
                    // 取消后留在本页，「从相册选」就在下面
                    showCamera = false
                })
                .ignoresSafeArea()
            }
            .fullScreenCover(isPresented: $showFullImage) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    }
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                showFullImage = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .scaledFont(28, relativeTo: .title2)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .padding(16)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .onChange(of: pickerItem?.itemIdentifier) { _ in
                loadFromLibrary()
            }
            // 从首页点「拍照」进来就直接是相机，取消后回到本页再从相册选。
            // 刚 present 完立刻再弹 cover 会被系统吞掉，所以等一拍再弹。
            .task {
                guard !autoOpenedCamera, image == nil else { return }
                autoOpenedCamera = true
                try? await Task.sleep(nanoseconds: 420_000_000)
                if image == nil && !showCamera { showCamera = true }
            }
        }
    }

    // MARK: - 部件

    private var preview: some View {
        ZStack {
            Theme.card

            if let image {
                // 只给高度不给宽度时，scaledToFill 会按原图长宽比把宽度撑到屏幕外，
                // 整个 ZStack 跟着变宽，看起来就是「图突然变大、显示不全」。
                // 这里把外框尺寸钉死，再用 fit 保证整张图都在框里；点一下能看大图。
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.viewfinder")
                        .scaledFont(34, weight: .light, relativeTo: .largeTitle)
                        .foregroundStyle(Theme.inkSoft.opacity(0.7))
                    Text("拍书页、板书、PPT，自动把字抠出来")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                }
            }

            if isRecognizing {
                ZStack {
                    Color.black.opacity(0.35)
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在识别文字…")
                            .font(.footnote)
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.hairline.opacity(0.5), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture {
            if image != nil { showFullImage = true }
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                showCamera = true
            } label: {
                Label("拍照", systemImage: "camera.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accentFill))
                    .foregroundStyle(.white)
            }

            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("从相册选", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("识别到的文字（可修改）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Text("\(text.count) 字")
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft)
            }
            TextEditor(text: $text)
                .frame(minHeight: 160)
                .scrollContentBackground(.hidden)
                .font(.body)
        }
        .card()
    }

    private var aiPanel: some View {
        AIExtractPanel(extractor: ai,
                       text: text,
                       onTags: { incoming in
                           tagText = mergeTags(existing: tagText, incoming: incoming)
                       })
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标签（可选）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.inkSoft)
            TextField("#课堂 #读书", text: $tagText)
                .font(.subheadline)
        }
        .card()
    }

    // MARK: - 逻辑

    private func loadFromLibrary() {
        guard let pickerItem else { return }
        Task {
            if let data = try? await pickerItem.loadTransferable(type: Data.self),
               let picked = UIImage(data: data) {
                await handle(picked)
            } else {
                hint = "这张图片读不出来，换一张试试"
            }
            // 取完就清空选择：否则再选同一张图时 itemIdentifier 没变，
            // onChange 不触发，界面看起来就是「点了没反应」。
            self.pickerItem = nil
        }
    }

    private func handle(_ picked: UIImage) async {
        image = picked
        isRecognizing = true
        hint = nil
        // 缩放 + JPEG 编码是纯 CPU 活，原来在主线程做，选大图会卡住界面；
        // 挪到后台，OCR 也一起等它。
        let scaled = await Task.detached(priority: .userInitiated) {
            ImageTool.compressed(picked)
        }.value
        compressed = scaled
        let recognized = await OCRService.recognize(in: picked)
        isRecognizing = false
        if recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hint = "没识别到文字。可以自己补一句描述，图片会一起存下来。"
        } else {
            text = recognized
            hint = "识别完成，可以再改一改"
        }
    }

    private func save() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = body.split(separator: "\n").first.map(String.init) ?? ""
        guard store.add(content: body,
                        title: String(title.prefix(30)),
                        tags: parseTags(tagText),
                        source: .photo,
                        imageData: compressed,
                        summary: ai.summary,
                        concepts: ai.concepts) != nil else {
            Haptics.warning()
            hint = "没有正文也没有图片，这条没能存下"
            return
        }
        Haptics.success()
        dismiss()
    }
}

// MARK: - 系统相机

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let picked = info[.originalImage] as? UIImage {
                // 由 fullScreenCover 的 binding 负责关闭，这里不再 dismiss
                parent.onImage(picked)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
