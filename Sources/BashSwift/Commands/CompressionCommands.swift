import ArgumentParser
import Compression
import Foundation

struct GzipCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.customShort("d"), .customLong("decompress")], help: "Decompress")
        var decompress = false

        @Flag(name: .short, help: "Write output on standard output")
        var c = false

        @Flag(name: .short, help: "Keep input files")
        var k = false

        @Flag(name: .short, help: "Force overwrite of output files")
        var f = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "gzip"
    static let overview = "Compress or decompress files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.decompress {
            return await CompressionCommandRunner.gunzip(
                context: &context,
                files: options.files,
                writeToStdout: options.c,
                keepInput: options.k,
                forceOverwrite: options.f,
                commandName: name
            )
        }

        return await CompressionCommandRunner.gzip(
            context: &context,
            files: options.files,
            writeToStdout: options.c,
            keepInput: options.k,
            forceOverwrite: options.f,
            commandName: name
        )
    }
}

struct GunzipCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Write output on standard output")
        var c = false

        @Flag(name: .short, help: "Keep input files")
        var k = false

        @Flag(name: .short, help: "Force overwrite of output files")
        var f = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "gunzip"
    static let overview = "Decompress files in gzip format"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        await CompressionCommandRunner.gunzip(
            context: &context,
            files: options.files,
            writeToStdout: options.c,
            keepInput: options.k,
            forceOverwrite: options.f,
            commandName: name
        )
    }
}

struct ZcatCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "zcat"
    static let overview = "Decompress gzip files to standard output"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        await CompressionCommandRunner.gunzip(
            context: &context,
            files: options.files,
            writeToStdout: true,
            keepInput: true,
            forceOverwrite: true,
            commandName: name
        )
    }
}

