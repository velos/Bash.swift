import ArgumentParser
import Foundation
import BashCore

struct SortCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Reverse the result")
        var r = false

        @Flag(name: .short, help: "Compare according to string numerical value")
        var n = false

        @Flag(name: .short, help: "Output only the first of an equal run")
        var u = false

        @Flag(name: .short, help: "Fold lower case to upper case characters")
        var f = false

        @Flag(name: .short, help: "Check whether input is sorted")
        var c = false

        @Flag(name: .customShort("V"), help: "Sort version numbers naturally")
        var V = false

        @Flag(name: .short, help: "Compare human-readable numbers")
        var h = false

        @Flag(name: .short, help: "Use NUL instead of newline as the record separator")
        var z = false

        @Option(name: .short, help: "Sort via field key definition")
        var k: [String] = []

        @Option(name: .short, help: "Use SEP instead of whitespace for fields")
        var t: String?

        @Option(name: .short, help: "Write result to FILE instead of standard output")
        var o: String?

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "sort"
    static let overview = "Sort lines of text"

    static func _toAnyBuiltinCommand() -> AnyBuiltinCommand {
        AnyBuiltinCommand(
            name: name,
            aliases: aliases,
            overview: overview
        ) { context, args in
            do {
                let options = try Options.parse(normalizeArguments(args))
                return await run(context: &context, options: options)
            } catch {
                let message = Options.fullMessage(for: error)
                if !message.isEmpty {
                    let output = message.hasSuffix("\n") ? message : message + "\n"
                    let exitCode = Options.exitCode(for: error).rawValue
                    if exitCode == 0 {
                        context.writeStdout(output)
                    } else {
                        context.writeStderr(output)
                    }
                }
                return Options.exitCode(for: error).rawValue
            }
        }
    }

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.h, options.files.isEmpty, context.stdin.isEmpty {
            context.writeStdout(
                """
                OVERVIEW: Sort lines of text

                USAGE: sort [OPTION]... [FILE]...

                """
            )
            return 0
        }
        if options.c, options.o != nil {
            context.writeStderr("sort: cannot combine -c and -o\n")
            return 2
        }

        let fieldSeparator: Character?
        if let rawSeparator = options.t {
            guard rawSeparator.count == 1, let separator = rawSeparator.first else {
                context.writeStderr("sort: field separator must be a single character\n")
                return 2
            }
            fieldSeparator = separator
        } else {
            fieldSeparator = nil
        }

        let inputs = await readInputs(paths: options.files, context: &context)
        let records = inputs.data.flatMap { splitRecords($0, nullSeparated: options.z) }

        let keySpecifications = options.k.compactMap(parseKeySpecification)
        if keySpecifications.count != options.k.count {
            context.writeStderr("sort: invalid field specification\n")
            return 2
        }
        let comparator: (String, String) -> Int = { lhs, rhs in
            compareLines(
                lhs: lhs,
                rhs: rhs,
                options: options,
                keySpecifications: keySpecifications,
                fieldSeparator: fieldSeparator
            )
        }

        if options.c {
            for index in 1..<records.count {
                if comparator(records[index - 1], records[index]) > 0 {
                    context.writeStderr("sort: input is not sorted\n")
                    return 1
                }
            }
            return inputs.hadError ? 1 : 0
        }

        let sortedBase = records.sorted { comparator($0, $1) < 0 }
        let sorted: [String]
        if options.r {
            sorted = Array(sortedBase.reversed())
        } else {
            sorted = sortedBase
        }

        var output: [String] = []
        if options.u {
            var previous: String?
            for line in sorted {
                if let previous, comparator(previous, line) == 0 {
                    continue
                }
                output.append(line)
                previous = line
            }
        } else {
            output = sorted
        }

        let separator = options.z ? "\0" : "\n"
        let rendered = output.isEmpty ? "" : output.joined(separator: separator) + separator
        if let outputFile = options.o {
            do {
                try await context.filesystem.writeFile(
                    path: context.resolvePath(outputFile),
                    data: Data(rendered.utf8),
                    append: false
                )
            } catch {
                context.writeStderr("sort: \(outputFile): \(error)\n")
                return 1
            }
        } else {
            context.writeStdout(rendered)
        }
        return inputs.hadError ? 1 : 0
    }

    private struct SortInputs {
        var data: [Data]
        var hadError: Bool
    }

    private enum ComparisonMode {
        case lexical
        case numeric
        case humanNumeric
        case version
    }

    private struct KeySpecification {
        var startField: Int
        var endField: Int
        var mode: ComparisonMode?
    }

    private static func readInputs(paths: [String], context: inout CommandContext) async -> SortInputs {
        guard !paths.isEmpty else {
            return SortInputs(data: [context.stdin], hadError: false)
        }

        var result = SortInputs(data: [], hadError: false)
        for path in paths {
            do {
                result.data.append(try await context.filesystem.readFile(path: context.resolvePath(path)))
            } catch {
                context.writeStderr("sort: \(path): \(error)\n")
                result.hadError = true
            }
        }
        return result
    }

    private static func splitRecords(_ data: Data, nullSeparated: Bool) -> [String] {
        if nullSeparated {
            return data.split(separator: 0, omittingEmptySubsequences: true).map {
                String(decoding: $0, as: UTF8.self)
            }
        }
        return CommandIO.splitLines(CommandIO.decodeString(data))
    }

    private static func parseKeySpecification(_ key: String) -> KeySpecification? {
        guard !key.isEmpty else { return nil }

        let mode: ComparisonMode?
        if key.contains("V") {
            mode = .version
        } else if key.contains("h") {
            mode = .humanNumeric
        } else if key.contains("n") {
            mode = .numeric
        } else {
            mode = nil
        }

        let numericPortion = key.prefix { $0.isNumber || $0 == "," || $0 == "." }
        let pieces = numericPortion.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = pieces.first else { return nil }
        let startToken = first.split(separator: ".", maxSplits: 1).first.map(String.init) ?? String(first)
        guard let start = Int(startToken), start > 0 else { return nil }

        let end: Int
        if pieces.count == 2 {
            let endToken = pieces[1].split(separator: ".", maxSplits: 1).first.map(String.init) ?? String(pieces[1])
            guard let parsedEnd = Int(endToken), parsedEnd >= start else { return nil }
            end = parsedEnd
        } else {
            end = start
        }
        return KeySpecification(startField: start, endField: end, mode: mode)
    }

    private static func keyForSort(
        line: String,
        specification: KeySpecification?,
        fieldSeparator: Character?
    ) -> String {
        guard let specification else { return line }

        let fields: [String]
        if let fieldSeparator {
            fields = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        } else {
            fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        guard specification.startField <= fields.count else { return "" }
        let end = min(specification.endField, fields.count)
        return fields[(specification.startField - 1)..<end].joined(separator: fieldSeparator.map(String.init) ?? " ")
    }

    private static func compareLines(
        lhs: String,
        rhs: String,
        options: Options,
        keySpecifications: [KeySpecification],
        fieldSeparator: Character?
    ) -> Int {
        let specifications: [KeySpecification?] = keySpecifications.isEmpty ? [nil] : keySpecifications.map(Optional.some)
        for specification in specifications {
            let lhsRawKey = keyForSort(line: lhs, specification: specification, fieldSeparator: fieldSeparator)
            let rhsRawKey = keyForSort(line: rhs, specification: specification, fieldSeparator: fieldSeparator)
            let lhsKey = options.f ? lhsRawKey.lowercased() : lhsRawKey
            let rhsKey = options.f ? rhsRawKey.lowercased() : rhsRawKey
            let mode = specification?.mode ?? globalComparisonMode(options)
            let comparison = compareKeys(lhsKey, rhsKey, mode: mode)
            if comparison != 0 { return comparison }
        }

        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
    }

    private static func globalComparisonMode(_ options: Options) -> ComparisonMode {
        if options.V { return .version }
        if options.h { return .humanNumeric }
        if options.n { return .numeric }
        return .lexical
    }

    private static func compareKeys(_ lhs: String, _ rhs: String, mode: ComparisonMode) -> Int {
        switch mode {
        case .lexical:
            return lhs == rhs ? 0 : (lhs < rhs ? -1 : 1)
        case .numeric:
            return compareNumbers(Double(lhs) ?? 0, Double(rhs) ?? 0)
        case .humanNumeric:
            return compareNumbers(humanReadableNumber(lhs), humanReadableNumber(rhs))
        case .version:
            return compareVersion(lhs, rhs)
        }
    }

    private static func compareNumbers(_ lhs: Double, _ rhs: Double) -> Int {
        if lhs < rhs { return -1 }
        if lhs > rhs { return 1 }
        return 0
    }

    private static func humanReadableNumber(_ value: String) -> Double {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let suffix = trimmed.last, suffix.isLetter else {
            return Double(trimmed) ?? 0
        }
        let multiplier: Double
        switch suffix.uppercased() {
        case "K": multiplier = 1_024
        case "M": multiplier = 1_024 * 1_024
        case "G": multiplier = 1_024 * 1_024 * 1_024
        case "T": multiplier = 1_024 * 1_024 * 1_024 * 1_024
        case "P": multiplier = 1_024 * 1_024 * 1_024 * 1_024 * 1_024
        case "E": multiplier = 1_024 * 1_024 * 1_024 * 1_024 * 1_024 * 1_024
        default: multiplier = 1
        }
        return (Double(trimmed.dropLast()) ?? 0) * multiplier
    }

    private static func compareVersion(_ lhs: String, _ rhs: String) -> Int {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        for index in 0..<max(left.count, right.count) {
            guard index < left.count else { return -1 }
            guard index < right.count else { return 1 }
            let lhsPart = left[index]
            let rhsPart = right[index]
            if lhsPart.numeric, rhsPart.numeric {
                let lhsNumber = lhsPart.value.drop(while: { $0 == "0" })
                let rhsNumber = rhsPart.value.drop(while: { $0 == "0" })
                if lhsNumber.count != rhsNumber.count { return lhsNumber.count < rhsNumber.count ? -1 : 1 }
                if lhsNumber != rhsNumber { return lhsNumber.lexicographicallyPrecedes(rhsNumber) ? -1 : 1 }
            } else if lhsPart.value != rhsPart.value {
                return lhsPart.value < rhsPart.value ? -1 : 1
            }
        }
        return 0
    }

    private static func versionComponents(_ value: String) -> [(value: String, numeric: Bool)] {
        var components: [(String, Bool)] = []
        for character in value {
            let numeric = character.isNumber
            if let last = components.indices.last, components[last].1 == numeric {
                components[last].0.append(character)
            } else {
                components.append((String(character), numeric))
            }
        }
        return components
    }

    private static func normalizeArguments(_ arguments: [String]) -> [String] {
        var normalized: [String] = []
        var passthrough = false
        for argument in arguments {
            if passthrough {
                normalized.append(argument)
                continue
            }
            if argument == "--" {
                passthrough = true
                normalized.append(argument)
                continue
            }
            if argument.hasPrefix("-k"), argument.count > 2 {
                normalized.append("-k")
                normalized.append(String(argument.dropFirst(2)))
            } else if argument.hasPrefix("-t"), argument.count > 2 {
                normalized.append("-t")
                normalized.append(String(argument.dropFirst(2)))
            } else if argument.hasPrefix("-o"), argument.count > 2 {
                normalized.append("-o")
                normalized.append(String(argument.dropFirst(2)))
            } else {
                normalized.append(argument)
            }
        }
        return normalized
    }
}

