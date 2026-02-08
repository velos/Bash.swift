import Foundation

enum SQLiteFormatters {
    static func render(resultSets: [SQLiteResultSet], invocation: SQLiteInvocation) -> String {
        var output = ""
        for resultSet in resultSets {
            output += render(resultSet: resultSet, invocation: invocation)
        }
        return output
    }

    private static func render(resultSet: SQLiteResultSet, invocation: SQLiteInvocation) -> String {
        switch invocation.mode {
        case .list:
            return renderList(resultSet: resultSet, invocation: invocation)
        case .csv:
            return renderCSV(resultSet: resultSet, invocation: invocation)
        case .json:
            return renderJSON(resultSet: resultSet)
        case .line:
            return renderLine(resultSet: resultSet, invocation: invocation)
        case .column:
            return renderColumn(resultSet: resultSet, invocation: invocation)
        case .table:
            return renderTable(resultSet: resultSet, invocation: invocation)
        case .markdown:
            return renderMarkdown(resultSet: resultSet, invocation: invocation)
        }
    }

    private static func renderList(resultSet: SQLiteResultSet, invocation: SQLiteInvocation) -> String {
        var lines: [String] = []
        if invocation.includeHeader {
            lines.append(resultSet.columns.joined(separator: invocation.separator))
        }

        for row in resultSet.rows {
            let rendered = row
                .map { renderScalar($0, nullValue: invocation.nullValue) }
                .joined(separator: invocation.separator)
            lines.append(rendered)
        }

        guard !lines.isEmpty else {
            return ""
        }

        return lines.joined(separator: invocation.newline) + invocation.newline
    }

    private static func renderCSV(resultSet: SQLiteResultSet, invocation: SQLiteInvocation) -> String {
        let delimiter = invocation.separator
        var lines: [String] = []

        if invocation.includeHeader {
            lines.append(resultSet.columns.map { csvField($0, delimiter: delimiter) }.joined(separator: delimiter))
        }

        for row in resultSet.rows {
            let rendered = row
                .map { csvField(renderScalar($0, nullValue: invocation.nullValue), delimiter: delimiter) }
                .joined(separator: delimiter)
            lines.append(rendered)
        }

        guard !lines.isEmpty else {
            return ""
        }

        return lines.joined(separator: invocation.newline) + invocation.newline
    }

    private static func renderJSON(resultSet: SQLiteResultSet) -> String {
        var objects: [[String: Any]] = []
        objects.reserveCapacity(resultSet.rows.count)

        for row in resultSet.rows {
            var object: [String: Any] = [:]
            for (index, value) in row.enumerated() {
                guard index < resultSet.columns.count else { continue }
                object[resultSet.columns[index]] = jsonValue(from: value)
            }
            objects.append(object)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]) else {
            return "[]\n"
        }
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func renderLine(resultSet: SQLiteResultSet, invocation: SQLiteInvocation) -> String {
        var lines: [String] = []

        for (rowIndex, row) in resultSet.rows.enumerated() {
            for (columnIndex, column) in resultSet.columns.enumerated() {
                let value = columnIndex < row.count ? renderScalar(row[columnIndex], nullValue: invocation.nullValue) : invocation.nullValue
                lines.append("\(column) = \(value)")
            }
            if rowIndex != resultSet.rows.count - 1 {
                lines.append("")
            }
        }

        guard !lines.isEmpty else {
            return ""
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderColumn(resultSet: SQLiteResultSet, invocation: SQLiteInvocation) -> String {
        var tableRows: [[String]] = resultSet.rows.map { row in
            resultSet.columns.enumerated().map { index, _ in
                index < row.count ? renderScalar(row[index], nullValue: invocation.nullValue) : invocation.nullValue
            }
        }

        var widths = tableRows.reduce(into: Array(repeating: 0, count: resultSet.columns.count)) { partial, row in
            for (index, value) in row.enumerated() {
                partial[index] = max(partial[index], value.count)
            }
        }

        if invocation.includeHeader {
            for (index, header) in resultSet.columns.enumerated() {
                widths[index] = max(widths[index], header.count)
            }
            tableRows.insert(resultSet.columns, at: 0)
        }

        guard !tableRows.isEmpty else {
            return ""
        }

        var outputLines: [String] = []
        for (index, row) in tableRows.enumerated() {
            outputLines.append(padRow(row, widths: widths, separator: "  "))
            if invocation.includeHeader, index == 0 {
                let divider = widths.map { String(repeating: "-", count: max($0, 1)) }.joined(separator: "  ")
                outputLines.append(divider)
            }
        }

        return outputLines.joined(separator: "\n") + "\n"
    }

    private static func renderTable(resultSet: SQLiteResultSet, invocation: SQLiteInvocation) -> String {
        let bodyRows = resultSet.rows.map { row in
            resultSet.columns.enumerated().map { index, _ in
                index < row.count ? renderScalar(row[index], nullValue: invocation.nullValue) : invocation.nullValue
            }
        }

        var widths = Array(repeating: 0, count: resultSet.columns.count)
        if invocation.includeHeader {
            for (index, header) in resultSet.columns.enumerated() {
                widths[index] = max(widths[index], header.count)
            }
        }
        for row in bodyRows {
            for (index, value) in row.enumerated() {
                widths[index] = max(widths[index], value.count)
            }
        }

        let hasHeader = invocation.includeHeader
        guard hasHeader || !bodyRows.isEmpty else {
            return ""
        }

        let border = "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
        var lines: [String] = [border]

        if hasHeader {
            lines.append("| " + padRow(resultSet.columns, widths: widths, separator: " | ") + " |")
            lines.append(border)
        }

        for row in bodyRows {
            lines.append("| " + padRow(row, widths: widths, separator: " | ") + " |")
        }

        lines.append(border)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderMarkdown(resultSet: SQLiteResultSet, invocation: SQLiteInvocation) -> String {
        let headers = resultSet.columns.map(escapeMarkdown)
        guard !headers.isEmpty else {
            return ""
        }

        var lines: [String] = []
        lines.append("| " + headers.joined(separator: " | ") + " |")
        lines.append("| " + Array(repeating: "---", count: headers.count).joined(separator: " | ") + " |")

        for row in resultSet.rows {
            let rendered = resultSet.columns.enumerated().map { index, _ in
                let value = index < row.count ? renderScalar(row[index], nullValue: invocation.nullValue) : invocation.nullValue
                return escapeMarkdown(value)
            }
            lines.append("| " + rendered.joined(separator: " | ") + " |")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderScalar(_ value: SQLiteCell, nullValue: String) -> String {
        switch value {
        case .null:
            return nullValue
        case let .integer(number):
            return String(number)
        case let .float(number):
            return String(number)
        case let .text(text):
            return text
        case let .blob(data):
            return "x'\(data.map { String(format: "%02X", $0) }.joined())'"
        }
    }

    private static func jsonValue(from cell: SQLiteCell) -> Any {
        switch cell {
        case .null:
            return NSNull()
        case let .integer(number):
            return number
        case let .float(number):
            return number
        case let .text(text):
            return text
        case let .blob(data):
            return data.base64EncodedString()
        }
    }

    private static func csvField(_ value: String, delimiter: String) -> String {
        let needsQuotes = value.contains("\"") || value.contains("\n") || value.contains("\r") || value.contains(delimiter)
        guard needsQuotes else {
            return value
        }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func padRow(_ row: [String], widths: [Int], separator: String) -> String {
        row.enumerated().map { index, value in
            value.padding(toLength: widths[index], withPad: " ", startingAt: 0)
        }.joined(separator: separator)
    }

    private static func escapeMarkdown(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }
}
