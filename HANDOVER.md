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
├── .github/workflows/ios.yml   ← 云端 CI：单测 + 打包未签名 IPA + 推 tag 自动发 Release
├── .swiftlint.yml              ← SwiftLint 规则（CI 里只提示不拦路）
├── docs/shots/                 ← README 用的截图
├── dist*/                      ← 本地构建产物与真机取证（**已被 /dist*/ 忽略，且不再被 git 跟踪**）
└── Weave/
    ├── App/
    │   ├── WeaveApp.swift      ← @main，注入 AppStore
    │   ├── RootView.swift      ← 五个页面常驻 + 自绘底部标签栏
    │   └── AppRouter.swift     ← 路由状态机（tab / 各种 tick 计数器）
    ├── Models/Models.swift     ← Note / NoteLink / ReviewCard / Prefs
    ├── Support/
    │   ├── AppStore.swift      ← ★ 唯一数据源（内存数组 + JSON 落盘）
    │   ├── Theme.swift         ← 配色（含深色）、scaledFont()、.card()、Haptics、parseTags
    │   ├── Formatters.swift    ← 共享的日期格式（别再每次渲染 new DateFormatter）
    │   ├── Keychain.swift      ← API Key 的存/取（不再进 UserDefaults）
    │   ├── Exporter.swift      ← 导出 Markdown（Obsidian 双链）
    │   ├── SeedData.swift      ← 首启 6 条示例笔记
    │   ├── ImageTool.swift     ← 图片压缩（长边 1600 / JPEG 0.72，须在后台调）
    │   ├── LLMKeys.swift       ← 预设服务商 + Keychain 读写
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
    │   ├── EmbeddingEngine.swift ← Hashing Trick 512 维 + IDF + 余弦 + SemanticCorpus
    │   ├── AutoLinker.swift    ← ★ 倒排剪枝的关联打分，核心算法
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
        ├── SettingsView.swift  ← 关联参数、AI 配置、备份恢复、导出、清库
        └── ModelPickerView.swift ← 从 /models 拉在线模型列表
    Localizable.xcstrings       ← 中文原文 + 英文译文（133 条）
WeaveTests/                     ← 纯逻辑单测（分词 / 边 / 检索 / SRS / 导出 / LLM 解析）
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
`xcodegen generate` → `xcodebuild test`（模拟器上跑 `WeaveTests`）→
`xcodebuild archive`（**未签名**，`CODE_SIGNING_ALLOWED=NO`）→ 校验版本号 →
把 `.app` 塞进 `Payload/` → `zip` 成 `Weave-v<版本>.ipa` → 上传 artifact。

> **版本号只有一个真源：`project.yml` 的 `MARKETING_VERSION`。**
> CI 会断言「产物里的 `CFBundleShortVersionString`」＝「project.yml 声明的值」＝
> 「tag 名去掉 v」三者一致，任何一处对不上直接失败。
> 所以发版就是：改 `project.yml` 的版本 → 提交 → `git tag vX.Y.Z && git push --tags`。

> ✅ **推 tag 会自动建 Release。** `release` job 在 `refs/tags/v*` 上触发，
> 下载刚打好的 IPA 并发布，标题为「织识 Weave vX.Y.Z（未签名 IPA）」。
> 不再需要手动 `gh release create`——历史上 v1.0.2、v1.0.4~v1.0.9、v1.0.11、
> v1.0.13、v1.0.14 就是因为靠手动建而漏掉，Release 页上一直是断的。
> 需要补历史版本时仍可手动：`gh release create v1.0.14 ./dist14/xxx.ipa`。

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
- `POST /v1/chat/completions` → 若 user 消息含「只回复两个字」就回「可用」（供「测试连接」用），
  否则回一段固定的 `{summary, concepts, tags}` JSON

App 里填接口地址 `http://<本机局域网IP>:8899/v1`、随便填个 Key 即可测试。
（`Info.plist` 已开 `NSAllowsLocalNetworking`，局域网 http 不会被 ATS 拦。）

---

## 4. 本地开发（若有 Mac + Xcode）

```bash
brew install xcodegen
xcodegen generate && open Weave.xcodeproj   # 直接调
./scripts/build_ipa.sh                       # 或出 IPA（版本号读 project.yml）
xcodebuild test -project Weave.xcodeproj -scheme Weave \
  -destination 'platform=iOS Simulator,name=iPhone 16'   # 跑单测
```

`.xcodeproj` 是生成物，**不入库**。改了 `project.yml` 必须重新 `xcodegen generate`。
`build_ipa.sh` 不再接受版本号参数：版本只有一个来源，脚本会断言产物与 `project.yml` 一致。

---

## 5. 已知限制（写在 README 里，接手时要知道哪些是「有意为之」）

| 限制 | 原因 |
|---|---|
| 语音转写单段约 60 秒 | 系统 `SFSpeechRecognizer` 的限制，本项目没有做自动分段 |
| 关联是「词面」相似度，不是真语义模型 | 同义词（如「滤波」/「filter」）要靠 AI 增强补齐 |
| 全量 JSON 写入 | 笔记量到几万条会明显变慢。**注意：这个阈值说早了** —— 真正的瓶颈见 §7 |
| 图谱布局一次性算完 | 节点上千时会卡，目前按几十到几百个节点设计 |
| 没有 iCloud 同步 | 换设备靠「备份与恢复」里的 `.weave` 文件，或导出 Markdown |
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
| Release 漏建 | ~~CI 只出 artifact，要手动 `gh release create`~~ 已修：推 tag 自动发版 |
| `git rm --cached` 猜目录名 | `dist2`/`dist11`~`dist20` 从来没被跟踪过，`git rm` 遇到不存在的 pathspec 会整体中止。只对 `git ls-files` 真列出来的路径下手 |
| 修完 `.gitignore` 不等于已停止跟踪 | 忽略规则对已入库的文件无效，必须先 `git rm -r --cached` |