struct UniqCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Prefix lines by occurrence counts")
        var c = false

        @Flag(name: .short, help: "Only print duplicate lines")
        var d = false

        @Flag(name: .short, help: "Only print unique lines")
        var u = false

        @Flag(name: .short, help: "Ignore case when comparing")
        var i = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "uniq"
    static let overview = "Report or omit repeated lines"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.files.count > 2 {
            context.writeStderr("uniq: extra operand '\(options.files[2])'\n")
            return 1
        }

        let inputPath = options.files.first
        let outputPath = options.files.count == 2 ? options.files[1] : nil
        let readPaths = inputPath.map { [$0] } ?? []
        let inputs = await CommandFS.readInputs(paths: readPaths, context: &context)
        let lines = inputs.contents.flatMap { CommandIO.splitLines($0) }

        var previous: String?
        var previousKey: String?
        var count = 0
        var rendered: [String] = []

        func flushLine(_ line: String?, count: Int) {
            guard let line else { return }
            if options.d, count < 2 {
                return
            }
            if options.u, count != 1 {
                return
            }
            if options.c {
                rendered.append("\(count) \(line)")
            } else {
                rendered.append(line)
            }
        }

        for line in lines {
            let key = options.i ? line.lowercased() : line
            if key == previousKey {
                count += 1
            } else {
                flushLine(previous, count: count)
                previous = line
                previousKey = key
                count = 1
            }
        }

        flushLine(previous, count: count)

        let outputData = Data(rendered.map { "\($0)\n" }.joined().utf8)
        if let outputPath {
            do {
                try await context.filesystem.writeFile(
                    path: context.resolvePath(outputPath),
                    data: outputData,
                    append: false
                )
            } catch {
                context.writeStderr("uniq: \(outputPath): \(error)\n")
                return 1
            }
        } else {
            context.stdout.append(outputData)
        }

        return inputs.hadError ? 1 : 0
    }
}

