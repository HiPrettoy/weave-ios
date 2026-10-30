import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore

    @AppStorage(Prefs.llmEnabled) private var llmEnabled = false
    @AppStorage(Prefs.llmBaseURL) private var llmBaseURL = "https://api.deepseek.com"
    @AppStorage(Prefs.llmModel) private var llmModel = "deepseek-chat"
    @AppStorage(Prefs.linkThreshold) private var threshold = 0.18
    @AppStorage(Prefs.linkMaxPerNote) private var maxLinks = 6

    /// Key 走 Keychain，不能再用 @AppStorage（那会明文写 UserDefaults）
    @State private var llmKey = ""
    /// Keychain 写入是磁盘操作，输入时防抖 0.5 秒再落
    @State private var keySaveTask: Task<Void, Never>?

    @State private var status: String?
    /// toast 的自动消失任务，新的提示来了要先取消旧的
    @State private var statusTask: Task<Void, Never>?
    @State private var exportURL: URL?
    @State private var backupURL: URL?
    @State private var confirmRestore = false
    @State private var showRestorePicker = false
    @State private var confirmWipe = false
    @State private var confirmSeed = false
    @State private var testing = false
    @State private var isExporting = false
    @State private var isRebuilding = false
    @State private var testMessage: String?
    @State private var testPassed = false

    private var trimmedBase: String {
        llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedKey: String {
        llmKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 编辑时只改 @State，停手 0.5 秒再写 Keychain —— 每次敲键都碰磁盘太浪费
    private var keyBinding: Binding<String> {
        Binding(
            get: { llmKey },
            set: { newValue in
                llmKey = newValue
                keySaveTask?.cancel()
                keySaveTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    LLMKeys.setAPIKey(newValue)
                    keySaveTask = nil
                }
            }
        )
    }

    private func flushKey() {
        keySaveTask?.cancel()
        keySaveTask = nil
        LLMKeys.setAPIKey(llmKey)
    }

    private func handleRestore(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            status = "恢复失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            // fileImporter 给的是沙箱外的 URL，必须先拿安全作用域访问权
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let count = try store.restore(from: data)
                exportURL = nil
                backupURL = nil
                status = "已恢复 \(count) 条笔记"
                Haptics.success()
            } catch {
                // 解码失败时 store.restore 已经抛错并且没有改动任何数据
                status = "这个文件不是有效的备份：\(error.localizedDescription)"
            }
        }
    }

    @MainActor
    private func runConnectionTest() async {
        testing = true
        testMessage = nil
        do {
            let result = try await LLMEnricher.probe(baseURL: llmBaseURL, apiKey: llmKey, model: llmModel)
            testPassed = true
            testMessage = "连接成功 · \(result.latencyMs) ms · 模型回复「\(result.reply)」"
            Haptics.success()
        } catch {
            testPassed = false
            testMessage = "连接失败：\(error.localizedDescription)"
        }
        testing = false
    }

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

                if let issue = store.loadIssue {
                    Section {
                        Label {
                            Text(issue)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.warm)
                        }
                    } header: {
                        Text("上次启动提示")
                    } footer: {
                        Text("如果数据看起来不对，先别继续编辑 —— 用下面的「从备份文件恢复」把车倒回去。")
                    }
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
                        // 重建会重算全库向量与候选对。算法本身已经从 O(n²) 降到
                        // O(n·桶大小)，几百条笔记是几十毫秒级；这里给一个「正在重建」
                        // 状态，主要是让点击有即时反馈，而不是让界面看起来没反应。
                        isRebuilding = true
                        status = "正在重建关联…"
                        Task { @MainActor in
                            // 先让上面的状态渲染出去，再开始算
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            let count = store.rebuildLinks(threshold: threshold, maxPerNote: maxLinks)
                            status = "已重建：\(count) 条关联"
                            isRebuilding = false
                            Haptics.success()
                        }
                    } label: {
                        Label(isRebuilding ? "正在重建…" : "按当前参数重建关联",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isRebuilding)
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
                        .font(.subheadline.monospaced())

                    Menu {
                        ForEach(LLMKeys.presets) { preset in
                            Button {
                                // 地址和模型名必须一起写：只改地址会让请求带着上一家的
                                // 模型名发过去（例如选 Kimi 仍发 deepseek-chat），必然 4xx。
                                llmBaseURL = preset.baseURL
                                llmModel = preset.model
                                testMessage = nil
                                Haptics.tap()
                            } label: {
                                let matched = LLMKeys.matchedPresetID(baseURL: llmBaseURL,
                                                                      model: llmModel) == preset.id
                                if matched {
                                    Label("\(preset.name)", systemImage: "checkmark")
                                } else {
                                    Text("\(preset.name) — \(preset.baseURL)")
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text("常用服务商地址")
                            Spacer()
                            Text("点选快速填入")
                                .font(.footnote)
                                .foregroundStyle(Theme.inkSoft)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(Theme.inkSoft)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("API Key")
                        SecureField("粘贴你的 Key", text: keyBinding)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(.subheadline.monospaced())
                    }

                    NavigationLink {
                        ModelPickerView(baseURL: llmBaseURL, apiKey: llmKey, selected: $llmModel)
                    } label: {
                        HStack {
                            Text("在线模型")
                            Spacer()
                            Text(llmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "点这里获取" : llmModel)
                                .font(.footnote.monospaced())
                                .foregroundStyle(Theme.inkSoft)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Button {
                        Task { await runConnectionTest() }
                    } label: {
                        HStack(spacing: 8) {
                            Label("测试连接", systemImage: "bolt.horizontal.circle")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || trimmedKey.isEmpty || trimmedBase.isEmpty)

                    if let testMessage {
                        Text(testMessage)
                            .font(.footnote)
                            .foregroundStyle(testPassed ? Theme.accent : Color.red.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("AI 增强（可选）")
                } footer: {
                    Text("填地址和 Key 后，点「在线模型」会自动从该地址的 /models 接口取回可用模型列表，你挑一个即可，不用记模型名。配好后先点「测试连接」，通了再回去用。不启用则一切在端上完成，笔记不出手机。")
                }

                Section {
                    Button {
                        do {
                            backupURL = try store.writeBackupFile()
                            status = "备份已生成"
                        } catch {
                            status = "备份失败：\(error.localizedDescription)"
                        }
                    } label: {
                        Label("生成完整备份（.weave）", systemImage: "externaldrive.badge.timemachine")
                    }

                    if let backupURL {
                        ShareLink(item: backupURL) {
                            Label("保存 / 分享备份文件", systemImage: "square.and.arrow.up")
                        }
                    }

                    Button {
                        confirmRestore = true
                    } label: {
                        Label("从备份文件恢复", systemImage: "arrow.down.doc")
                    }
                } header: {
                    Text("备份与恢复")
                } footer: {
                    Text("备份是完整数据（笔记、关联、复习进度），换机或重装后导入即可回到原样。Markdown 导出只保留正文。")
                }

                Section {
                    if let exportURL {
                        ShareLink(item: exportURL) {
                            Label("分享导出的 Markdown 文件", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        // 导出要把全库正文拼成一个字符串，上千条时是上百毫秒的活，
                        // 原来直接跑在主线程上，点一下能感觉到的卡。
                        isExporting = true
                        Task { @MainActor in
                            let notes = store.notes
                            let links = store.links
                            let markdown = await Task.detached(priority: .userInitiated) {
                                Exporter.markdown(notes: notes, links: links)
                            }.value
                            exportURL = Exporter.writeTemporaryFile(content: markdown)
                            status = exportURL == nil ? "导出失败" : "已生成导出文件"
                            isExporting = false
                        }
                    } label: {
                        Label("生成 Markdown 导出", systemImage: "doc.plaintext")
                    }
                    .disabled(isExporting)
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
                        Text(AppInfo.version)
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
            .task {
                if llmKey.isEmpty { llmKey = LLMKeys.apiKey }
            }
            .onDisappear {
                flushKey()
            }
            .onChange(of: status) { _ in
                guard status != nil else { return }
                // 可取消的自动消失：原来是一串不可取消的 asyncAfter，
                // 连续两条提示（比如先备份再分享）会让后一条被前一条的计时器提前清掉。
                statusTask?.cancel()
                statusTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled else { return }
                    status = nil
                }
            }
            .overlay(alignment: .bottom) {
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.scrim))
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
            .confirmationDialog("用备份覆盖当前数据？", isPresented: $confirmRestore, titleVisibility: .visible) {
                // 这一步只是打开文件选择器，真正覆盖发生在选完文件之后，
                // 所以按钮不该标成 destructive —— 用户还有一次反悔机会。
                Button("选择备份文件") { showRestorePicker = true }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前的笔记、关联、复习进度都会被备份里的内容替换。")
            }
            .fileImporter(isPresented: $showRestorePicker,
                          // .weave 已经在 Info.plist 里声明过（UTExportedTypeDeclarations），
                          // 但用户也可能直接把 .json 改个名字丢进来，所以几种都放行。
                          allowedContentTypes: [UTType(filenameExtension: "weave") ?? .json, .json, .data],
                          allowsMultipleSelection: false) { result in
                handleRestore(result)
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

/// 从 App 的 Info.plist 读版本，避免设置页里写死的版本号与实际包里对不上
enum AppInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}
