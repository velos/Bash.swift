import Foundation
import Testing
@testable import Bash

@Suite("Filesystem Options")
struct FilesystemOptionsTests {
    @Test("rootless session init works with InMemoryFileSystem")
    func rootlessSessionInitWorksWithInMemoryFileSystem() async throws {
        let session = try await BashSession(
            options: SessionOptions(
                filesystem: InMemoryFileSystem(),
                layout: .unixLike,
                initialEnvironment: [:],
                enableGlobbing: true,
                maxHistory: 1_000
            )
        )

        let create = await session.run("touch rootless.txt")
        #expect(create.exitCode == 0)

        let ls = await session.run("ls")
        #expect(ls.exitCode == 0)
        #expect(ls.stdoutString.contains("rootless.txt"))
    }

    @Test("filesystem-backed session exposes workspace sharing filesystem")
    func filesystemBackedSessionExposesWorkspaceSharingFilesystem() async throws {
        let session = try await BashSession(
            options: SessionOptions(
                filesystem: InMemoryFileSystem(),
                layout: .rootOnly
            )
        )

        let write = await session.run("printf hello > /note.txt")
        #expect(write.exitCode == 0)

        let content = try await session.workspace.readText("/note.txt")
        #expect(content == "hello")
    }

    @Test("workspace-backed sessions share workspace filesystem")
    func workspaceBackedSessionsShareWorkspaceFilesystem() async throws {
        let workspace = Workspace(fileSystem: InMemoryFileSystem())
        let first = try await BashSession(
            options: SessionOptions(workspace: workspace, layout: .rootOnly)
        )
        let second = try await BashSession(
            options: SessionOptions(workspace: workspace, layout: .rootOnly)
        )

        #expect(first.workspace.workspaceID == workspace.workspaceID)
        #expect(second.workspace.workspaceID == workspace.workspaceID)

        let write = await first.run("printf shared > /shared.txt")
        #expect(write.exitCode == 0)

        let read = await second.run("cat /shared.txt")
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "shared")

