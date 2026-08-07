import Foundation
import Testing
@testable import Bash

@Suite("Model Shell Transcript Scenarios")
struct ModelShellTranscriptScenariosTests {
    @Test("OpenAI repository inventory pipeline")
    func openAIRepositoryInventoryPipeline() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p Sources/Nested")
        _ = await session.run("touch Sources/z.swift Sources/a.swift Sources/Nested/m.swift")

        // A representative Codex shape: enumerate files, make the result
        // deterministic, and bound the output before reading it.
        let result = await session.run("rg --files Sources | sort | sed -n '1,2p'")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "Sources/Nested/m.swift\nSources/a.swift\n")
    }

    @Test("Claude chained inspection with a quiet optional read")
    func claudeChainedInspectionWithQuietOptionalRead() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p Sources")
        _ = await session.run("touch Sources/App.swift")
        _ = await session.run("printf 'first\\nsecond\\nthird\\n' > README.md")

        // Claude frequently combines a directory listing with an optional
        // file read whose diagnostics are discarded and output is bounded.
        let result = await session.run("ls -la Sources && cat README.md 2>/dev/null | head -2")
        #expect(result.exitCode == 0)
        #expect(result.stdoutString.contains("App.swift"))
        #expect(result.stdoutString.hasSuffix("first\nsecond\n"))
        #expect(result.stderrString.isEmpty)
    }

    @Test("Claude find exclusion pipeline")
    func claudeFindExclusionPipeline() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("mkdir -p Sources vendor")
        _ = await session.run("touch Sources/App.swift vendor/Generated.swift")

        let result = await session.run(
            "find . -type f -not -path '*/vendor/*' | sort | head -10"
        )
        #expect(result.exitCode == 0)
        #expect(result.stdoutString.contains("/home/user/Sources/App.swift"))
        #expect(!result.stdoutString.contains("Generated.swift"))
    }
}
