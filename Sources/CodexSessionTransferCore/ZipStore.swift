import Foundation

enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index in
            var value = UInt32(index)
            for _ in 0..<8 {
                if value & 1 == 1 {
                    value = 0xEDB88320 ^ (value >> 1)
                } else {
                    value >>= 1
                }
            }
            return value
        }
    }()

    static func hash(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

enum ZipStore {
    struct Entry: Equatable {
        var name: String
        var data: Data
    }

    static func archive(_ entries: [Entry], validateNames: Bool = true) throws -> Data {
        var seen = Set<String>()
        var local = ByteWriter()
        var stored: [(entry: Entry, crc: UInt32, offset: UInt32)] = []
        for entry in entries {
            if validateNames {
                try validateName(entry.name)
            }
            if !seen.insert(entry.name).inserted {
                throw TransferError.invalidPackage("The session package repeats \(entry.name).")
            }
            guard local.data.count <= Int(UInt32.max), entry.data.count <= Int(UInt32.max) else {
                throw TransferError.invalidPackage("This session is larger than 1 GB.")
            }
            let offset = UInt32(local.data.count)
            let crc = CRC32.hash(entry.data)
            let name = Data(entry.name.utf8)
            guard name.count <= Int(UInt16.max) else {
                throw TransferError.invalidPackage("The session package contains an invalid file name.")
            }
            local.u32(0x0403_4B50)
            local.u16(20)
            local.u16(0x0800)
            local.u16(0)
            local.u16(0)
            local.u16(0)
            local.u32(crc)
            local.u32(UInt32(entry.data.count))
            local.u32(UInt32(entry.data.count))
            local.u16(UInt16(name.count))
            local.u16(0)
            local.bytes(name)
            local.bytes(entry.data)
            stored.append((entry, crc, offset))
        }

        var central = ByteWriter()
        for item in stored {
            let name = Data(item.entry.name.utf8)
            central.u32(0x0201_4B50)
            central.u16(20)
            central.u16(20)
            central.u16(0x0800)
            central.u16(0)
            central.u16(0)
            central.u16(0)
            central.u32(item.crc)
            central.u32(UInt32(item.entry.data.count))
            central.u32(UInt32(item.entry.data.count))
            central.u16(UInt16(name.count))
            central.u16(0)
            central.u16(0)
            central.u16(0)
            central.u16(0)
            central.u32(0)
            central.u32(item.offset)
            central.bytes(name)
        }

        guard stored.count <= Int(UInt16.max),
              local.data.count <= Int(UInt32.max),
              central.data.count <= Int(UInt32.max) else {
            throw TransferError.invalidPackage("This session is larger than 1 GB.")
        }
        var archive = local.data
        let centralOffset = UInt32(archive.count)
        archive.append(central.data)
        var end = ByteWriter()
        end.u32(0x0605_4B50)
        end.u16(0)
        end.u16(0)
        end.u16(UInt16(stored.count))
        end.u16(UInt16(stored.count))
        end.u32(UInt32(central.data.count))
        end.u32(centralOffset)
        end.u16(0)
        archive.append(end.data)
        return archive
    }

    static func extract(_ data: Data) throws -> [String: Data] {
        if data.count > SessionTransfer.maxPackageBytes + (64 * 1024 * 1024) {
            throw TransferError.invalidPackage("This session is larger than 1 GB.")
        }
        let eocd = try endOfCentralDirectory(in: data)
        var reader = ByteReader(data)
        reader.offset = eocd
        let signature = try reader.u32()
        guard signature == 0x0605_4B50 else {
            throw TransferError.invalidPackage("The session package is not a zip archive.")
        }
        _ = try reader.u16()
        _ = try reader.u16()
        _ = try reader.u16()
        let entryCount = try reader.u16()
        let centralSize = try reader.u32()
        let centralOffset = try reader.u32()
        if centralOffset == 0xFFFF_FFFF || centralSize == 0xFFFF_FFFF {
            throw TransferError.invalidPackage("This session is larger than 1 GB.")
        }
        reader.offset = Int(centralOffset)
        var files: [String: Data] = [:]
        for _ in 0..<entryCount {
            let header = try reader.u32()
            guard header == 0x0201_4B50 else {
                throw TransferError.invalidPackage("The session package is damaged.")
            }
            _ = try reader.u16()
            _ = try reader.u16()
            _ = try reader.u16()
            let method = try reader.u16()
            _ = try reader.u16()
            _ = try reader.u16()
            let crc = try reader.u32()
            let compressedSize = try reader.u32()
            let uncompressedSize = try reader.u32()
            let nameLength = try reader.u16()
            let extraLength = try reader.u16()
            let commentLength = try reader.u16()
            _ = try reader.u16()
            _ = try reader.u16()
            _ = try reader.u32()
            let localOffset = try reader.u32()
            let nameData = try reader.take(Int(nameLength))
            try reader.skip(Int(extraLength) + Int(commentLength))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw TransferError.invalidPackage("The session package contains an invalid file name.")
            }
            try validateName(name)
            if method != 0 || compressedSize != uncompressedSize {
                throw TransferError.invalidPackage("The session package is damaged.")
            }
            let fileData = try localFile(in: data, offset: Int(localOffset), size: Int(compressedSize))
            guard CRC32.hash(fileData) == crc else {
                throw TransferError.invalidPackage("The session package is damaged.")
            }
            if files[name] != nil {
                throw TransferError.invalidPackage("The session package repeats \(name).")
            }
            files[name] = fileData
        }
        return files
    }

    static func validateName(_ name: String) throws {
        if name.isEmpty || name.hasPrefix("/") || name.contains("\\") || name.contains("\u{0}") {
            throw TransferError.invalidPackage("The session package contains an invalid file name.")
        }
        for part in name.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." || part == ".." {
                throw TransferError.invalidPackage("The session package contains an invalid file name.")
            }
        }
    }

    private static func localFile(in data: Data, offset: Int, size: Int) throws -> Data {
        var reader = ByteReader(data)
        reader.offset = offset
        let signature = try reader.u32()
        guard signature == 0x0403_4B50 else {
            throw TransferError.invalidPackage("The session package is damaged.")
        }
        _ = try reader.u16()
        _ = try reader.u16()
        _ = try reader.u16()
        _ = try reader.u16()
        _ = try reader.u16()
        _ = try reader.u32()
        _ = try reader.u32()
        _ = try reader.u32()
        let nameLength = try reader.u16()
        let extraLength = try reader.u16()
        try reader.skip(Int(nameLength) + Int(extraLength))
        return try reader.take(size)
    }

    private static func endOfCentralDirectory(in data: Data) throws -> Int {
        guard data.count >= 22 else {
            throw TransferError.invalidPackage("The session package is not a zip archive.")
        }
        let lower = max(0, data.count - (22 + 65535))
        var offset = data.count - 22
        while offset >= lower {
            let start = data.index(data.startIndex, offsetBy: offset)
            if data[start] == 0x50,
               data[data.index(start, offsetBy: 1)] == 0x4B,
               data[data.index(start, offsetBy: 2)] == 0x05,
               data[data.index(start, offsetBy: 3)] == 0x06 {
                return offset
            }
            if offset == 0 { break }
            offset -= 1
        }
        throw TransferError.invalidPackage("The session package is not a zip archive.")
    }
}

private struct ByteWriter {
    var data = Data()

    mutating func u16(_ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    mutating func u32(_ value: UInt32) {
        u16(UInt16(value & 0xFFFF))
        u16(UInt16((value >> 16) & 0xFFFF))
    }

    mutating func bytes(_ value: Data) {
        data.append(value)
    }
}

private struct ByteReader {
    let data: Data
    var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func u16() throws -> UInt16 {
        let low = try byte()
        let high = try byte()
        return UInt16(low) | (UInt16(high) << 8)
    }

    mutating func u32() throws -> UInt32 {
        let low = try u16()
        let high = try u16()
        return UInt32(low) | (UInt32(high) << 16)
    }

    mutating func byte() throws -> UInt8 {
        guard offset < data.count else {
            throw TransferError.invalidPackage("The session package is truncated.")
        }
        let index = data.index(data.startIndex, offsetBy: offset)
        offset += 1
        return data[index]
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw TransferError.invalidPackage("The session package is truncated.")
        }
        offset += count
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw TransferError.invalidPackage("The session package is truncated.")
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return data.subdata(in: start..<end)
    }
}
