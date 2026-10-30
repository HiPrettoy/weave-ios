# 织识 Weave · 交接文档

> 面向「第一次接触本项目、要立刻能改代码并出包」的人。
> 按顺序读完这一份，就能独立完成一次完整的迭代（改功能 → 出 IPA → 装真机 → 验证）。
>
> 最后更新：2026-10-30 · 对应版本 v1.0.19 (build 20)

---

## 0. 一句话概括

一个 SwiftUI 写的 iOS 知识速记 App（iOS 16+）：文字 / 语音 / 拍照三种方式快速记下陌生知识点，
**保存瞬间本地算法自动把新笔记和已有笔记连成图谱**，再配 SM-2 复习排期。
零第三方依赖，数据全在本机，AI 增强是可选项。

| 关键事实 | 值 |
|---|---|
| 仓库 | https://github.com/HiPrettoy/weave-ios（分支 `master`，SSH 远端） |
| Bundle ID | `app.weave.ios` |
| 部署目标 | iOS 16.0（**不能用 SwiftData**，要 iOS 17） |
| 语言 / UI | Swift 5.9 / SwiftUI，`SWIFT_STRICT_CONCURRENCY: minimal` |
| 依赖 | **零第三方**（不用 SPM），CI 不用解析依赖，更稳 |
| 持久化 | `Documents/weave-store.json`，一份 Codable JSON |
| 当前版本 | `1.0.19` (build `20`)，见 `project.yml` |
| 目标真机 | iPhone / iOS 16.7.16 / rootless 越狱（Dopamine） |
| 安装方式 | TrollStore / TrollStore Lite（未签名 IPA） |

---

## 1. 目录结构与职责

```
D:\DSH\weave-ios/
├── project.yml                 ← XcodeGen 配置（唯一事实源；.xcodeproj 不入库）
├── HANDOVER.md                 ← 本文档
├── Config/Info.plist           ← 权限文案、ATS 局域网白名单
├── scripts/build_ipa.sh        ← 有 Mac 时的本地打包脚本
├── scripts/mock_llm.py         ← 本地 mock OpenAI 服务（测「在线模型」「AI 提炼」用）
├── scripts/make_icon.py        ← 生成 App 图标
├── .github/workflows/ios.yml   ← 云端 CI：出未签名 IPA artifact
├── docs/shots/                 ← README 用的截图
├── dist*/                      ← 本地构建产物与真机取证（已 gitignore）
└── Weave/
    ├── App/
    │   ├── WeaveApp.swift      ← @main，注入 AppStore
    │   ├── RootView.swift      ← 五个页面常驻 + 自绘底部标签栏
    │   └── AppRouter.swift     ← 路由状态机（tab / 各种 tick 计数器）
    ├── Models/Models.swift     ← Note / NoteLink / ReviewCard / Prefs
    ├── Support/
    │   ├── AppStore.swift      ← ★ 唯一数据源（内存数组 + JSON 落盘）
    │   ├── Theme.swift         ← 配色、.card() 修饰器、Haptics、parseTags
    │   ├── Exporter.swift      ← 导出 Markdown（Obsidian 双链）
    │   ├── SeedData.swift      ← 首启 6 条示例笔记
    │   ├── ImageTool.swift     ← 图片压缩（长边 1600 / JPEG 0.72）
    │   ├── LLMKeys.swift       ← 预设服务商 + UserDefaults 读写
    │   └── NoteRow.swift       ← 列表行组件
    ├── Capture/
    │   ├── CaptureView.swift   ← 首页（快记 + 三入口 + 最近列表 + 手势）
    │   ├── VoiceCaptureView.swift  ← Speech 实时转写
    │   ├── PhotoCaptureView.swift  ← 相机 + Vision OCR
    │   ├── ManualCaptureView.swift ← 长文本手记
    │   ├── SpeechService.swift ← SFSpeechRecognizer 封装
    │   ├── OCRService.swift    ← VNRecognizeTextRequest 封装
    │   └── AIExtract.swift     ← 三页共用的「AI 提炼」面板
    ├── Linking/
    │   ├── TextTokenizer.swift ← 中英混排分词（单字 + 二元组）
    │   ├── EmbeddingEngine.swift ← Hashing Trick 512 维 + IDF + 余弦
    │   ├── AutoLinker.swift    ← ★ O(n²) 关联打分，核心算法
    │   └── LLMEnricher.swift   ← OpenAI 兼容接口：/models、/chat/completions
    ├── Graph/
    │   ├── ForceLayout.swift   ← Fruchterman-Reingold 力导向布局
    │   └── GraphView.swift     ← Canvas 绘图 + 缩放拖拽点选
    ├── Library/
    │   ├── LibraryView.swift   ← 搜索（关键词/语义）、来源筛选、标签多选
    │   └── NoteDetailView.swift← 详情、编辑、AI 提炼、关联列表、复习信息
    ├── Review/
    │   ├── SRS.swift           ← SM-2 简化版
    │   └── ReviewView.swift    ← 复习卡界面
    └── Settings/
        ├── SettingsView.swift  ← 关联参数、AI 配置、导出、清库
        └── ModelPickerView.swift ← 从 /models 拉在线模型列表
```

