import Foundation

enum SQLiteOutputMode: Sendable {
    case list
    case csv
    case json
    case line
    case column
    case table
    case markdown
}

struct SQLiteInvocation: Sendable {
    var mode: SQLiteOutputMode
    var includeHeader: Bool
    var separator: String
    var newline: String
    var nullValue: String
    var readOnly: Bool
    var bail: Bool
    var showVersion: Bool
    var commandScripts: [String]
    var database: String
    var sql: String?
}

enum SQLiteParseResult {
    case success(SQLiteInvocation)
    case usageError(String)
}

enum SQLiteArgumentModel {
    static let helpText = """
    OVERVIEW: Execute SQL statements against a SQLite database

    USAGE: sqlite3 [OPTION]... [DATABASE [SQL]]

    OPTIONS:
      -csv                  set output mode to csv
      -json                 set output mode to json
      -line                 set output mode to line
      -list                 set output mode to list (default)
      -column               set output mode to column
      -table                set output mode to table
      -markdown             set output mode to markdown table
      -header               turn on headers
      -noheader             turn off headers
      -separator SEP        set output column separator
      -newline SEP          set output row separator
      -nullvalue STR        set text for NULL values
      -readonly             open the database read-only
      -bail                 stop after first SQL error
      -cmd SQL              run SQL before processing stdin/SQL argument
      -version              print SQLite library version
      --                    stop parsing options
      -h, --help            show help

    """

    static func parse(_ args: [String]) -> SQLiteParseResult {
        var mode: SQLiteOutputMode = .list
        var includeHeader = false
        var separator = "|"
        var newline = "\n"
        var nullValue = ""
        var readOnly = false
        var bail = false
        var showVersion = false
        var commandScripts: [String] = []
        var positionals: [String] = []

        var index = 0
        while index < args.count {
            let arg = args[index]

            switch arg {
            case "-h", "--help":
                return .usageError(helpText)
            case "--":
                positionals.append(contentsOf: args[(index + 1)...])
                index = args.count
            case "-csv":
                mode = .csv
                if separator == "|" {
                    separator = ","
                }
                index += 1
            case "-json":
                mode = .json
                index += 1
            case "-line":
                mode = .line
                index += 1
            case "-list":
                mode = .list
                if separator == "," {
                    separator = "|"
                }
                index += 1
            case "-column":
                mode = .column
                index += 1
            case "-table":
                mode = .table
                index += 1
            case "-markdown":
                mode = .markdown
                index += 1
            case "-header":
                includeHeader = true
                index += 1
            case "-noheader":
                includeHeader = false
                index += 1
            case "-readonly":
                readOnly = true
                index += 1
            case "-bail":
                bail = true
                index += 1
            case "-version":
                showVersion = true
                index += 1
            case "-separator", "--separator":
                guard index + 1 < args.count else {
                    return .usageError("sqlite3: option requires an argument -- separator\n")
                }
                separator = decodeEscapes(args[index + 1])
                index += 2
            case "-newline", "--newline":
                guard index + 1 < args.count else {
                    return .usageError("sqlite3: option requires an argument -- newline\n")
                }
                newline = decodeEscapes(args[index + 1])
                index += 2
            case "-nullvalue", "--nullvalue":
                guard index + 1 < args.count else {
                    return .usageError("sqlite3: option requires an argument -- nullvalue\n")
                }
                nullValue = args[index + 1]
                index += 2
            case "-cmd", "--cmd":
                guard index + 1 < args.count else {
                    return .usageError("sqlite3: option requires an argument -- cmd\n")
                }
                commandScripts.append(args[index + 1])
                index += 2
            default:
                if let value = parseInlineValue(arg: arg, option: "-separator") {
                    separator = decodeEscapes(value)
                    index += 1
                    continue
                }

                if let value = parseInlineValue(arg: arg, option: "-newline") {
                    newline = decodeEscapes(value)
                    index += 1
                    continue
                }

                if let value = parseInlineValue(arg: arg, option: "-nullvalue") {
                    nullValue = value
                    index += 1
                    continue
                }

                if let value = parseInlineValue(arg: arg, option: "-cmd") {
                    commandScripts.append(value)
                    index += 1
                    continue
                }

                if arg.hasPrefix("-"), arg != "-" {
                    return .usageError("sqlite3: unknown option: \(arg)\n")
                }

                positionals.append(arg)
                index += 1
            }
        }

        if positionals.count > 2 {
            return .usageError("sqlite3: too many positional arguments\n")
        }

        let database: String
        let sql: String?
        switch positionals.count {
        case 0:
            database = ":memory:"
            sql = nil
        case 1:
            database = positionals[0]
            sql = nil
        default:
            database = positionals[0]
            sql = positionals[1]
        }

        return .success(
            SQLiteInvocation(
                mode: mode,
                includeHeader: includeHeader,
                separator: separator,
                newline: newline,
                nullValue: nullValue,
                readOnly: readOnly,
                bail: bail,
                showVersion: showVersion,
                commandScripts: commandScripts,
                database: database,
                sql: sql
            )
        )
    }

    private static func parseInlineValue(arg: String, option: String) -> String? {
        let prefix = option + "="
        if arg.hasPrefix(prefix) {
            return String(arg.dropFirst(prefix.count))
        }
        return nil
    }

    private static func decodeEscapes(_ value: String) -> String {
        var output = ""
        var iterator = value.makeIterator()

        while let char = iterator.next() {
            guard char == "\\" else {
                output.append(char)
                continue
            }

            guard let escaped = iterator.next() else {
                output.append("\\")
                break
            }

            switch escaped {
            case "n":
                output.append("\n")
            case "r":
                output.append("\r")
            case "t":
                output.append("\t")
            case "0":
                output.append("\0")
            case "\\":
                output.append("\\")
            default:
                output.append(escaped)
            }
        }

        return output
    }
}
