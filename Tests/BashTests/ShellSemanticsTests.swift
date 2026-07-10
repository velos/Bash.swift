import Foundation
import Testing
@testable import Bash

@Suite("Shell Semantics")
struct ShellSemanticsTests {
    @Test("arithmetic overflow wraps instead of crashing")
    func arithmeticOverflowWraps() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let addOverflow = await session.run("echo $(( 9223372036854775807 + 1 ))")
        #expect(addOverflow.exitCode == 0)
        #expect(TestSupport.text(addOverflow.stdout) == "-9223372036854775808\n")

        let subtractOverflow = await session.run("echo $(( 0 - (1 << 63) ))")
        #expect(TestSupport.text(subtractOverflow.stdout) == "-9223372036854775808\n")

        let multiplyOverflow = await session.run("echo $(( 9223372036854775807 * 2 ))")
        #expect(TestSupport.text(multiplyOverflow.stdout) == "-2\n")

        let divideMinByMinusOne = await session.run("echo $(( (1 << 63) / -1 ))")
        #expect(TestSupport.text(divideMinByMinusOne.stdout) == "-9223372036854775808\n")

        let remainderMinByMinusOne = await session.run("echo $(( (1 << 63) % -1 ))")
        #expect(TestSupport.text(remainderMinByMinusOne.stdout) == "0\n")

        let negateMin = await session.run("echo $(( - (1 << 63) ))")
        #expect(TestSupport.text(negateMin.stdout) == "-9223372036854775808\n")

        let maskedShift = await session.run("echo $(( 1 << 64 ))")
        #expect(TestSupport.text(maskedShift.stdout) == "1\n")