---

## 2. 运行时数据流

### 2.1 唯一数据源：`AppStore`

`AppStore` 是 `ObservableObject`，全局通过 `.environmentObject(store)` 注入。

```
@Published private(set) var notes: [Note]     // 全部笔记，内存数组
@Published private(set) var links: [NoteLink] // 关联边
@Published private(set) var cards: [ReviewCard]
```

**任何页面都不直接改这三个数组**，一律调 `AppStore` 的方法：

| 方法 | 作用 | 副作用 |
|---|---|---|
| `add(content:title:tags:source:imageData:summary:concepts:)` | 新增笔记 | 插入头部 → 建复习卡 → **重建全部关联** → 防抖落盘 |
| `update(_:)` / `updateWithoutTouch(_:)` | 改笔记 | 改数组 → 防抖落盘（**不重建关联**） |
| `delete(_:)` | 删笔记 | 清关联 + 清卡 → **重建全部关联** → 落盘 |
| `toggleFavorite(_:)` | 收藏 | 落盘 |
| `grade(_:grade:)` | 复习评分 | 走 `SRS.apply` → 落盘 |
| `rebuildLinks(threshold:maxPerNote:)` | 手动/自动重建关联 | **整库 O(n²) 重算** → 落盘 |
| `enrich(_:config:)` | AI 提炼 | 写 summary/concepts/tags → **重建关联** → 落盘 |
| `wipeAll()` / `resetToSeed()` | 清库 / 恢复示例 | 落盘 |

### 2.2 落盘时机

- `scheduleSave()`：防抖 0.5 秒，**在调用线程取快照**（值类型，无并发读写问题），编码与写盘放后台队列。
- `saveNow()`：立即写。
- 触发点：任何写操作之后；以及 `RootView` 检测到 `scenePhase != .active`（切后台）。

文件路径：`FileManager.default.urls(for: .documentDirectory)[0]/weave-store.json`
写入用 `Data.write(to:options:.atomic)`，原子替换，不会写坏半个文件。

### 2.3 关联算法（核心）

`AutoLinker.build(notes:threshold:maxPerNote:)` 被调用的频率极高，**它是全库重算**：

```
score = 0.68 × cos(向量a, 向量b)
      + 0.22 × Jaccard(标签a, 标签b)
      + 0.10 × max(0, 1 - 相距小时数 / 72)
```

连边条件：`score ≥ threshold`（默认 0.18，设置页可调 0.08~0.45）**或** `相似度 ≥ 0.34`，
且必须 `相似度 ≥ 0.10 或 标签重合 > 0`。每条笔记最多连 `maxPerNote` 条（默认 6，范围 2~15）。

向量：`EmbeddingEngine` 用 Hashing Trick 512 维 + 次线性 TF + IDF + L2 归一化。
**哈希用 FNV-1a 而不是 Swift 的 `Hasher`** —— `Hasher` 每次启动种子不同，跨进程不一致会让已存向量全部失效。

分词：`TextTokenizer` 中文按「单字 + 相邻二元组」，拉丁按词，带中英停用词表。
二元组是中文没有空格时性价比最高的近似 n-gram 方案。

> ⚠️ **性能现状（接手后第一件该知道的事）**
> `AutoLinker.build` 是 O(n²)，内层循环每对笔记还要 new 两个 `Set` 做 Jaccard。
> 粗估：**n=500 时单次 `add()` 就要主线程卡 1~2 秒，n=1000 卡 5~10 秒**。
> `AppStore.related(to:)` 和 `note(id:)` 也都是线性查找。
> 这是当前最大的技术债，但**换 SQLite 解决不了**（全在内存里）。
> 正确的顺序见 §7。

