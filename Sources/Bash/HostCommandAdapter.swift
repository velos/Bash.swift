import Foundation
import BashCore

/// Metadata for an application-provided command that may cross the Bash.swift
/// jail and execute work in the host application.
public struct HostCommandDescriptor: Sendable, Hashable {
    public var name: String
    public var aliases: [String]
    public var overview: String
    public var forwardedEnvironmentKeys: [String]

    public init(
        name: String,
        aliases: [String] = [],
        overview: String,
        forwardedEnvironmentKeys: [String] = []
    ) {
        self.name = name
        self.aliases = aliases
        self.overview = overview
        self.forwardedEnvironmentKeys = forwardedEnvironmentKeys
    }
}

/// The shell-visible input passed to an application-provided host executor.
/// `virtualCurrentDirectory` is a path in the configured Bash.swift workspace,
/// not a host filesystem path.
public struct HostCommandRequest: Sendable {
    public var commandName: String
    public var arguments: [String]
    public var stdin: Data
    public var virtualCurrentDirectory: String
    public var environment: [String: String]

    public init(
        commandName: String,
        arguments: [String],
        stdin: Data,
        virtualCurrentDirectory: String,
        environment: [String: String]
    ) {
        self.commandName = commandName
        self.arguments = arguments
        self.stdin = stdin
        self.virtualCurrentDirectory = virtualCurrentDirectory
        self.environment = environment
    }
}

public enum HostCommandAuthorization: Sendable, Equatable {
    case allow
    case deny(message: String? = nil)
}

public enum HostCommandAdapterError: Error, Sendable, Equatable, LocalizedError {
    case invalidCommandName(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidCommandName(name):
            "invalid host command name '\(name)'"
        }
    }
}

public extension BashSession {
    /// Registers an opt-in bridge to application-controlled host execution.
    ///
    /// Bash.swift never creates a host process. The authorization closure is
    /// called for every invocation, and the executor runs only after it returns
    /// `.allow`. Applications remain responsible for constructing a process
    /// with an argument vector instead of interpolating arguments into a shell.
    func registerHostCommand(
        _ descriptor: HostCommandDescriptor,
        authorize: @escaping @Sendable (HostCommandRequest) async -> HostCommandAuthorization,
        execute: @escaping @Sendable (HostCommandRequest) async throws -> CommandResult
    ) async throws {
        for commandName in [descriptor.name] + descriptor.aliases {
            guard Self.isValidHostCommandName(commandName) else {
                throw HostCommandAdapterError.invalidCommandName(commandName)
            }
        }

        let forwardedKeys = Set(descriptor.forwardedEnvironmentKeys)
        let command = AnyBuiltinCommand(
            name: descriptor.name,
            aliases: descriptor.aliases,
            overview: descriptor.overview
        ) { context, arguments in
            let forwardedEnvironment = context.environment.filter { forwardedKeys.contains($0.key) }
            let request = HostCommandRequest(
                commandName: context.commandName,
                arguments: arguments,
                stdin: context.stdin,
                virtualCurrentDirectory: context.currentDirectory,
                environment: forwardedEnvironment
            )

            switch await authorize(request) {
            case .allow:
                do {
                    let result = try await execute(request)
                    context.stdout.append(result.stdout)
                    context.stderr.append(result.stderr)
                    return result.exitCode
                } catch {
                    context.writeStderr("\(context.commandName): host execution failed: \(error.localizedDescription)\n")
                    return 126
                }
            case let .deny(message):
                let detail = message.map { ": \($0)" } ?? ""
                context.writeStderr("\(context.commandName): host execution denied\(detail)\n")
                return 126
            }
        }

        await register(command)
    }

    private static func isValidHostCommandName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/")
            && !name.contains(where: { $0.isWhitespace || $0.isNewline })
    }
}