---

## 7. 技术债现状（2026-10 这一轮之后）

原来的「三步走」里第 1 步和第 2 步的核心已经做掉了，这里记录改动落点，
避免后来者重复劳动或者把已经修好的东西又写回去。

**已修：关联重建从 O(n²) 降到 O(n·桶大小)**
- `AutoLinker.build` 改成倒排剪枝：每条笔记取权重最高的 16 个哈希桶建 `postings`，
  只有共享桶的才成为候选对；标签另建 `byTag` 索引兜底（标签是用户手打的，比哈希碰撞可信）。
- 每对只打分一次并双向记账；每条笔记各自取前 `maxPerNote` 条再全局去重 ——
  原来的单向 `seen` 会让先入库的笔记占满配额，后面的连不到东西。
- 桶与标签都按 key 排序后遍历，保证同一份数据重算两次得到同样的边。

**已修：索引与派生值**
- `AppStore` 加 `noteIndex` / `cardIndex`（脏标记 + 懒重建），`note(id:)`、`card(for:)`、
  `related(to:)` 不再线性扫描；`updateWithoutTouch`、`linkCount`、`degree` 等死代码清掉。
- 整库语料 `SemanticCorpus` 缓存在 `AppStore.corpus`，语义检索不再每敲一个字就重新分词全库；
  查询向量与笔记向量现在用**同一个** `CorpusIndex` 生成（旧实现混用新旧 IDF，分数没有意义）。
- `LibraryView` / `CaptureView` 的过滤结果与常用标签按内容指纹缓存；
  `Formatters` 统一了 DateFormatter（原来每次渲染都 new 一个）。

**仍是「有意为之」的取舍**
- 持久化还是一份 JSON。`imageData` 仍在 JSON 里 —— **第 2 步（图片外置到 Documents/Images）还没做**，
  它现在是 JSON 体积的大头（一张 1600px JPEG ≈ 250KB，base64 后 ≈ 330KB）。
- 仍然不引入 SQLite：JSON 全量写在几百到几千条量级够用，
  收益要等到「按条增量写」真的成为瓶颈时才兑现。
- 图谱力导向仍是全对排斥（300 轮），但已经挪到后台队列，且隐藏页不再触发重算。
  节点上千时会慢，这是已知边界。

**测试**
- `WeaveTests` 覆盖分词语义、向量与余弦、连边规则（含 `maxPerNote` 对称性、去重、空笔记）、
  语义检索的坐标系校验、SM-2 调度、Markdown 导出、LLM 的 URL 拼接与 JSON 抽取。
- 运行：`xcodebuild test -project Weave.xcodeproj -scheme Weave -destination 'platform=iOS Simulator,name=iPhone 16'`，
  CI 的 `test` job 会自动跑。

**已修：深色模式、字号与无障碍**
- 配色拆成两套：`accent` / `warm` 是**彩色文字**用色，`accentFill` / `warmFill` 是**承载白字的实心块**用色。
  原因：同一个绿在深色背景上当文字够亮，当底压白字就只剩 2.67:1。所有 `.fill(...)` 的调用点都已改成 `*Fill`。
- 修掉一个真缺陷：toast 原来用 `ink.opacity(0.86)` 当底 + 白字，而 `ink` 在深色下是白色 —— 深色模式完全看不见提示。
  现在统一用 `Theme.scrim`（`CaptureView` 与 `SettingsView` 两处）。
- 字号：`scaledFont(_:weight:design:relativeTo:)` 包了一层 `@ScaledMetric`，22 处 `.system(size:)` 改为跟随系统字号。
  TabBar 的 SF Symbol 图标保持固定；图谱 Canvas 里的节点文字由 `@ScaledMetric` 单独驱动（`ctx.draw(Text)` 挂不了修饰器）。
- VoiceOver：笔记行合并成一句摘要、Tab 播报选中态、采集键补「开始语音输入」自定义动作、
  图谱统计条播报节点/连线/缩放、评分按钮播报四档含义、语音波形对读屏隐藏。
- 本地化：`Weave/Localizable.xcstrings`（133 条，中文原文 + 英文译文）。编译产物是 `Weave.app/en.lproj/Localizable.strings`，
  中文走 development region 回退（键本身就是中文），所以**不需要 zh-Hans.lproj**。
  坑：枚举属性、方法参数、`@Published` 字符串这类**`String` 参数不会自动查表**，
  必须显式 `String(localized:)`（`CaptureSource`/`LinkKind`/`Note.fullTitle`/`SRS.grades`/`AppTab.title`/toast/语音错误提示）。

---

## 8. 常用命令速查

```bash
# 本地提交
git add -A && git commit -m "feat: xxx" && git push origin master

# 发版（推 tag 会自动建 Release，不用再手动 gh release create）
#   1) 先改 project.yml 的 MARKETING_VERSION
#   2) git commit -am "chore: 版本号升到 1.0.20"
#   3) git tag v1.0.20 && git push --tags

# CI 状态
gh run list --limit 5
gh run watch <run-id>

# 下载 IPA（PR 不产 artifact，只有 push/tag 才有）
gh run download <run-id> -n weave-unsigned-ipa -D ./dist20

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