### 2.4 页面路由

`AppRouter` 持有 `tab`（当前 tab，**默认 `.capture` 即采集页是启动页**）和四个自增计数器：

| 计数器 | 触发方 | 效果 |
|---|---|---|
| `captureFocusTick` | 重复点「采集」 | 采集页输入框聚焦弹键盘 |
| `searchFocusTick` | 重复点「笔记」 | 笔记页进入搜索态并弹键盘 |
| `cameraTick` | 首页下滑 | 直接弹相机 |
| `voiceTick` | 长按底部采集钮 | 直接进语音页 |

用**自增计数器而非布尔**，是为了连点两次也能各触发一次。

五个页面在 `RootView` 里**全部常驻**，靠 `TabPage` 修饰器切透明度和命中测试。
**不要改成 `if` 分支重建** —— 切一次标签搜索词、导航层级全丢，体验会退步。

---

## 3. 一次完整迭代的标准流程

### 3.1 改代码 → 出包（无 Mac 环境）

```bash
cd "D:/DSH/weave-ios"

# 1) 改代码后，先在 project.yml 里递增版本号（两处都要改）
#    MARKETING_VERSION: "1.0.20"
#    CURRENT_PROJECT_VERSION: "21"

# 2) 提交并推送（推 master 会触发 CI）
git add -A && git commit -m "feat: 你的改动 (1.0.20)"
git push origin master

# 3) 等 CI 跑完，下载 artifact
gh run list --limit 3
gh run download <run-id> -n weave-unsigned-ipa -D ./dist20
# 或手动从 Actions 页面下载 weave-unsigned-ipa
```

CI（`.github/workflows/ios.yml`，跑在 `macos-15`）做的事：
`brew install xcodegen` → `xcodegen generate` → `xcodebuild archive`（**未签名**，
`CODE_SIGNING_ALLOWED=NO`）→ 把 `.app` 塞进 `Payload/` → `zip` 成 `Weave-v1.0.20.ipa` → 上传 artifact。

> ⚠️ **CI 只出 artifact，不自动建 Release。** 需要 Release 的话手动补：
> ```bash
> gh release create v1.0.20 ./dist20/Weave-v1.0.20.ipa \
>   --title "织识 Weave v1.0.20（未签名 IPA）" --notes "改动摘要"
> ```
> 历史上 v1.0.11 / v1.0.12 就因为只跑了 CI 没建 Release，导致用户在 Release 页找不到新版。

### 3.2 装到真机

走 **TrollStore / TrollStore Lite**，不要用 `ldid` + `dpkg` 那条路（原因见 §6）。

```bash
# 本机起一个只服务 IPA 的 HTTP 服务（TrollStore 走 apple-magnifier://install?url=...）
node "D:\DSH\Cliplt\tools\iosmcp.mjs" tsinstall ./dist20/Weave-v1.0.20.ipa app.weave.ios
```

`iosmcp.mjs` 常用子命令：

| 命令 | 用途 |
|---|---|
| `info` | 设备信息（系统版本、越狱类型、电量、内存） |
| `tools` | 列出所有可用 MCP 工具 |
| `call <tool> '<json>'` | 直接调某个工具（点按、滑动、输入等） |
| `shot [文件名]` | 截图存到本地 |
| `apps [关键词]` | 列出已装 App |
| `launch <bundleId>` | 启动 App |
| `install <ipa>` | 普通安装（**会失败**，见 §6） |
| `deploy <ipa> [bundleId]` | 伪签名 + dpkg 部署（**能装但不能联网**，见 §6） |
| `tsinstall <ipa> [bundleId]` | ★ TrollStore 安装，唯一能正常联网的方式 |
| `sh '<命令>'` | 在设备上跑 shell |
| `crash` / `crashread <name>` | 查崩溃日志 |

### 3.3 真机验证

`iosmcp.mjs call <tool> '<json>'` 的工具名要先用 `tools` 查。常用交互类工具（名字以实际 `tools` 输出为准）：

- 点按某个坐标或某个 UI 元素
- 长按 —— ⚠️ **参数是 `seconds`，不是 `duration`**（历史上用错导致「长按没生效」的误判）
- 输入文本、滑动