struct CommCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(parsing: .captureForPassthrough, help: "Options and two input files")
        var args: [String] = []
    }

    static let name = "comm"
    static let overview = "Compare two sorted files line by line"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.args == ["--help"] || options.args == ["-h"] {
            context.writeStdout(
                """
                OVERVIEW: Compare two sorted files line by line

                USAGE: comm [-123] FILE1 FILE2

                OPTIONS:
                  -1      Suppress lines unique to FILE1
                  -2      Suppress lines unique to FILE2
                  -3      Suppress lines common to both files

                """
            )
            return 0
        }

        var suppress1 = false
        var suppress2 = false
        var suppress3 = false
        var files: [String] = []

        for arg in options.args {
            if arg.hasPrefix("-"), arg != "-", arg.dropFirst().allSatisfy({ "123".contains($0) }) {
                for flag in arg.dropFirst() {
                    switch flag {
                    case "1":
                        suppress1 = true
                    case "2":
                        suppress2 = true
                    case "3":
                        suppress3 = true
                    default:
                        break
                    }
                }
            } else {
                files.append(arg)
            }
        }

        guard files.count == 2 else {
            context.writeStderr("comm: expected two input files\n")
            return 1
        }

        let first: [String]
        let second: [String]
        do {
            first = try await readLines(path: files[0], context: &context)
            second = try await readLines(path: files[1], context: &context)
        } catch {
            return 1
        }

        var i = 0
        var j = 0
        while i < first.count || j < second.count {
            if i >= first.count {
                if !suppress2 {
                    context.writeStdout(prefix(column: 2, suppress1: suppress1, suppress2: suppress2) + second[j] + "\n")
                }
                j += 1
                continue
            }

            if j >= second.count {
                if !suppress1 {
                    context.writeStdout(prefix(column: 1, suppress1: suppress1, suppress2: suppress2) + first[i] + "\n")
                }
                i += 1
                continue
            }

            if first[i] == second[j] {
                if !suppress3 {
                    context.writeStdout(prefix(column: 3, suppress1: suppress1, suppress2: suppress2) + first[i] + "\n")
                }
                i += 1
                j += 1
            } else if first[i] < second[j] {
                if !suppress1 {
                    context.writeStdout(prefix(column: 1, suppress1: suppress1, suppress2: suppress2) + first[i] + "\n")
                }
                i += 1
            } else {
                if !suppress2 {
                    context.writeStdout(prefix(column: 2, suppress1: suppress1, suppress2: suppress2) + second[j] + "\n")
                }
                j += 1
            }
        }

        return 0
    }

    private static func readLines(path: String, context: inout CommandContext) async throws -> [String] {
        if path == "-" {
            return CommandIO.decodeLines(context.stdin)
        }

        do {
            let data = try await context.filesystem.readFile(path: context.resolvePath(path))
            return CommandIO.decodeLines(data)
        } catch {
            context.writeStderr("comm: \(path): \(error)\n")
            throw error
        }
    }

    private static func prefix(column: Int, suppress1: Bool, suppress2: Bool) -> String {
        switch column {
        case 1:
            return ""
        case 2:
            return suppress1 ? "" : "\t"
        default:
            return (suppress1 ? "" : "\t") + (suppress2 ? "" : "\t")
        }
    }
}

