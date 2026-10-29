import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @AppStorage(Prefs.llmEnabled) private var llmEnabled = false
    @AppStorage(Prefs.llmBaseURL) private var llmBaseURL = "https://api.deepseek.com"
    @AppStorage(Prefs.llmModel) private var llmModel = "deepseek-chat"
    @AppStorage(Prefs.llmKey) private var llmKey = ""
    @AppStorage(Prefs.linkThreshold) private var threshold = 0.18
    @AppStorage(Prefs.linkMaxPerNote) private var maxLinks = 6

    @State private var status: String?
    @State private var exportURL: URL?
    @State private var confirmWipe = false
    @State private var confirmSeed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("笔记")
                        Spacer()
                        Text("\(store.notes.count)")
                            .foregroundStyle(Theme.inkSoft)
                    }
                    HStack {
                        Text("关联")
                        Spacer()
                        Text("\(store.links.count)")
                            .foregroundStyle(Theme.inkSoft)
                    }
                    HStack {
                        Text("复习卡")
                        Spacer()
                        Text("\(store.cards.count)")
                            .foregroundStyle(Theme.inkSoft)
                    }
                } header: {
                    Text("数据")
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("关联阈值")
                            Spacer()
                            Text(String(format: "%.2f", threshold))
                                .foregroundStyle(Theme.inkSoft)
                                .font(.footnote.monospacedDigit())
                        }
                        Slider(value: $threshold, in: 0.08...0.45, step: 0.01)
                    }
                    Stepper("每条最多关联 \(maxLinks) 条", value: $maxLinks, in: 2...15)

                    Button {
                        let count = store.rebuildLinks(threshold: threshold, maxPerNote: maxLinks)
                        status = "已重建：\(count) 条关联"
                        Haptics.success()
                    } label: {
                        Label("按当前参数重建关联", systemImage: "arrow.triangle.2.circlepath")
                    }
                } header: {
                    Text("关联引擎（本地算法，无需联网）")
                } footer: {
                    Text("相似度 = 0.68×语义向量 + 0.22×标签重合 + 0.10×时间邻近。阈值越低，连得越多。")
                }

                Section {
                    Toggle("启用云端增强", isOn: $llmEnabled)
                    TextField("接口地址", text: $llmBaseURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    TextField("模型名", text: $llmModel)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    SecureField("API Key", text: $llmKey)
                } header: {
                    Text("AI 增强（可选）")
                } footer: {
                    Text("填了 Key 并打开开关后，笔记详情页会多出「用 AI 提炼摘要与概念」按钮。不填则一切在端上完成，笔记不出手机。")
                }

                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("分享导出的 Markdown 文件", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        let markdown = Exporter.markdown(notes: store.notes, links: store.links)
                        exportURL = Exporter.writeTemporaryFile(content: markdown)
                        status = exportURL == nil ? "导出失败" : "已生成导出文件"
                    } label: {
                        Label("生成 Markdown 导出", systemImage: "doc.plaintext")
                    }
                } header: {
                    Text("导出")
                } footer: {
                    Text("导出包含正文、标签、摘要与关联，格式兼容 Obsidian 的双链。")
                }

                Section {
                    Button {
                        confirmSeed = true
                    } label: {
                        Label("恢复示例数据", systemImage: "sparkles")
                    }
                    Button(role: .destructive) {
                        confirmWipe = true
                    } label: {
                        Label("清空所有数据", systemImage: "trash")
                    }
                } header: {
                    Text("危险操作")
                }

                Section {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(Theme.inkSoft)
                    }
                    HStack {
                        Text("最低系统")
                        Spacer()
                        Text("iOS 16.0")
                            .foregroundStyle(Theme.inkSoft)
                    }
                } header: {
                    Text("关于")
                } footer: {
                    Text("织识 · 用文字、语音、拍照快速记下陌生知识，并让它们自动产生关联。数据全部存在本机 Documents/weave-store.json。")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: status) { _ in
                guard status != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { status = nil }
            }
            .overlay(alignment: .bottom) {
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.ink.opacity(0.86)))
                        .padding(.bottom, 20)
                }
            }
            .confirmationDialog("恢复示例数据？", isPresented: $confirmSeed, titleVisibility: .visible) {
                Button("恢复（会覆盖现有笔记）", role: .destructive) {
                    store.resetToSeed()
                    status = "示例数据已恢复"
                }
                Button("取消", role: .cancel) {}
            }
            .confirmationDialog("清空所有数据？", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("全部删除", role: .destructive) {
                    store.wipeAll()
                    exportURL = nil
                    status = "已清空"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("笔记、关联、复习进度都会删除，无法恢复。")
            }
        }
    }
}