**验证纪律**（踩过的坑）：
1. **截图脚本不要写死旧图片路径** —— 必须每次真读新截图文件，否则会看到「修改无效」的假象（历史上真发生过）。
2. **改了代码必须重新出包重新装**，不能只热重载 App 就期望看到新 UI。
3. **测完要清理测试数据**（删测试笔记），把手机恢复到原状。
4. 改完 UI 后**用像素量间距**，不要目测。例如「织识」标题最终定为：状态栏文字底 y=27、标题顶 y=53。

### 3.4 本地 mock LLM 服务

验证「在线模型」和「AI 提炼」不需要真 Key。`scripts/mock_llm.py` 就是干这个的：

```bash
python scripts/mock_llm.py     # 监听 0.0.0.0:8899
```

- `GET /v1/models` → 返回 `mock-alpha` / `mock-beta` / `mock-gamma`
- `POST /v1/chat/completions` → 若 user 消息含「可用」两个字就回「可用」（供「测试连接」用），
  否则回一段固定的 `{summary, concepts, tags}` JSON

App 里填接口地址 `http://<本机局域网IP>:8899/v1`、随便填个 Key 即可测试。
（`Info.plist` 已开 `NSAllowsLocalNetworking`，局域网 http 不会被 ATS 拦。）

---

## 4. 本地开发（若有 Mac + Xcode）

```bash
brew install xcodegen
xcodegen generate && open Weave.xcodeproj   # 直接调
./scripts/build_ipa.sh 1.0.20                 # 或出 IPA
```

`.xcodeproj` 是生成物，**不入库**。改了 `project.yml` 必须重新 `xcodegen generate`。

---

## 5. 已知限制（写在 README 里，接手时要知道哪些是「有意为之」）

| 限制 | 原因 |
|---|---|
| 语音转写单段约 1 分钟 | 系统 `SFSpeechRecognizer` 的限制 |
| 关联是「词面」相似度，不是真语义模型 | 同义词（如「滤波」/「filter」）要靠 AI 增强补齐 |
| 全量 JSON 写入 | 笔记量到几万条会明显变慢。**注意：这个阈值说早了** —— 真正的瓶颈见 §7 |
| 图谱布局一次性算完 | 节点上千时会卡，目前按几十到几百个节点设计 |
| 没有 iCloud 同步 | 换设备靠导出 Markdown |
| 目标机 iOS 16.7 | SwiftData 用不了；Core Data 要 `.xcdatamodeld`，没有 Xcode 无法校验 |

---

## 6. 历史踩坑清单（别再犯）

### 架构 / 平台约束

| 坑 | 说明 |
|---|---|
| SwiftData 要 iOS 17 | 部署目标 16.0，直接出局 |
| Core Data 要 `.xcdatamodeld` | 没有 Xcode 环境就校验不了 `.mom`，只能靠 CI 报错，链路太脆 |
| `ldid` 伪签名 + `dpkg` 装进 `/var/jb/Applications` | **能启动但不能联网**：系统按进程拦外网请求，报 `NSURLError -1009`。语音识别和 AI 增强都会失效。必须走 TrollStore |
| `install_app` 装未签名 IPA | 被 `installation_proxy` 拒（`installApplication returned NO`），因为没 AppSync / CoreTrust |

### SwiftUI 特有坑

| 坑 | 症状 | 正解 |
|---|---|---|
| `ScrollView` 吞掉父级上滑手势 | 首页「上滑进笔记」失效 | 最近列表**不用 ScrollView**，改成按屏高固定放 3~8 条 |
| body 表达式过于复杂 | SwiftUI 类型检查超时（编译卡死） | 拆成 `captureBody(in:)` / `topBlock(in:)` 等独立函数 |
| `GeometryProxy.height` | 编译不过 | 是 `size.height` |
| `ForEach` 用元组做 keyPath | 编译不过 | 定义 `struct TagUsage: Identifiable` 之类的包装类型 |
| 全局 `.tint` 影响 swipeActions | 删除按钮变成绿色/蓝色 | 删除必须显式 `.tint(Color.red)`（系统语义里删除必须是红） |
| 两行说明被压成一行 | 入口卡片文案被截断 | `.lineLimit(2)` + `.fixedSize(horizontal:false, vertical:true)` |

### 手势 / 状态机

