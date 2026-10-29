import Foundation

/// 中英混排分词：中文按「单字 + 相邻二元组」切分，拉丁文按单词切分。
/// 不依赖任何第三方库，完全离线、确定性输出。
enum TextTokenizer {
    private static let latinStopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can",
        "had", "her", "was", "one", "our", "out", "day", "get", "has", "him",
        "his", "how", "its", "may", "new", "now", "old", "see", "two", "way",
        "who", "boy", "did", "she", "use", "that", "with", "have", "this",
        "will", "your", "from", "they", "know", "want", "been", "good", "much",
        "some", "time", "very", "when", "come", "here", "just", "like", "long",
        "make", "many", "more", "only", "over", "such", "take", "than", "them",
        "then", "were", "what", "which", "into", "about", "would", "there",
        "could", "other", "these", "those", "should", "because", "while", "http",
        "https", "www", "com"
    ]

    private static let cjkStopwords: Set<String> = [
        "的", "了", "是", "在", "和", "我", "有", "就", "不", "人", "都", "一",
        "上", "也", "很", "到", "说", "要", "去", "你", "会", "着", "看", "好",
        "这", "那", "他", "她", "它", "们", "个", "与", "或", "及", "而", "但",
        "为", "以", "于", "之", "其", "此", "被", "把", "让", "给", "从", "对",
        "么", "呢", "吧", "啊", "呀", "哦", "嗯", "还", "又", "再", "才", "只",
        "没", "无", "非", "可", "能", "应", "该", "需", "如", "若", "则", "即",
        "一个", "我们", "你们", "他们", "这个", "那个", "什么", "怎么", "如何",
        "可以", "因为", "所以", "但是", "如果", "然后", "其实", "已经", "还是",
        "就是", "这样", "那样", "一些", "这些", "那些", "自己", "时候", "以及",
        "没有", "不是", "不能", "什么", "为什么", "怎样", "多少"
    ]

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    static func tokens(in text: String) -> [String] {
        var output: [String] = []
        var latinBuffer = ""
        var cjkBuffer: [Character] = []

        func flushLatin() {
            if latinBuffer.count >= 2, !latinStopwords.contains(latinBuffer) {
                output.append(latinBuffer)
            }
            latinBuffer = ""
        }

        func flushCJK() {
            defer { cjkBuffer.removeAll(keepingCapacity: true) }
            guard !cjkBuffer.isEmpty else { return }
            for character in cjkBuffer {
                let single = String(character)
                if !cjkStopwords.contains(single) {
                    output.append(single)
                }
            }
            if cjkBuffer.count >= 2 {
                for index in 0..<(cjkBuffer.count - 1) {
                    let bigram = String(cjkBuffer[index]) + String(cjkBuffer[index + 1])
                    if !cjkStopwords.contains(bigram) {
                        output.append(bigram)
                    }
                }
            }
        }

        for character in text.lowercased() {
            guard let scalar = character.unicodeScalars.first else { continue }
            if isCJK(scalar) {
                flushLatin()
                cjkBuffer.append(character)
            } else if character.isLetter || character.isNumber {
                flushCJK()
                latinBuffer.append(character)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return output
    }
}