        let content = try await workspace.readText("/shared.txt")
        #expect(content == "shared")
    }

    @Test("pre-rooted workspace-backed session writes through to disk")
    func preRootedWorkspaceBackedSessionWritesThroughToDisk() async throws {
        let root = try TestSupport.makeTempDirectory(prefix: "BashWorkspaceBacked")
        defer { TestSupport.removeDirectory(root) }

        let workspace = Workspace(fileSystem: try LocalFileSystem(root: root))
        let session = try await BashSession(
            rootDirectory: root,
            options: SessionOptions(workspace: workspace, layout: .rootOnly)
        )

        #expect(session.workspace.workspaceID == workspace.workspaceID)

        let write = await session.run("printf disk > /disk.txt")
        #expect(write.exitCode == 0)

        let workspaceContent = try await workspace.readText("/disk.txt")
        #expect(workspaceContent == "disk")

        let diskContent = try String(
            contentsOf: root.appendingPathComponent("disk.txt"),
            encoding: .utf8
        )
        #expect(diskContent == "disk")
    }

    @Test("session options workspace and filesystem setters switch authoritative source")
    func sessionOptionsWorkspaceAndFilesystemSettersSwitchAuthoritativeSource() async throws {
        let workspaceFilesystem = InMemoryFileSystem()
        let workspace = Workspace(fileSystem: workspaceFilesystem)
        let replacementFilesystem = InMemoryFileSystem()
        var options = SessionOptions(filesystem: InMemoryFileSystem(), layout: .rootOnly)

        options.workspace = workspace
        #expect(options.workspace?.workspaceID == workspace.workspaceID)
        try await options.filesystem?.writeFile(
            path: WorkspacePath(normalizing: "/workspace-option.txt"),
            data: Data("workspace".utf8),
            append: false
        )
        #expect(await workspaceFilesystem.exists(path: WorkspacePath(normalizing: "/workspace-option.txt")))

        options.filesystem = replacementFilesystem
        #expect(options.workspace == nil)
        try await options.filesystem?.writeFile(
            path: WorkspacePath(normalizing: "/replacement-option.txt"),
            data: Data("replacement".utf8),
            append: false
        )
        #expect(await replacementFilesystem.exists(path: WorkspacePath(normalizing: "/replacement-option.txt")))
        #expect(!(await workspaceFilesystem.exists(path: WorkspacePath(normalizing: "/replacement-option.txt"))))
    }

    @Test("bash reexports native workspace filesystem types")
    func bashReexportsNativeWorkspaceFilesystemTypes() async throws {
        let workspaceFilesystem: any FileSystem = InMemoryFileSystem()
        let shellFilesystem: any FileSystem = workspaceFilesystem
        let inMemoryFilesystem = InMemoryFileSystem()
        try await inMemoryFilesystem.writeFile(
            path: WorkspacePath(normalizing: "/note.txt"),
            data: Data("native".utf8),
            append: false
        )
        await inMemoryFilesystem.reset()

        let info = FileInfo(
            path: WorkspacePath(normalizing: "/note.txt"),
            kind: .file,
            size: 4,
            permissions: POSIXPermissions(0o644),
            modificationDate: nil
        )
        let entry = DirectoryEntry(name: "note.txt", info: info)
        let error = WorkspaceError.unsupported("native check")

        #expect(await shellFilesystem.exists(path: .root))
        #expect(!(await inMemoryFilesystem.exists(path: WorkspacePath(normalizing: "/note.txt"))))
        #expect(entry.info.path == WorkspacePath(normalizing: "/note.txt"))
        #expect(error.description.contains("native check"))
    }

    @Test("overlay filesystem snapshots disk and keeps writes in memory")
    func overlayFilesystemSnapshotsDiskAndKeepsWritesInMemory() async throws {
        let root = try TestSupport.makeTempDirectory(prefix: "BashOverlay")
        defer { TestSupport.removeDirectory(root) }

        let onDisk = root.appendingPathComponent("seed.txt")
        try Data("seed".utf8).write(to: onDisk)

        let session = try await BashSession(
            options: SessionOptions(
                filesystem: try await OverlayFileSystem(root: root),
                layout: .rootOnly
            )
        )

        let read = await session.run("cat /seed.txt")
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "seed")

        let write = await session.run("printf updated > /seed.txt")
        #expect(write.exitCode == 0)

        let overlayRead = await session.run("cat /seed.txt")
        #expect(overlayRead.exitCode == 0)
        #expect(overlayRead.stdoutString == "updated")

        let diskContents = try String(contentsOf: onDisk, encoding: .utf8)
        #expect(diskContents == "seed")
    }

    @Test("mountable filesystem can combine roots and copy across mounts")
    func mountableFilesystemCanCombineRootsAndCopyAcrossMounts() async throws {
        let base = InMemoryFileSystem()
        let workspaceRoot = try TestSupport.makeTempDirectory(prefix: "BashMountWorkspace")
        defer { TestSupport.removeDirectory(workspaceRoot) }

        let docsRoot = try TestSupport.makeTempDirectory(prefix: "BashMountDocs")
        defer { TestSupport.removeDirectory(docsRoot) }
        try Data("guide".utf8).write(to: docsRoot.appendingPathComponent("guide.txt"))

        let mountable = MountedFileSystem(
            base: base,
            mounts: [
                MountedFileSystem.Mount(
                    mountPoint: "/workspace",
                    fileSystem: try await OverlayFileSystem(root: workspaceRoot)
                ),
                MountedFileSystem.Mount(
                    mountPoint: "/docs",
                    fileSystem: try await OverlayFileSystem(root: docsRoot)
                ),
            ]
        )

        let session = try await BashSession(
            options: SessionOptions(
                filesystem: mountable,
                layout: .rootOnly
            )
        )

        let top = await session.run("ls /")
        #expect(top.exitCode == 0)
        #expect(top.stdoutString.contains("workspace"))
        #expect(top.stdoutString.contains("docs"))

        let copy = await session.run("cp /docs/guide.txt /workspace/guide.txt")
        #expect(copy.exitCode == 0)

        let read = await session.run("cat /workspace/guide.txt")
        #expect(read.exitCode == 0)
        #expect(read.stdoutString == "guide")

        #expect(!FileManager.default.fileExists(atPath: workspaceRoot.appendingPathComponent("guide.txt").path))
    }

    @Test("rootless session init defaults to an in-memory filesystem")
    func rootlessSessionInitDefaultsToInMemoryFilesystem() async throws {
        let filename = "default-fs-\(UUID().uuidString).txt"
        let session = try await BashSession(
            options: SessionOptions(
                layout: .rootOnly,
                initialEnvironment: [:],
                enableGlobbing: true,
                maxHistory: 1_000
            )
        )

        let create = await session.run("printf hi > /\(filename)")
        #expect(create.exitCode == 0)

        let read = await session.run("cat /\(filename)")
        #expect(read.stdoutString == "hi")
        #expect(!FileManager.default.fileExists(atPath: "/\(filename)"))
    }

    @Test("sandbox temporary root read-write smoke")
    func sandboxTemporaryRootReadWriteSmoke() async throws {
        let filename = "bashswift-\(UUID().uuidString).txt"
        let session = try await BashSession(
            options: SessionOptions(
                filesystem: SandboxFileSystem(root: .temporary),
                layout: .rootOnly,
                initialEnvironment: [:],
                enableGlobbing: true,
                maxHistory: 1_000
            )
        )

        let create = await session.run("touch \(filename)")
        #expect(create.exitCode == 0)

        let ls = await session.run("ls \(filename)")
        #expect(ls.exitCode == 0)
        #expect(ls.stdoutString.contains(filename))

        _ = await session.run("rm \(filename)")
    }

    @Test("sandbox documents and caches roots configure")
    func sandboxDocumentsAndCachesRootsConfigure() async throws {
        let documents = try SandboxFileSystem(root: .documents)
        #expect(await documents.exists(path: "/"))

        let caches = try SandboxFileSystem(root: .caches)
        #expect(await caches.exists(path: "/"))
    }

    @Test("sandbox app group invalid id throws unsupported")
    func sandboxAppGroupInvalidIDThrowsUnsupported() {
        do {
            _ = try SandboxFileSystem(root: .appGroup("invalid.group.\(UUID().uuidString)"))
            Issue.record("expected unsupported error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("app group"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("bookmark store save-load-delete")
    func bookmarkStoreSaveLoadDelete() async throws {
        let prefix = "bashswift.tests.bookmark.\(UUID().uuidString)."
        let store = UserDefaultsBookmarkStore(keyPrefix: prefix)

        let id = "sample"
        let payload = Data([0x01, 0x02, 0x03])

        try await store.saveBookmark(payload, for: id)
        let loaded = try await store.loadBookmark(for: id)
        #expect(loaded == payload)

        try await store.deleteBookmark(for: id)
        let missing = try await store.loadBookmark(for: id)
        #expect(missing == nil)
    }

    #if os(tvOS) || os(watchOS)
    @Test("security-scoped filesystem unsupported on tvOS/watchOS")
    func securityScopedFilesystemUnsupportedOnUnsupportedPlatforms() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        do {
            _ = try SecurityScopedFileSystem(url: tempURL)
            Issue.record("expected unsupported error")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("security-scoped URLs not supported"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
    #else
    @Test("security-scoped bookmark roundtrip and read-only enforcement")
    func securityScopedBookmarkRoundtripAndReadOnlyEnforcement() async throws {
        let root = try TestSupport.makeTempDirectory(prefix: "BashSecurityScoped")
        defer { TestSupport.removeDirectory(root) }

        let readWriteFS = try SecurityScopedFileSystem(url: root, mode: .readWrite)
        try await readWriteFS.writeFile(path: "/note.txt", data: Data("hello".utf8), append: false)

        let bookmarkData = try readWriteFS.makeBookmarkData()
        #expect(!bookmarkData.isEmpty)

        let storePrefix = "bashswift.tests.security.\(UUID().uuidString)."
        let store = UserDefaultsBookmarkStore(keyPrefix: storePrefix)
        let bookmarkID = "workspace"

        try await readWriteFS.saveBookmark(id: bookmarkID, store: store)

        let restored = try await SecurityScopedFileSystem.loadBookmark(id: bookmarkID, store: store, mode: .readWrite)
        let data = try await restored.readFile(path: "/note.txt")
        #expect(String(decoding: data, as: UTF8.self) == "hello")

        let readOnly = try SecurityScopedFileSystem(bookmarkData: bookmarkData, mode: .readOnly)

        do {
            try await readOnly.writeFile(path: "/blocked.txt", data: Data("x".utf8), append: false)
            Issue.record("expected read-only rejection")
        } catch let error as WorkspaceError {
            #expect(error.description.contains("filesystem is read-only"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        try await store.deleteBookmark(for: bookmarkID)
    }
    #endif
}
