import Foundation
@_exported import Workspace

// MARK: - Workspace 0.6 compatibility
//
// Workspace 0.6 made several `WorkspacePath` conveniences internal. Shell code normalizes and
// inspects untrusted path strings on nearly every command, so they are restored here with the same
// semantics. If Workspace re-exposes them, this extension can be deleted.
public extension WorkspacePath {
    /// Non-throwing normalization for shell-derived paths. The only invalid input is a NUL byte,
    /// which is stripped so shell code can normalize without threading errors through every call site.
    init(normalizing path: some StringProtocol, relativeTo currentDirectory: WorkspacePath = .root) {
        let sanitized = String(path).replacingOccurrences(of: "\u{0}", with: "")
        self = (try? WorkspacePath(sanitized, relativeTo: currentDirectory)) ?? currentDirectory
    }

    /// The final path component, or `/` for the root path.
    var basename: String {
        name
    }

    /// The parent directory of the path. The root is its own parent.
    var dirname: WorkspacePath {
        parent
    }

    /// Splits an absolute path string into components, excluding the leading `/`.
    static func splitComponents(_ absolutePath: some StringProtocol) -> [String] {
        String(absolutePath).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Returns the last component of `path`, or `/` for the root path.
    static func basename(_ path: some StringProtocol) -> String {
        let string = String(path)
        let normalized = string == "/" ? "/" : string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized == "/" || normalized.isEmpty {
            return "/"
        }
        return normalized.split(separator: "/").last.map(String.init) ?? "/"
    }

    /// Returns the parent directory of `path`.
    static func dirname(_ path: some StringProtocol) -> WorkspacePath {
        WorkspacePath(normalizing: path).parent
    }

    /// Returns `true` when the token contains glob metacharacters.
    static func containsGlob(_ token: some StringProtocol) -> Bool {
        let string = String(token)
        return string.contains("*") || string.contains("?") || string.contains("[")
    }

    /// Converts a shell-style glob pattern into an anchored regular expression pattern.
    ///
    /// `*` and `?` match within a single path component (they never cross `/`), `**` matches any
    /// characters including `/`, and character classes support shell-style negation (`[!abc]`).
    static func globToRegex(_ pattern: some StringProtocol) -> String {
        let pattern = String(pattern)
        var regex = "^"
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let char = pattern[index]
            if char == "*" {
                let nextIndex = pattern.index(after: index)
                if nextIndex < pattern.endIndex, pattern[nextIndex] == "*" {
                    let afterDoubleStar = pattern.index(after: nextIndex)
                    if afterDoubleStar < pattern.endIndex, pattern[afterDoubleStar] == "/" {
                        regex += "(?:.*/)?"
                        index = afterDoubleStar
                    } else {
                        regex += ".*"
                        index = nextIndex
                    }
                } else {
                    regex += "[^/]*"
                }
            } else if char == "?" {
                regex += "[^/]"
            } else if char == "[" {
                if let closeIndex = pattern[index...].firstIndex(of: "]"),
                   closeIndex > pattern.index(after: index)
                {
                    let range = pattern.index(after: index)..<closeIndex
                    var body = String(pattern[range])
                    if body.hasPrefix("!") {
                        body = "^" + body.dropFirst()
                    }
                    regex += "[" + body + "]"
                    index = closeIndex
                } else {
                    regex += "\\["
                }
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
            }
            index = pattern.index(after: index)
        }

        regex += "$"
        return regex
    }
}

package func shellPath(
    _ path: String,
    currentDirectory: String = "/"
) throws -> WorkspacePath {
    try WorkspacePath(
        path,
        relativeTo: WorkspacePath(normalizing: currentDirectory)
    )
}

package func validateWorkspacePath(_ path: String) throws {
    _ = try WorkspacePath(path)
}

package func normalizeWorkspacePath(
    path: String,
    currentDirectory: String
) -> String {
    WorkspacePath(
        normalizing: path,
        relativeTo: WorkspacePath(normalizing: currentDirectory)
    ).string
}

public extension FileInfo {
    var isDirectory: Bool {
        kind == .directory
    }

    var isSymbolicLink: Bool {
        kind == .symlink
    }

    var permissionBits: Int {
        Int(permissions.rawValue)
    }
}

public extension POSIXPermissions {
    var intValue: Int {
        Int(rawValue)
    }
}