struct TarCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Create a new archive")
        var c = false

        @Flag(name: .short, help: "Extract from an archive")
        var x = false

        @Flag(name: .short, help: "List archive contents")
        var t = false

        @Flag(name: .short, help: "Use gzip compression/decompression")
        var z = false

        @Option(name: .short, help: "Archive file")
        var f: String?

        @Option(name: .customShort("C"), help: "Change to directory")
        var C: String?

        @Argument(help: "Paths")
        var paths: [String] = []
    }

    static let name = "tar"
    static let overview = "Create, extract, and list tar archives"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let modeCount = [options.c, options.x, options.t].filter { $0 }.count
        guard modeCount == 1 else {
            context.writeStderr("tar: exactly one of -c, -x, or -t is required\n")
            return 2
        }

        guard let archiveArg = options.f, !archiveArg.isEmpty else {
            context.writeStderr("tar: archive file is required (-f)\n")
            return 2
        }

        if options.c {
            return await createArchive(context: &context, options: options, archiveArg: archiveArg)
        }
        if options.x {
            return await extractArchive(context: &context, options: options, archiveArg: archiveArg)
        }
        return await listArchive(context: &context, options: options, archiveArg: archiveArg)
    }

    private static func createArchive(
        context: inout CommandContext,
        options: Options,
        archiveArg: String
    ) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("tar: refusing to create an empty archive\n")
            return 2
        }

        let baseDirectory = options.C.map(context.resolvePath) ?? context.currentDirectory

        var entries: [TarCodec.Entry] = []
        var seen = Set<String>()

        for operand in options.paths {
            let resolvedInputPath = PathUtils.normalize(path: operand, currentDirectory: baseDirectory)
            let archivePath = archivePathForOperand(operand, resolvedPath: resolvedInputPath)
            do {
                entries.append(
                    contentsOf: try await collectTarEntries(
                        virtualPath: resolvedInputPath,
                        archivePath: archivePath,
                        filesystem: context.filesystem,
                        seenPaths: &seen
                    )
                )
            } catch {
                context.writeStderr("tar: \(operand): \(error)\n")
                return 1
            }
        }

        do {
            let tarData = try TarCodec.encode(entries: entries)
            let outputData = options.z ? try GzipCodec.compress(tarData) : tarData
            let archivePath = context.resolvePath(archiveArg)
            try await context.filesystem.writeFile(path: archivePath, data: outputData, append: false)
            return 0
        } catch {
            context.writeStderr("tar: \(error)\n")
            return 1
        }
    }

    private static func listArchive(
        context: inout CommandContext,
        options: Options,
        archiveArg: String
    ) async -> Int32 {
        do {
            let entries = try await readTarEntries(context: &context, archiveArg: archiveArg, forceGzip: options.z)
            for entry in filterEntries(entries: entries, filters: options.paths) {
                context.writeStdout("\(entry.path)\n")
            }
            return 0
        } catch {
            context.writeStderr("tar: \(error)\n")
            return 1
        }
    }

    private static func extractArchive(
        context: inout CommandContext,
        options: Options,
        archiveArg: String
    ) async -> Int32 {
        do {
            let entries = try await readTarEntries(context: &context, archiveArg: archiveArg, forceGzip: options.z)
            let destinationRoot = options.C.map(context.resolvePath) ?? context.currentDirectory
            try await context.filesystem.createDirectory(path: destinationRoot, recursive: true)

            for entry in filterEntries(entries: entries, filters: options.paths) {
                let outputPath = PathUtils.normalize(path: entry.path, currentDirectory: destinationRoot)
                switch entry.kind {
                case .directory:
                    try await context.filesystem.createDirectory(path: outputPath, recursive: true)
                    try? await context.filesystem.setPermissions(path: outputPath, permissions: entry.mode)
                case let .file(data):
                    let parent = PathUtils.dirname(outputPath)
                    try await context.filesystem.createDirectory(path: parent, recursive: true)
                    try await context.filesystem.writeFile(path: outputPath, data: data, append: false)
                    try? await context.filesystem.setPermissions(path: outputPath, permissions: entry.mode)
                }
            }
            return 0
        } catch {
            context.writeStderr("tar: \(error)\n")
            return 1
        }
    }

    private static func readTarEntries(
        context: inout CommandContext,
        archiveArg: String,
        forceGzip: Bool
    ) async throws -> [TarCodec.Entry] {
        let archivePath = context.resolvePath(archiveArg)
        let archiveData = try await context.filesystem.readFile(path: archivePath)
        let isGzipData = GzipCodec.looksLikeGzip(archiveData)

        let tarData: Data
        if forceGzip || isGzipData {
            tarData = try GzipCodec.decompress(archiveData)
        } else {
            tarData = archiveData
        }

        return try TarCodec.decode(data: tarData)
    }

    private static func filterEntries(entries: [TarCodec.Entry], filters: [String]) -> [TarCodec.Entry] {
        guard !filters.isEmpty else {
            return entries
        }

        let normalizedFilters = filters.map(normalizeFilterPath)
        return entries.filter { entry in
            let entryPath = normalizeFilterPath(entry.path)
            return normalizedFilters.contains { filter in
                entryPath == filter || entryPath.hasPrefix(filter + "/")
            }
        }
    }

    private static func normalizeFilterPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasPrefix("./") {
            value.removeFirst(2)
        }
        return value
    }

    private static func archivePathForOperand(_ operand: String, resolvedPath: String) -> String {
        let normalizedOperand = PathUtils.normalize(path: operand, currentDirectory: "/")
        var archivePath = String(normalizedOperand.dropFirst())
        if archivePath.isEmpty {
            archivePath = PathUtils.basename(resolvedPath)
        }
        if archivePath.isEmpty {
            archivePath = "root"
        }
        return archivePath
    }

    private static func collectTarEntries(
        virtualPath: String,
        archivePath: String,
        filesystem: any ShellFilesystem,
        seenPaths: inout Set<String>
    ) async throws -> [TarCodec.Entry] {
        let info = try await filesystem.stat(path: virtualPath)
        let cleanPath = TarCodec.cleanArchivePath(archivePath)

        if info.isDirectory {
            let directoryPath = cleanPath.hasSuffix("/") ? cleanPath : cleanPath + "/"
            var output: [TarCodec.Entry] = []
            if seenPaths.insert(directoryPath).inserted {
                output.append(
                    .directory(
                        path: directoryPath,
                        mode: info.permissions,
                        modificationTime: modificationTime(info.modificationDate)
                    )
                )
            }

            let children = try await filesystem.listDirectory(path: virtualPath).sorted { $0.name < $1.name }
            for child in children {
                let childVirtualPath = PathUtils.join(virtualPath, child.name)
                let childArchivePath = directoryPath + child.name
                output.append(
                    contentsOf: try await collectTarEntries(
                        virtualPath: childVirtualPath,
                        archivePath: childArchivePath,
                        filesystem: filesystem,
                        seenPaths: &seenPaths
                    )
                )
            }
            return output
        }

        if seenPaths.insert(cleanPath).inserted {
            let data = try await filesystem.readFile(path: virtualPath)
            return [
                .file(
                    path: cleanPath,
                    data: data,
                    mode: info.permissions,
                    modificationTime: modificationTime(info.modificationDate)
                )
            ]
        }
        return []
    }

    private static func modificationTime(_ date: Date?) -> Int {
        Int((date ?? Date()).timeIntervalSince1970)
    }
}