struct CutCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Option(name: .short, help: "Use DELIM instead of TAB")
        var d: String = "\t"

        @Option(name: .short, help: "Select only these fields")
        var f: String?

        @Option(name: .short, help: "Select only these characters")
        var c: String?

        @Flag(name: .short, help: "Do not print lines with no delimiter characters")
        var s = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "cut"
    static let overview = "Remove sections from each line of files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        enum Mode {
            case field([SelectionRange])
            case character([SelectionRange])
        }

        let mode: Mode
        switch (options.f, options.c) {
        case (.none, .none):
            context.writeStderr("cut: one of -f or -c must be specified\n")
            return 1
        case (.some, .some):
            context.writeStderr("cut: options -f and -c are mutually exclusive\n")
            return 1
        case let (.some(fieldSpec), .none):
            guard let ranges = parseSelectionRanges(fieldSpec), !ranges.isEmpty else {
                context.writeStderr("cut: invalid field list\n")
                return 1
            }
            mode = .field(ranges)
        case let (.none, .some(charSpec)):
            guard let ranges = parseSelectionRanges(charSpec), !ranges.isEmpty else {
                context.writeStderr("cut: invalid character list\n")
                return 1
            }
            mode = .character(ranges)
        }

        if case .field = mode, options.d.isEmpty {
            context.writeStderr("cut: delimiter must not be empty\n")
            return 1
        }

        let delimiter = options.d
        let inputs = await CommandFS.readInputs(paths: options.files, context: &context)

        for content in inputs.contents {
            let lines = CommandIO.splitLines(content)
            for line in lines {
                switch mode {
                case .field(let ranges):
                    if !line.contains(delimiter) {
                        if !options.s {
                            context.writeStdout("\(line)\n")
                        }
                        continue
                    }

                    let parts = line.components(separatedBy: delimiter)
                    let selectedIndexes = selectIndexes(totalCount: parts.count, ranges: ranges)
                    let selected = selectedIndexes.map { parts[$0 - 1] }
                    context.writeStdout(selected.joined(separator: delimiter) + "\n")

                case .character(let ranges):
                    let characters = Array(line)
                    let selectedIndexes = selectIndexes(totalCount: characters.count, ranges: ranges)
                    let selected = selectedIndexes.map { characters[$0 - 1] }
                    context.writeStdout(String(selected) + "\n")
                }
            }
        }

        return inputs.hadError ? 1 : 0
    }
}

