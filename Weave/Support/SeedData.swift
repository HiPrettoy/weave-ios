import Foundation

/// 首次启动塞几条互相有关联的示例笔记，让图谱一打开就不是空的。
/// 用户清空数据后不会自动重灌，除非在设置里手动「重置示例数据」。
enum SeedData {
    private struct Draft {
        let title: String
        let content: String
        let tags: [String]
        let source: CaptureSource
        let hoursAgo: Double
    }

    private static let drafts: [Draft] = [
        Draft(title: "贝叶斯推断",
              content: """
              用先验概率加上新证据，得到后验概率。核心公式：P(θ|D) ∝ P(D|θ)·P(θ)。
              直觉是「新证据不应该推翻旧信念，而是修正它」。
              难点通常在先验怎么选，以及似然函数的建模是否合理。
              """,
              tags: ["概率", "统计"],
              source: .manual,
              hoursAgo: 52),
        Draft(title: "卡尔曼滤波",
              content: """
              在线性高斯假设下做最优状态估计的递归算法：预测（先验）→ 用观测更新（后验）。
              它本质上是贝叶斯推断在动态系统上的特例，只是把分布限制成高斯，可以只用均值和协方差表示。
              调参主要看 Q（过程噪声）和 R（观测噪声）的比例。
              """,
              tags: ["状态估计", "算法"],
              source: .text,
              hoursAgo: 40),
        Draft(title: "粒子滤波为什么需要它",
              content: """
              当系统非线性、噪声非高斯时，高斯假设崩了，卡尔曼滤波就不再最优。
              粒子滤波用一堆带权样本近似后验分布，代价是计算量大、会有粒子退化。
              重采样是缓解退化的手段，但也带来样本贫化问题。
              """,
              tags: ["状态估计", "算法"],
              source: .text,
              hoursAgo: 30),
        Draft(title: "费曼学习法",
              content: """
              四步：选一个概念 → 假装讲给外行听 → 卡住的地方回去补 → 简化语言再用类比讲一遍。
              关键不是「读懂了」，而是能不能不看资料复述出来。讲不顺的地方就是理解的缺口。
              """,
              tags: ["学习方法"],
              source: .voice,
              hoursAgo: 20),
        Draft(title: "间隔重复与遗忘曲线",
              content: """
              艾宾浩斯遗忘曲线：遗忘先快后慢。在快要忘记的临界点复习，记忆保持率最高。
              间隔重复就是把这个临界点交给算法排期，SM-2 用难度系数 ease 动态拉长间隔。
              复习太密是浪费，太疏就白学。
              """,
              tags: ["学习方法", "记忆"],
              source: .text,
              hoursAgo: 12),
        Draft(title: "双链笔记的价值",
              content: """
              传统文件夹是树，双链是网。写笔记时不用先想「放哪个目录」，只写 [[链接]]，
              结构会随着笔记变多自己长出来。回链让旧笔记重新被看见。
              图谱视图的意义在于暴露「孤岛笔记」——那些没有任何连接的笔记，往往是想了一半的东西。
              """,
              tags: ["知识管理", "记忆"],
              source: .manual,
              hoursAgo: 4)
    ]

    static func makeNotes(now: Date = Date()) -> [Note] {
        drafts.map { draft in
            Note(title: draft.title,
                 content: draft.content,
                 tags: draft.tags,
                 source: draft.source,
                 createdAt: now.addingTimeInterval(-draft.hoursAgo * 3600))
        }
    }
}
