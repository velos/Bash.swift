import Foundation

/// Routes a command's buffered stdout/stderr through its redirections,
/// emulating bash's file-descriptor duplication semantics for buffered
/// streams. Redirections are applied in order to a sink table first, so
/// `cmd > file 2>&1` sends both streams to the file while
/// `cmd 2>&1 > file` sends stderr to the caller's stdout and stdout to
/// the file, matching bash.
package enum RedirectionPlan {
    package enum Sink: Equatable, Sendable {
        case callerStdout
        case callerStderr
        case file(path: String, append: Bool)
    }

    package struct FileWrite: Sendable {
        package var path: String
        package var append: Bool
        package var data: Data

        package init(path: String, append: Bool, data: Data) {
            self.path = path
            self.append = append
            self.data = data
        }
    }

    package struct Routed: Sendable {
        package var stdout: Data
        package var stderr: Data
        package var writes: [FileWrite]

        package init(stdout: Data = Data(), stderr: Data = Data(), writes: [FileWrite] = []) {
            self.stdout = stdout
            self.stderr = stderr
            self.writes = writes
        }
    }

    /// `resolvedTargets` carries the expanded target path for each entry of
    /// `redirections`, aligned by index; entries for redirections without a
    /// path target are nil.
    package static func route(
        redirections: [Redirection],
        resolvedTargets: [String?],
        stdout: Data,
        stderr: Data
    ) -> Routed {
        var stdoutSink = Sink.callerStdout
        var stderrSink = Sink.callerStderr

        for (index, redirection) in redirections.enumerated() {
            let target = index < resolvedTargets.count ? resolvedTargets[index] : nil
            switch redirection.type {
            case .stdin:
                continue
            case .stdoutTruncate, .stdoutAppend:
                guard let target else { continue }
                stdoutSink = .file(path: target, append: redirection.type == .stdoutAppend)
            case .stderrTruncate, .stderrAppend:
                guard let target else { continue }
                stderrSink = .file(path: target, append: redirection.type == .stderrAppend)
            case .stderrToStdout:
                stderrSink = stdoutSink
            case .stdoutAndErrTruncate, .stdoutAndErrAppend:
                guard let target else { continue }
                let append = redirection.type == .stdoutAndErrAppend
                stdoutSink = .file(path: target, append: append)
                stderrSink = .file(path: target, append: append)
            }
        }

        var routed = Routed()

        func route(_ data: Data, to sink: Sink) {
            switch sink {
            case .callerStdout:
                routed.stdout.append(data)
            case .callerStderr:
                routed.stderr.append(data)
            case let .file(path, append):
                if let existing = routed.writes.firstIndex(where: { $0.path == path }) {
                    routed.writes[existing].data.append(data)
                } else {
                    routed.writes.append(FileWrite(path: path, append: append, data: data))
                }
            }
        }

        route(stdout, to: stdoutSink)
        route(stderr, to: stderrSink)
        return routed
    }
}