struct TrCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Delete characters in SET1")
        var d = false

        @Flag(name: .short, help: "Squeeze repeated characters listed in the last specified SET")
        var s = false

        @Flag(name: .short, help: "Use the complement of SET1")
        var c = false

        @Argument(help: "SET1")
        var source: String

        @Argument(help: "SET2")
        var destination: String?
    }

    static let name = "tr"
    static let overview = "Translate or delete characters"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let input = CommandIO.decodeString(context.stdin)

        if let destination = options.destination {
            if options.source == "[:lower:]" && destination == "[:upper:]" {
                context.writeStdout(input.uppercased())
                return 0
            }
            if options.source == "[:upper:]" && destination == "[:lower:]" {
                context.writeStdout(input.lowercased())
                return 0
            }
        }

        let inputCharacters = Array(input)
        let sourceCharacters = expandCharacterSet(options.source)
        let sourceSet = Set(sourceCharacters)

        let effectiveSourceCharacters: [Character]
        if options.c {
            var seen: Set<Character> = []
            var complement: [Character] = []
            for character in inputCharacters where !sourceSet.contains(character) {
                if seen.insert(character).inserted {
                    complement.append(character)
                }
            }
            effectiveSourceCharacters = complement
        } else {
            effectiveSourceCharacters = sourceCharacters
        }
        let effectiveSourceSet = Set(effectiveSourceCharacters)

        if options.d {
            var transformed = inputCharacters.filter { !effectiveSourceSet.contains($0) }
            if options.s {
                let squeezeSource = options.destination.map(expandCharacterSet) ?? effectiveSourceCharacters
                transformed = squeezeCharacters(transformed, set: Set(squeezeSource))
            }
            context.writeStdout(String(transformed))
            return 0
        }

        if let destination = options.destination {
            let destinationCharacters = expandCharacterSet(destination)
            guard !destinationCharacters.isEmpty else {
                context.writeStderr("tr: replacement set must not be empty\n")
                return 1
            }

            let translationMap = buildTranslationMap(
                source: effectiveSourceCharacters,
                destination: destinationCharacters
            )
            var transformed = inputCharacters.map { character in
                translationMap[character] ?? character
            }
            if options.s {
                transformed = squeezeCharacters(transformed, set: Set(destinationCharacters))
            }
            context.writeStdout(String(transformed))
            return 0
        }

        guard options.s else {
            context.writeStderr("tr: missing replacement string\n")
            return 1
        }

        let squeezed = squeezeCharacters(inputCharacters, set: effectiveSourceSet)
        context.writeStdout(String(squeezed))
        return 0
    }

    private static func buildTranslationMap(
        source: [Character],
        destination: [Character]
    ) -> [Character: Character] {
        guard let finalDestination = destination.last else {
            return [:]
        }

        var map: [Character: Character] = [:]
        for (index, character) in source.enumerated() {
            map[character] = destination[index < destination.count ? index : destination.count - 1]
        }
        if map.isEmpty {
            _ = finalDestination
        }
        return map
    }

    private static func squeezeCharacters(_ characters: [Character], set: Set<Character>) -> [Character] {
        guard !set.isEmpty else {
            return characters
        }

        var output: [Character] = []
        var previous: Character?
        for character in characters {
            if previous == character, set.contains(character) {
                continue
            }
            output.append(character)
            previous = character
        }
        return output
    }

    private static func expandCharacterSet(_ raw: String) -> [Character] {
        if raw.hasPrefix("[:"), raw.hasSuffix(":]"), raw.count > 4 {
            let start = raw.index(raw.startIndex, offsetBy: 2)
            let end = raw.index(raw.endIndex, offsetBy: -2)
            let className = String(raw[start..<end])
            if let classCharacters = posixClassCharacters(named: className) {
                return classCharacters
            }
        }

        let unescaped = decodeEscapes(raw)
        guard unescaped.count >= 3 else {
            return unescaped
        }

        var output: [Character] = []
        var index = 0
        while index < unescaped.count {
            var consumedPOSIXClass = false
            if index + 3 < unescaped.count,
               unescaped[index] == "[",
               unescaped[index + 1] == ":" {
                var cursor = index + 2
                while cursor + 1 < unescaped.count {
                    if unescaped[cursor] == ":", unescaped[cursor + 1] == "]" {
                        let className = String(unescaped[(index + 2)..<cursor])
                        if let classCharacters = posixClassCharacters(named: className) {
                            output.append(contentsOf: classCharacters)
                            index = cursor + 2
                            consumedPOSIXClass = true
                        }
                        break
                    }
                    cursor += 1
                }
            }

            if consumedPOSIXClass {
                continue
            }

            if index + 2 < unescaped.count, unescaped[index + 1] == "-",
               let expandedRange = expandRange(start: unescaped[index], end: unescaped[index + 2]) {
                output.append(contentsOf: expandedRange)
                index += 3
                continue
            }

            output.append(unescaped[index])
            index += 1
        }
        return output
    }

    private static func posixClassCharacters(named className: String) -> [Character]? {
        switch className.lowercased() {
        case "lower":
            return expandRange(start: "a", end: "z")
        case "upper":
            return expandRange(start: "A", end: "Z")
        case "digit":
            return expandRange(start: "0", end: "9")
        case "alpha":
            return (expandRange(start: "A", end: "Z") ?? []) + (expandRange(start: "a", end: "z") ?? [])
        case "alnum":
            return (expandRange(start: "A", end: "Z") ?? [])
                + (expandRange(start: "a", end: "z") ?? [])
                + (expandRange(start: "0", end: "9") ?? [])
        case "space":
            return [" ", "\t", "\n", "\r", "\u{0B}", "\u{0C}"]
        default:
            return nil
        }
    }

    private static func decodeEscapes(_ raw: String) -> [Character] {
        var output: [Character] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character == "\\", raw.index(after: index) < raw.endIndex {
                let nextIndex = raw.index(after: index)
                let escaped = raw[nextIndex]
                switch escaped {
                case "n": output.append("\n")
                case "t": output.append("\t")
                case "r": output.append("\r")
                case "\\": output.append("\\")
                default: output.append(escaped)
                }
                index = raw.index(after: nextIndex)
                continue
            }

            output.append(character)
            index = raw.index(after: index)
        }
        return output
    }

    private static func expandRange(start: Character, end: Character) -> [Character]? {
        guard let startScalar = singleScalar(for: start), let endScalar = singleScalar(for: end) else {
            return nil
        }

        if startScalar.value <= endScalar.value {
            return (startScalar.value...endScalar.value).compactMap {
                UnicodeScalar($0).map(Character.init)
            }
        }

        return (endScalar.value...startScalar.value).reversed().compactMap {
            UnicodeScalar($0).map(Character.init)
        }
    }

    private static func singleScalar(for character: Character) -> UnicodeScalar? {
        let scalars = Array(String(character).unicodeScalars)
        guard scalars.count == 1 else {
            return nil
        }
        return scalars[0]
    }
}

