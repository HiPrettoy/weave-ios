import Foundation

/// 极简 ZIP 读写：只用「存储」模式（不压缩），够装一份备份用。
///
/// 为什么自己写：项目坚持零第三方依赖，而 iOS 16 没有现成的 zip API
/// （AppleArchive 是流式的，拼一个能被桌面解压的 .zip 反而更绕）。
/// 备份里本来就是已经压过一遍的 JPEG 与 JSON，再上 deflate 收益很小。
///
/// 产出的文件是标准 ZIP：macOS「归档实用工具」、Windows 资源管理器、7-Zip 都能直接打开。
enum ZipArchive {
    private static let localSignature: UInt32 = 0x0403_4b50
    private static let centralSignature: UInt32 = 0x0201_4b50
    private static let endSignature: UInt32 = 0x0605_4b50

    struct Entry {
        var name: String
        var data: Data
    }

    // MARK: - 写

    static func make(_ entries: [Entry]) -> Data {
        var output = Data()
        var central = Data()

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)

            // 本地文件头
            output.append(uint32: localSignature)
            output.append(uint16: 20)              // 解压所需版本
            output.append(uint16: 0x0800)          // 文件名是 UTF-8
            output.append(uint16: 0)               // 0 = 存储，不压缩
            output.append(uint16: 0)               // 修改时间
            output.append(uint16: 0x21)            // 修改日期（1980-01-01）
            output.append(uint32: crc)
            output.append(uint32: size)            // 压缩后大小
            output.append(uint32: size)            // 原始大小
            output.append(uint16: UInt16(nameBytes.count))
            output.append(uint16: 0)               // 扩展字段长度
            output.append(contentsOf: nameBytes)
            output.append(entry.data)

            // 中央目录项
            central.append(uint32: centralSignature)
            central.append(uint16: 20)             // 创建者版本
            central.append(uint16: 20)             // 解压所需版本
            central.append(uint16: 0x0800)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0x21)
            central.append(uint32: crc)
            central.append(uint32: size)
            central.append(uint32: size)
            central.append(uint16: UInt16(nameBytes.count))
            central.append(uint16: 0)              // 扩展字段
            central.append(uint16: 0)              // 注释
            central.append(uint16: 0)              // 起始磁盘号
            central.append(uint16: 0)              // 内部属性
            central.append(uint32: 0)              // 外部属性
            central.append(uint32: offset)
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)

        // 中央目录结束记录
        output.append(uint32: endSignature)
        output.append(uint16: 0)                   // 本磁盘号
        output.append(uint16: 0)                   // 中央目录起始磁盘号
        output.append(uint16: UInt16(entries.count))
        output.append(uint16: UInt16(entries.count))
        output.append(uint32: UInt32(central.count))
        output.append(uint32: centralOffset)
        output.append(uint16: 0)                   // 注释长度
        return output
    }

    // MARK: - 读

    /// 解析 ZIP，返回 文件名 → 数据。只支持存储模式，够读自己写的备份。
    static func read(_ data: Data) -> [String: Data]? {
        let bytes = [UInt8](data)
        // 最短的合法 ZIP 就是 22 字节的「结束记录」，没有任何条目
        guard bytes.count >= 22 else { return nil }
        guard let endOffset = findEndRecord(bytes) else { return nil }

        let count = Int(readUInt16(bytes, endOffset + 10))
        let centralOffset = Int(readUInt32(bytes, endOffset + 16))
        // 空包（没有任何条目）是合法的：中央目录长度为 0，偏移也停在 0
        if count == 0 { return [:] }
        guard centralOffset > 0, centralOffset < bytes.count else { return nil }

        var result: [String: Data] = [:]
        var cursor = centralOffset
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count,
                  readUInt32(bytes, cursor) == centralSignature else { return nil }
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localOffset = Int(readUInt32(bytes, cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { return nil }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            cursor = nameStart + nameLength + extraLength + commentLength

            guard localOffset + 30 <= bytes.count,
                  readUInt32(bytes, localOffset) == localSignature else { return nil }
            let localNameLength = Int(readUInt16(bytes, localOffset + 26))
            let localExtraLength = Int(readUInt16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + uncompressedSize <= bytes.count else { return nil }
            result[name] = Data(bytes[dataStart..<(dataStart + uncompressedSize)])
        }
        return result
    }

    private static func findEndRecord(_ bytes: [UInt8]) -> Int? {
        // 注释最长 65535，倒着找签名
        let lowerBound = max(0, bytes.count - 65_557)
        var offset = bytes.count - 22
        while offset >= lowerBound {
            if readUInt32(bytes, offset) == endSignature { return offset }
            offset -= 1
        }
        return nil
    }

    // MARK: - 工具

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    /// CRC-32（IEEE 802.3），ZIP 规范要求
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            table[index] = value
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(uint32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