| 坑 | 说明 |
|---|---|
| 长按后抬手被当成点按 | 长按采集进语音后，又触发了一次点按。解法：`lastLongPressAt` 时间戳抑制 1.2 秒内的点按 |
| 系统 Speech 迟到回调抹掉文本 | 「点结束后内容消失」的根因。解法：`isFinishing` 标志 + 空结果不覆盖 + 停止时先取快照 |
| present 后立刻再弹 cover 被吞 | 拍照页自动弹相机要 `Task.sleep(420ms)` 再弹 |
| 图片只给高度时 `scaledToFill` 撑宽 | 「图突然变大、显示不全」。解法：外框 `.frame(height: 240)` 钉死 + 图用 `.scaledToFit()` |
| 图谱点节点报「笔记已不在」 | sheet 的 `onAppear` 时机导致按 id 查不到。解法：`NoteDetailView` 加 `initial: Note?` 兜底快照 |

### 工具链

| 坑 | 说明 |
|---|---|
| ios-mcp 长按参数 | 是 `seconds`，不是 `duration` |
| 扫描脚本写死图片路径 | 会产生「修改无效」的假象 |
| Release 漏建 | CI 只出 artifact，Release 要手动 `gh release create` |

---

## 7. 建议的技术债处理顺序

如果要给这个项目提速或重构，**按这个顺序**做，收益从大到小：

**第 1 步：修 O(n²)（纯内存算法优化，不动存储格式、不动 UI，风险最低、收益最大）**
- `AutoLinker.build`：只让「新笔记 / 变更笔记」跟候选集比，而不是整库两两比；
  或用倒排索引（按 token 倒排）先剪枝候选，再算余弦
- `AppStore.related(to:)`：用 `notesByID` 字典替掉 `notes.first(where:)`
- `AppStore.note(id:)`：同上
- 内层循环的 `Set(left.tags.map { $0.lowercased() })` 提到循环外预计算

**第 2 步：把 `imageData` 从 JSON 里挪出去**
图片存 `Documents/Images/<uuid>.jpg`，JSON 里只存路径。
现在一张 1600px JPEG 压完约 250KB，base64 进 JSON 后膨胀到约 330KB —— **这一步能把 JSON 体积砍掉两个数量级，收益比换 SQLite 还大**。

**第 3 步：才考虑 SQLite**
SQLite 只解决「按条增量写」和「按 id 索引查找」，**解决不了第 1 步的 O(n²)**。
真要上，裸 `sqlite3` C API 在 iOS 16 上是系统自带、零依赖的（`import SQLite3`），
不需要 Core Data 也不需要第三方 ORM。但要付出：数据访问层 + schema 迁移 + 线程隔离（sqlite3 C API 不是 Sendable）。
三张表（notes / links / cards），没有分页、没有复杂查询、没有并发多写 —— SQLite 的价值目前还没兑现。

**注意**：`Note.embedding` 是 512 维向量，SQLite 原生也不擅长向量检索（真要做得引 sqlite-vec 之类扩展，那又回到「引入依赖」）。

---

## 8. 常用命令速查

```bash
# 本地提交
git add -A && git commit -m "feat: xxx (1.0.20)" && git push origin master

# CI 状态
gh run list --limit 5
gh run watch <run-id>

# 下载 IPA
gh run download <run-id> -n weave-unsigned-ipa -D ./dist20

# 建 Release
gh release create v1.0.20 ./dist20/Weave-v1.0.20.ipa \
  --title "织识 Weave v1.0.20（未签名 IPA）" --notes "..."

# 设备
node "D:\DSH\Cliplt\tools\iosmcp.mjs" info
node "D:\DSH\Cliplt\tools\iosmcp.mjs" tools
node "D:\DSH\Cliplt\tools\iosmcp.mjs" shot shot.png
node "D:\DSH\Cliplt\tools\iosmcp.mjs" launch app.weave.ios
node "D:\DSH\Cliplt\tools\iosmcp.mjs" tsinstall ./dist20/Weave-v1.0.20.ipa app.weave.ios

# 设备上看数据文件（越狱 shell）
node "D:\DSH\Cliplt\tools\iosmcp.mjs" sh 'cat /var/mobile/Containers/Data/Application/*/Documents/weave-store.json | head -c 2000'
```

---

## 9. 参考过的开源项目

设计思路借鉴，代码全部重写：

- `rahulkarda/knowledge-graph-engine` — 多模态采集 + 自动关联 + 语义搜索的整体骨架
- `bwl/forest` — 图谱数据结构与自动打边
- `kermopajula/braindump` — 纯端上、语音优先的隐私设计
- `luisangel2895/neurova` — SwiftUI + 端上 OCR + 间隔重复
- `cutd/Anki-Flashcards-Pro` — Anki 兼容的 SRS 调度

License：MIT