private struct SelectionRange {
    let start: Int?
    let end: Int?

    func contains(_ index: Int) -> Bool {
        if let start, index < start {
            return false
        }
        if let end, index > end {
            return false
        }
        return true
    }
}

private func parseSelectionRanges(_ spec: String) -> [SelectionRange]? {
    let tokens = spec.split(separator: ",").map(String.init)
    guard !tokens.isEmpty else {
        return nil
    }

    var ranges: [SelectionRange] = []
    for token in tokens where !token.isEmpty {
        if token.contains("-") {
            let pieces = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pieces.count == 2 else {
                return nil
            }

            let left = pieces[0].isEmpty ? nil : Int(pieces[0])
            let right = pieces[1].isEmpty ? nil : Int(pieces[1])

            if left == nil, right == nil {
                return nil
            }
            if let left, left <= 0 {
                return nil
            }
            if let right, right <= 0 {
                return nil
            }
            if let left, let right, left > right {
                return nil
            }
            ranges.append(SelectionRange(start: left, end: right))
        } else if let value = Int(token), value > 0 {
            ranges.append(SelectionRange(start: value, end: value))
        } else {
            return nil
        }
    }

    return ranges.isEmpty ? nil : ranges
}

private func selectIndexes(totalCount: Int, ranges: [SelectionRange]) -> [Int] {
    guard totalCount > 0 else {
        return []
    }

    var selected: [Int] = []
    for index in 1...totalCount {
        if ranges.contains(where: { $0.contains(index) }) {
            selected.append(index)
        }
    }
    return selected
}