private enum CompressionCommandRunner {
    static func gzip(
        context: inout CommandContext,
        files: [String],
        writeToStdout: Bool,
        keepInput: Bool,
        forceOverwrite: Bool,
        commandName: String
    ) async -> Int32 {
        if files.isEmpty {
            do {
                context.stdout.append(try GzipCodec.compress(context.stdin))
                return 0
            } catch {
                context.writeStderr("\(commandName): \(error)\n")
                return 1
            }
        }

        var failed = false
        for file in files {
            let sourcePath = context.resolvePath(file)
            do {
                let input = try await context.filesystem.readFile(path: sourcePath)
                let output = try GzipCodec.compress(input)

                if writeToStdout {
                    context.stdout.append(output)
                    continue
                }

                let destinationPath = sourcePath + ".gz"
                if !forceOverwrite, await context.filesystem.exists(path: destinationPath) {
                    context.writeStderr("\(commandName): \(file).gz: already exists\n")
                    failed = true
                    continue
                }

                try await context.filesystem.writeFile(path: destinationPath, data: output, append: false)
                if !keepInput {
                    try await context.filesystem.remove(path: sourcePath, recursive: false)
                }
            } catch {
                context.writeStderr("\(commandName): \(file): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }

    static func gunzip(
        context: inout CommandContext,
        files: [String],
        writeToStdout: Bool,
        keepInput: Bool,
        forceOverwrite: Bool,
        commandName: String
    ) async -> Int32 {
        if files.isEmpty {
            do {
                context.stdout.append(try GzipCodec.decompress(context.stdin))
                return 0
            } catch {
                context.writeStderr("\(commandName): \(error)\n")
                return 1
            }
        }

        var failed = false
        for file in files {
            let sourcePath = context.resolvePath(file)
            do {
                let input = try await context.filesystem.readFile(path: sourcePath)
                let output = try GzipCodec.decompress(input)

                if writeToStdout {
                    context.stdout.append(output)
                    continue
                }

                let destinationPath = gunzipOutputPath(for: sourcePath)
                if !forceOverwrite, await context.filesystem.exists(path: destinationPath) {
                    context.writeStderr("\(commandName): \(PathUtils.basename(destinationPath)): already exists\n")
                    failed = true
                    continue
                }

                try await context.filesystem.writeFile(path: destinationPath, data: output, append: false)
                if !keepInput {
                    try await context.filesystem.remove(path: sourcePath, recursive: false)
                }
            } catch {
                context.writeStderr("\(commandName): \(file): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }

    private static func gunzipOutputPath(for sourcePath: String) -> String {
        if sourcePath.hasSuffix(".tgz") {
            return String(sourcePath.dropLast(4)) + ".tar"
        }
        if sourcePath.hasSuffix(".gz") {
            return String(sourcePath.dropLast(3))
        }
        return sourcePath + ".out"
    }
}

private enum GzipCodec {
    static func compress(_ input: Data) throws -> Data {
        let compressedPayload = try DeflateCodec.compress(input)
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        output.append(compressedPayload)

        appendLittleEndianUInt32(CRC32.checksum(input), to: &output)
        appendLittleEndianUInt32(UInt32(truncatingIfNeeded: input.count), to: &output)
        return output
    }

    static func decompress(_ input: Data) throws -> Data {
        let bytes = [UInt8](input)
        guard bytes.count >= 18 else {
            throw ShellError.unsupported("invalid gzip stream")
        }
        guard looksLikeGzip(input) else {
            throw ShellError.unsupported("not in gzip format")
        }

        let flags = bytes[3]
        var index = 10

        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            let extraLength = Int(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            index += 2
            guard index + extraLength <= bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            index += extraLength
        }

        if flags & 0x08 != 0 {
            while index < bytes.count, bytes[index] != 0x00 {
                index += 1
            }
            guard index < bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            index += 1
        }

        if flags & 0x10 != 0 {
            while index < bytes.count, bytes[index] != 0x00 {
                index += 1
            }
            guard index < bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            index += 1
        }

        if flags & 0x02 != 0 {
            guard index + 2 <= bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            index += 2
        }

        guard index <= bytes.count - 8 else {
            throw ShellError.unsupported("invalid gzip stream")
        }

        let payload = Data(bytes[index..<(bytes.count - 8)])
        let expectedCRC = littleEndianUInt32(from: bytes, at: bytes.count - 8)
        let expectedSize = littleEndianUInt32(from: bytes, at: bytes.count - 4)

        let output = try DeflateCodec.decompress(payload)
        guard CRC32.checksum(output) == expectedCRC else {
            throw ShellError.unsupported("gzip CRC mismatch")
        }
        guard UInt32(truncatingIfNeeded: output.count) == expectedSize else {
            throw ShellError.unsupported("gzip size mismatch")
        }

        return output
    }

    static func looksLikeGzip(_ data: Data) -> Bool {
        guard data.count >= 2 else {
            return false
        }
        return data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    private static func littleEndianUInt32(from bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    private static func appendLittleEndianUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }
}

private enum DeflateCodec {
    static func compress(_ input: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk {
                output.append(chunk)
            }
        }
        try filter.write(input)
        try filter.finalize()
        return output
    }

    static func decompress(_ input: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
            if let chunk {
                output.append(chunk)
            }
        }
        try filter.write(input)
        try filter.finalize()
        return output
    }
}

private enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { value in
            var c = UInt32(value)
            for _ in 0..<8 {
                if c & 1 == 1 {
                    c = 0xedb88320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return ~crc
    }
}

private enum TarCodec {
    struct Entry {
        enum Kind {
            case file(Data)
            case directory
        }

        let path: String
        let kind: Kind
        let mode: Int
        let modificationTime: Int

        static func file(path: String, data: Data, mode: Int, modificationTime: Int) -> Entry {
            Entry(path: path, kind: .file(data), mode: mode, modificationTime: modificationTime)
        }

        static func directory(path: String, mode: Int, modificationTime: Int) -> Entry {
            Entry(path: path, kind: .directory, mode: mode, modificationTime: modificationTime)
        }
    }

    static func cleanArchivePath(_ path: String) -> String {
        var output = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if output.hasPrefix("./") {
            output.removeFirst(2)
        }
        if output.isEmpty {
            output = "root"
        }
        return output
    }

    static func encode(entries: [Entry]) throws -> Data {
        var archive = Data()
        for entry in entries {
            try appendEntry(entry, to: &archive)
        }
        archive.append(Data(repeating: 0x00, count: 1024))
        return archive
    }

    static func decode(data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        var offset = 0
        var entries: [Entry] = []

        while offset + 512 <= bytes.count {
            let block = Array(bytes[offset..<(offset + 512)])
            if block.allSatisfy({ $0 == 0 }) {
                break
            }

            let name = parseName(from: block)
            let mode = parseOctal(from: block, offset: 100, length: 8)
            let size = parseOctal(from: block, offset: 124, length: 12)
            let typeFlag = block[156]

            let payloadStart = offset + 512
            let payloadLength = Int(size)
            let paddedLength = ((payloadLength + 511) / 512) * 512
            guard payloadStart + paddedLength <= bytes.count else {
                throw ShellError.unsupported("invalid tar stream")
            }

            if typeFlag == 53 { // '5'
                let normalizedName = name.hasSuffix("/") ? name : name + "/"
                entries.append(.directory(path: normalizedName, mode: mode, modificationTime: 0))
            } else {
                let payloadEnd = payloadStart + payloadLength
                let payload = Data(bytes[payloadStart..<payloadEnd])
                entries.append(.file(path: name, data: payload, mode: mode, modificationTime: 0))
            }

            offset = payloadStart + paddedLength
        }

        return entries
    }

    private static func appendEntry(_ entry: Entry, to archive: inout Data) throws {
        let path = cleanArchivePath(entry.path)
        let (nameField, prefixField) = try splitPath(path)

        var header = [UInt8](repeating: 0x00, count: 512)

        try writeString(nameField, to: &header, offset: 0, length: 100)
        try writeOctal(entry.mode & 0o7777, to: &header, offset: 100, length: 8)
        try writeOctal(0, to: &header, offset: 108, length: 8) // uid
        try writeOctal(0, to: &header, offset: 116, length: 8) // gid

        let payloadSize: Int
        let typeFlag: UInt8
        let payload: Data
        switch entry.kind {
        case let .file(data):
            payloadSize = data.count
            typeFlag = 48 // '0'
            payload = data
        case .directory:
            payloadSize = 0
            typeFlag = 53 // '5'
            payload = Data()
        }

        try writeOctal(payloadSize, to: &header, offset: 124, length: 12)
        try writeOctal(entry.modificationTime, to: &header, offset: 136, length: 12)

        for index in 148..<156 {
            header[index] = 0x20
        }

        header[156] = typeFlag
        try writeString("ustar", to: &header, offset: 257, length: 6)
        try writeString("00", to: &header, offset: 263, length: 2)
        try writeString("user", to: &header, offset: 265, length: 32)
        try writeString("group", to: &header, offset: 297, length: 32)
        if let prefixField {
            try writeString(prefixField, to: &header, offset: 345, length: 155)
        }

        let checksum = header.reduce(0) { $0 + Int($1) }
        try writeChecksum(checksum, to: &header)

        archive.append(contentsOf: header)
        archive.append(payload)

        if payloadSize % 512 != 0 {
            archive.append(Data(repeating: 0x00, count: 512 - (payloadSize % 512)))
        }
    }

    private static func parseName(from header: [UInt8]) -> String {
        let name = parseString(from: header, offset: 0, length: 100)
        let prefix = parseString(from: header, offset: 345, length: 155)
        if prefix.isEmpty {
            return name
        }
        return prefix + "/" + name
    }

    private static func parseString(from header: [UInt8], offset: Int, length: Int) -> String {
        let slice = header[offset..<(offset + length)]
        let bytes = Array(slice.prefix { $0 != 0x00 })
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseOctal(from header: [UInt8], offset: Int, length: Int) -> Int {
        let raw = parseString(from: header, offset: offset, length: length)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return 0
        }
        return Int(trimmed, radix: 8) ?? 0
    }

    private static func splitPath(_ path: String) throws -> (name: String, prefix: String?) {
        if path.utf8.count <= 100 {
            return (path, nil)
        }

        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else {
            throw ShellError.unsupported("tar path is too long: \(path)")
        }

        for split in stride(from: parts.count - 1, through: 1, by: -1) {
            let prefix = parts[..<split].joined(separator: "/")
            let name = parts[split...].joined(separator: "/")
            if prefix.utf8.count <= 155, name.utf8.count <= 100 {
                return (name, prefix)
            }
        }

        throw ShellError.unsupported("tar path is too long: \(path)")
    }

    private static func writeString(
        _ value: String,
        to header: inout [UInt8],
        offset: Int,
        length: Int
    ) throws {
        let bytes = [UInt8](value.utf8)
        guard bytes.count <= length else {
            throw ShellError.unsupported("tar header field overflow")
        }
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
    }

    private static func writeOctal(
        _ value: Int,
        to header: inout [UInt8],
        offset: Int,
        length: Int
    ) throws {
        guard value >= 0 else {
            throw ShellError.unsupported("negative tar numeric field")
        }
        let maxDigits = max(1, length - 1)
        let encoded = String(value, radix: 8)
        guard encoded.utf8.count <= maxDigits else {
            throw ShellError.unsupported("tar numeric field overflow")
        }

        let padded = String(repeating: "0", count: maxDigits - encoded.utf8.count) + encoded
        let bytes = [UInt8](padded.utf8)
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
        header[offset + maxDigits] = 0x00
    }

    private static func writeChecksum(_ value: Int, to header: inout [UInt8]) throws {
        let encoded = String(value, radix: 8)
        guard encoded.utf8.count <= 6 else {
            throw ShellError.unsupported("tar checksum overflow")
        }

        let padded = String(repeating: "0", count: 6 - encoded.utf8.count) + encoded
        let bytes = [UInt8](padded.utf8)
        for (index, byte) in bytes.enumerated() {
            header[148 + index] = byte
        }
        header[154] = 0x00
        header[155] = 0x20
    }
}