        let powerOverflow = await session.run("echo $(( 2 ** 64 ))")
        #expect(powerOverflow.exitCode == 0)
        #expect(TestSupport.text(powerOverflow.stdout) == "0\n")
    }

    @Test("arithmetic accepts dollar-prefixed parameters")
    func arithmeticDollarParameters() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("x=5")
        let dollarVariable = await session.run("echo $(( $x * 2 ))")
        #expect(TestSupport.text(dollarVariable.stdout) == "10\n")

        let bareVariable = await session.run("echo $(( x + 1 ))")
        #expect(TestSupport.text(bareVariable.stdout) == "6\n")

        _ = await session.run("false")
        let lastStatus = await session.run("echo $(( $? + 1 ))")
        #expect(TestSupport.text(lastStatus.stdout) == "2\n")
    }

    @Test("$? expands to the last exit status")
    func lastExitStatusExpansion() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let initial = await session.run("echo $?")
        #expect(TestSupport.text(initial.stdout) == "0\n")

        let afterFalse = await session.run("false; echo $?")
        #expect(TestSupport.text(afterFalse.stdout) == "1\n")

        let afterTrue = await session.run("true; echo $?")
        #expect(TestSupport.text(afterTrue.stdout) == "0\n")

        let afterMissingCommand = await session.run("this-command-does-not-exist; echo $?")
        #expect(TestSupport.text(afterMissingCommand.stdout) == "127\n")

        let braced = await session.run("false; echo ${?}")
        #expect(TestSupport.text(braced.stdout) == "1\n")

        let acrossRuns = await session.run("false")
        #expect(acrossRuns.exitCode == 1)
        let nextRun = await session.run("echo $?")
        #expect(TestSupport.text(nextRun.stdout) == "1\n")

        let pipelineStatus = await session.run("false | true; echo $?")
        #expect(TestSupport.text(pipelineStatus.stdout) == "0\n")

        let skippedSegment = await session.run("false && echo skipped; echo $?")
        #expect(TestSupport.text(skippedSegment.stdout) == "1\n")

        _ = await session.run("false")
        let condition = await session.run("if [ $? -ne 0 ]; then echo failed; fi")
        #expect(TestSupport.text(condition.stdout) == "failed\n")
    }

    @Test("inline environment assignments apply to a single command")
    func inlineEnvironmentAssignments() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        let inline = await session.run("INLINE_VAR=inline-value printenv INLINE_VAR")
        #expect(inline.exitCode == 0)
        #expect(TestSupport.text(inline.stdout) == "inline-value\n")

        let afterInline = await session.run("printenv INLINE_VAR")
        #expect(afterInline.exitCode != 0)
        #expect(TestSupport.text(afterInline.stdout).isEmpty)

        let multiple = await session.run("A_VAR=1 B_VAR=2 printenv B_VAR")
        #expect(TestSupport.text(multiple.stdout) == "2\n")

        _ = await session.run("KEEP_VAR=original")
        let overlay = await session.run("KEEP_VAR=temporary printenv KEEP_VAR")
        #expect(TestSupport.text(overlay.stdout) == "temporary\n")
        let restored = await session.run("printenv KEEP_VAR")
        #expect(TestSupport.text(restored.stdout) == "original\n")

        _ = await session.run("M_ONE=1 M_TWO=2")
        let persisted = await session.run("printenv M_ONE M_TWO")
        #expect(TestSupport.text(persisted.stdout) == "1\n2\n")

        _ = await session.run("EXP_VAR=before")
        let expansionOrder = await session.run("EXP_VAR=after echo $EXP_VAR")
        #expect(TestSupport.text(expansionOrder.stdout) == "before\n")

        let missingCommand = await session.run("INLINE_ONLY=x this-command-does-not-exist")
        #expect(missingCommand.exitCode == 127)
        let notPersisted = await session.run("printenv INLINE_ONLY")
        #expect(notPersisted.exitCode != 0)
    }

    @Test("unquoted expansions are word split")
    func unquotedExpansionsAreWordSplit() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("SPLIT_VAR=\"a   b c\"")

        let unquoted = await session.run("echo $SPLIT_VAR")
        #expect(TestSupport.text(unquoted.stdout) == "a b c\n")

        let quoted = await session.run("echo \"$SPLIT_VAR\"")
        #expect(TestSupport.text(quoted.stdout) == "a   b c\n")

        let fields = await session.run("printf '[%s][%s][%s]' $SPLIT_VAR")
        #expect(TestSupport.text(fields.stdout) == "[a][b][c]")

        let loop = await session.run("for token in $SPLIT_VAR; do echo \"<$token>\"; done")
        #expect(TestSupport.text(loop.stdout) == "<a>\n<b>\n<c>\n")

        let emptyRemoved = await session.run("echo start $UNSET_SPLIT_VAR end")
        #expect(TestSupport.text(emptyRemoved.stdout) == "start end\n")

        let escapedSpace = await session.run("printf '[%s][%s]' a\\ b")
        #expect(TestSupport.text(escapedSpace.stdout) == "[a b][]")

        _ = await session.run("MID_VAR=\"1 2\"")
        let attached = await session.run("printf '[%s][%s]' x$MID_VAR/y")
        #expect(TestSupport.text(attached.stdout) == "[x1][2/y]")
    }

    @Test("redirection ordering matches bash file-descriptor semantics")
    func redirectionOrderingMatchesBash() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        // `> file 2>&1` routes both streams into the file.
        let combined = await session.run("cat missing-file.txt > combined.log 2>&1")
        #expect(combined.exitCode != 0)
        #expect(TestSupport.text(combined.stdout).isEmpty)
        #expect(TestSupport.text(combined.stderr).isEmpty)
        let combinedLog = await session.run("cat combined.log")
        #expect(TestSupport.text(combinedLog.stdout).contains("missing-file.txt"))

        // `2>&1 > file` duplicates stderr to the caller's stdout first, then
        // sends stdout to the file.
        let ordered = await session.run("cat missing-other.txt 2>&1 > stdout-only.log")
        #expect(TestSupport.text(ordered.stdout).contains("missing-other.txt"))
        #expect(TestSupport.text(ordered.stderr).isEmpty)
        let stdoutOnlyLog = await session.run("cat stdout-only.log")
        #expect(TestSupport.text(stdoutOnlyLog.stdout).isEmpty)

        // A bare `2>&1` still merges stderr into stdout.
        let merged = await session.run("cat missing-merged.txt 2>&1")
        #expect(TestSupport.text(merged.stdout).contains("missing-merged.txt"))
        #expect(TestSupport.text(merged.stderr).isEmpty)

        // Separate targets are unaffected.
        _ = await session.run("echo out-line > out.log 2> err.log")
        let outLog = await session.run("cat out.log")
        #expect(TestSupport.text(outLog.stdout) == "out-line\n")
        let errLog = await session.run("cat err.log")
        #expect(errLog.exitCode == 0)
        #expect(TestSupport.text(errLog.stdout).isEmpty)
    }

    @Test("$? expands inside heredocs")
    func lastExitStatusInHeredocs() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        _ = await session.run("false")
        let heredoc = await session.run("cat << EOF\nstatus=$?\nEOF")
        #expect(TestSupport.text(heredoc.stdout) == "status=1\n")
    }
}
