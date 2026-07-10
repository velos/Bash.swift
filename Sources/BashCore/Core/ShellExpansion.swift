import Foundation

/// Canonical `$`-expansion shared by the executor and the session so
/// special-parameter handling stays in sync across both paths.
package enum ShellExpansion {
    package static func expandVariables(in string: String, environment: [String: String]) -> String {
        var result = ""
        var index = string.startIndex

        func readIdentifier(startingAt start: String.Index) -> (String, String.Index) {
            var cursor = start
            var value = ""
            while cursor < string.endIndex {
                let character = string[cursor]
                if character.isLetter || character.isNumber || character == "_" {
                    value.append(character)
                    cursor = string.index(after: cursor)
                } else {
                    break
                }
            }
            return (value, cursor)
        }

        while index < string.endIndex {
            let character = string[index]
            guard character == "$" else {
                result.append(character)
                index = string.index(after: index)
                continue
            }

            let next = string.index(after: index)
            guard next < string.endIndex else {
                result.append("$")
                break
            }

            if string[next] == "!" {
                result += environment["!"] ?? ""
                index = string.index(after: next)
                continue
            }

            if string[next] == "?" {
                result += lastExitStatus(in: environment)
                index = string.index(after: next)
                continue
            }

            if string[next] == "@" || string[next] == "*" || string[next] == "#" {
                result += environment[String(string[next])] ?? ""
                index = string.index(after: next)
                continue
            }

            if string[next] == "(" {
                let maybeSecondOpen = string.index(after: next)
                if maybeSecondOpen < string.endIndex, string[maybeSecondOpen] == "(",
                   let capture = captureArithmeticExpansion(in: string, secondOpen: maybeSecondOpen) {
                    let evaluated = ArithmeticEvaluator.evaluate(
                        capture.expression,
                        environment: environment
                    ) ?? 0
                    result += String(evaluated)
                    index = capture.endIndex
                    continue
                }
            }

            if string[next] == "{" {
                guard let close = string[next...].firstIndex(of: "}") else {
                    result.append("$")
                    index = next
                    continue
                }

                let contentStart = string.index(after: next)
                let content = String(string[contentStart..<close])

                if let range = content.range(of: ":-") {
                    let key = String(content[..<range.lowerBound])
                    let fallback = String(content[range.upperBound...])
                    let value = lookupParameter(key, in: environment)
                    if let value, !value.isEmpty {
                        result += value
                    } else {
                        result += fallback
                    }
                } else {
                    result += lookupParameter(content, in: environment) ?? ""
                }

                index = string.index(after: close)
                continue
            }

            let (key, end) = readIdentifier(startingAt: next)
            if key.isEmpty {
                result.append("$")
                index = next
            } else {
                result += environment[key] ?? ""
                index = end
            }
        }

        return result
    }

    /// Expands a word into a single string without field splitting or
    /// globbing. Used for contexts where bash suppresses word splitting,
    /// such as assignment values and redirection targets.
    package static func expandJoined(_ word: ShellWord, environment: [String: String]) -> String {
        var output = ""
        for part in word.parts {
            switch part.quote {
            case .single:
                output += part.text
            case .none, .double:
                output += expandVariables(in: part.text, environment: environment)
            }
        }
        return output
    }

    /// Expands a word into fields, applying bash-style word splitting to the
    /// results of unquoted expansions. Literal unquoted text cannot contain
    /// whitespace (the lexer already split words on it, and escaped characters
    /// arrive as quoted parts), so any whitespace in an expanded unquoted part
    /// came from an expansion and separates fields. A word whose unquoted
    /// expansions produce nothing and that has no quoted parts yields no
    /// fields, matching bash's removal of empty unquoted expansions.
    package static func expandFields(_ word: ShellWord, environment: [String: String]) -> [String] {
        var fields: [String] = []
        var current = ""
        var currentHasQuotedContent = false

        func flushField() {
            guard currentHasQuotedContent || !current.isEmpty else { return }
            fields.append(current)
            current = ""
            currentHasQuotedContent = false
        }

        for part in word.parts {
            switch part.quote {
            case .single:
                current += part.text
                currentHasQuotedContent = true
            case .double:
                current += expandVariables(in: part.text, environment: environment)
                currentHasQuotedContent = true
            case .none:
                let expanded = expandVariables(in: part.text, environment: environment)
                for character in expanded {
                    if character == " " || character == "\t" || character == "\n" {
                        flushField()
                    } else {
                        current.append(character)
                    }
                }
            }
        }

        flushField()
        return fields
    }

    package static func lastExitStatus(in environment: [String: String]) -> String {
        environment["?"] ?? "0"
    }

    private static func lookupParameter(_ key: String, in environment: [String: String]) -> String? {
        if key == "?" {
            return lastExitStatus(in: environment)
        }
        return environment[key]
    }

    private static func captureArithmeticExpansion(
        in string: String,
        secondOpen: String.Index
    ) -> (expression: String, endIndex: String.Index)? {
        var depth = 1
        var cursor = string.index(after: secondOpen)
        let expressionStart = cursor

        while cursor < string.endIndex {
            if string[cursor] == "(" {
                let next = string.index(after: cursor)
                if next < string.endIndex, string[next] == "(" {
                    depth += 1
                    cursor = string.index(after: next)
                    continue
                }
            } else if string[cursor] == ")" {
                let next = string.index(after: cursor)
                if next < string.endIndex, string[next] == ")" {
                    depth -= 1
                    if depth == 0 {
                        let expression = String(string[expressionStart..<cursor])
                        return (
                            expression: expression,
                            endIndex: string.index(after: next)
                        )
                    }
                    cursor = string.index(after: next)
                    continue
                }
            }
            cursor = string.index(after: cursor)
        }
        return nil
    }
}
