import Foundation
import Testing

@testable import SwiftMutationTesting

@Suite("XcodeProcessLauncher")
struct XcodeProcessLauncherTests {
    private let launcher = XcodeProcessLauncher()

    @Test("Engine kill helper")
    func engineKillWindowHelper() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["SWIFT_MUTATION_ENGINE_KILL_HELPER_ROOT"],
            let phase = environment["SWIFT_MUTATION_ENGINE_KILL_HELPER_PHASE"]
        else { return }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let marker = root.appendingPathComponent("executed-" + phase)
        let ready = root.appendingPathComponent("ready-" + phase + ".json")
        let registry = root.appendingPathComponent("process-custody.json")
        let runner = ProcessRunner(
            processDidStart: { pid in
                let group = try SystemProcessIdentity.group(for: pid)
                if phase == "registered" {
                    try ProcessCustody.system(registrationURL: registry).register(group)
                }
                let payload: [String: Any] = [
                    "enginePID": Int(getpid()), "childPID": Int(pid),
                    "processGroupID": Int(group.processGroupID),
                ]
                try JSONSerialization.data(withJSONObject: payload).write(to: ready, options: .atomic)
                while true { usleep(10_000) }
            },
            onTimeout: { _ in }
        )
        _ = try await runner.launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf executed > \"$1\"", "custody-test", marker.path],
            workingDirectoryURL: root,
            timeout: 30
        )
    }

    @Test("Engine SIGKILL cannot release an unregistered child and registered state recovers")
    func engineKillWindowIsRecoverable() async throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        defer { try? FileManager.default.removeItem(at: root) }

        func runPhase(_ phase: String) throws -> (childPID: Int32, processGroupID: Int32) {
            let ready = root.appendingPathComponent("ready-" + phase + ".json")
            let process = Process()
            let buildRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build")
            let testBundle = try #require(
                FileManager.default.enumerator(at: buildRoot, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL }
                    .first(where: {
                        $0.lastPathComponent == "SwiftMutationTestingPackageTests"
                            && $0.deletingLastPathComponent().lastPathComponent == "MacOS"
                    }))
            let developerDirectory =
                ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
                ?? "/Applications/Xcode.app/Contents/Developer"
            process.executableURL = URL(fileURLWithPath: developerDirectory)
                .appendingPathComponent(
                    "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
            process.arguments = [
                "--test-bundle-path", testBundle.path, "--skip-build", "--no-parallel",
                "--filter", "engineKillWindowHelper", testBundle.path,
                "--testing-library", "swift-testing",
            ]
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["SWIFT_MUTATION_ENGINE_KILL_HELPER_ROOT"] = root.path
            environment["SWIFT_MUTATION_ENGINE_KILL_HELPER_PHASE"] = phase
            environment["LLVM_PROFILE_FILE"] = root.appendingPathComponent("helper-" + phase + "-%p.profraw").path
            process.environment = environment
            try process.run()
            for _ in 0 ..< 500 where !FileManager.default.fileExists(atPath: ready.path) {
                usleep(10_000)
            }
            let data = try Data(contentsOf: ready)
            let object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            let enginePID = Int32(try #require(object["enginePID"] as? Int))
            let childPID = Int32(try #require(object["childPID"] as? Int))
            let processGroupID = Int32(try #require(object["processGroupID"] as? Int))
            #expect(kill(enginePID, SIGKILL) == 0)
            for _ in 0 ..< 100 where process.isRunning { usleep(10_000) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            for _ in 0 ..< 100 where process.isRunning { usleep(10_000) }
            return (childPID, processGroupID)
        }

        let unregistered = try runPhase("unregistered")
        for _ in 0 ..< 500 where kill(-unregistered.processGroupID, 0) == 0 { usleep(10_000) }
        #expect(kill(-unregistered.processGroupID, 0) == -1)
        #expect(errno == ESRCH)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("executed-unregistered").path))

        let registered = try runPhase("registered")
        let registry = root.appendingPathComponent("process-custody.json")
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).count == 1)
        let custody = try ProcessCustody.system(registrationURL: registry)
        try custody.handleEngineTermination()
        #expect(custody.isQuiescent)
        #expect(kill(-registered.processGroupID, 0) == -1)
        #expect(errno == ESRCH)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("executed-registered").path))

        let equivalentMarker = root.appendingPathComponent("equivalent-next-run")
        let equivalent = ProcessRunner(processDidStart: { _ in }, onTimeout: { _ in })
        #expect(
            try await equivalent.launch(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf ready > \"$1\"", "custody-test", equivalentMarker.path],
                workingDirectoryURL: root, timeout: 10
            ) == 0)
        #expect(FileManager.default.fileExists(atPath: equivalentMarker.path))
        _ = registered.childPID
    }

    @Test("Process runner registers a child after launch and unregisters it after termination")
    func processLifecycleHooks() async throws {
        let recorder = ProcessLifecycleRecorder()
        let runner = ProcessRunner(
            processDidStart: { try recorder.start($0) },
            postTerminationCleanup: { recorder.finish($0) },
            onTimeout: { _ in }
        )

        #expect(
            try await runner.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            ) == 0)
        #expect(recorder.started.count == 1)
        #expect(recorder.finished == recorder.started)
    }

    @Test("Process runner propagates registration failures for both launch modes")
    func processRegistrationFailures() async {
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("executed")
        let runner = ProcessRunner(
            processDidStart: { _ in
                #expect(!FileManager.default.fileExists(atPath: marker.path))
                throw PreparedCacheError.unverifiableProcessIdentity
            },
            postTerminationCleanup: nil,
            onTimeout: { _ in }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await runner.launch(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf started > \(marker.path)"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
            )
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await runner.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf started > \(marker.path)"],
                    environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
                ))
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        XcodeProcessLauncher().makeRunner().onTimeout(0)
        #expect(ProcessRunner.readCapturedOutput(from: -1) == nil)
    }

    @Test("A gated child does not inherit the launch-gate descriptor after exec")
    func gatedChildClosesLaunchGateDescriptor() async throws {
        let runner = ProcessRunner(
            processDidStart: { _ in },
            postTerminationCleanup: { _ in },
            onTimeout: { _ in }
        )

        let result = try await runner.launchCapturing(
            .init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "if [ -e /dev/fd/3 ]; then printf open; else printf closed; fi",
                ],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            ))

        #expect(result.exitCode == 0)
        #expect(result.output == "closed")
    }

    @Test("Process-group setup failure aborts only the direct child and never registers a caller group")
    func processGroupSetupFailureIsContained() async {
        let recorder = ProcessLifecycleRecorder()
        let runner = ProcessRunner(
            processDidStart: { try recorder.start($0) },
            postTerminationCleanup: nil,
            onTimeout: { _ in },
            establishProcessGroup: { _ in false },
            terminateDirectProcess: { recorder.abort($0) }
        )

        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await runner.launch(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
            )
        }
        #expect(recorder.started.isEmpty)
        #expect(recorder.aborted.count == 1)

        let defaultAbort = ProcessRunner(
            onTimeout: { _ in },
            establishProcessGroup: { _ in false }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await defaultAbort.launch(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
            )
        }
    }

    @Test("Process runner fails closed for descriptor and spawn setup failures")
    func processSetupFailures() async {
        let nullFailure = ProcessRunner(onTimeout: { _ in }, openNullDescriptor: { -1 })
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await nullFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        let captureFailure = ProcessRunner(onTimeout: { _ in }, createCaptureDescriptor: { _ in -1 })
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await captureFailure.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        let descriptorRecorder = ProcessLifecycleRecorder()
        let ownedDescriptorRunner = ProcessRunner(
            onTimeout: { _ in },
            createCaptureDescriptor: { path in
                let descriptor = ProcessRunner.openPrivateCaptureFile(path)
                descriptorRecorder.abort(descriptor)
                return descriptor
            },
            configureSpawn: { _, _, output, _ in
                #expect(output == descriptorRecorder.aborted.first)
                return false
            }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await ownedDescriptorRunner.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        #expect(descriptorRecorder.aborted.count == 1)
        if let ownedDescriptor = descriptorRecorder.aborted.first {
            #expect(fcntl(ownedDescriptor, F_GETFD) == -1)
        }
        #expect(ProcessRunner.openPrivateCaptureFile("ignored", openFile: { _ in -1 }) == -1)
        #expect(ProcessRunner.openPrivateCaptureFile("ignored", openFile: { _ in Int32.max }) == -1)
        #expect(throws: PreparedCacheError.unsafeCachePath) {
            try ProcessRunner.captureDirectory(nil, canonicalizer: { _ in nil })
        }
        let insecurePath = CapturePathRecorder()
        let insecureCapture = ProcessRunner(
            onTimeout: { _ in },
            createCaptureDescriptor: { path in
                insecurePath.path = path
                return open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o644)
            }
        )
        await #expect(throws: PreparedCacheError.unsafeCachePath) {
            try await insecureCapture.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        if let path = insecurePath.path { try? FileManager.default.removeItem(atPath: path) }
        let initializeFailure = ProcessRunner(
            onTimeout: { _ in },
            initializeSpawn: { _, _ in false }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await initializeFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        let configureFailure = ProcessRunner(
            onTimeout: { _ in },
            configureSpawn: { _, _, _, _ in false }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await configureFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        let gateCreationFailure = ProcessRunner(
            processDidStart: { _ in }, onTimeout: { _ in },
            createLaunchGate: { _ in nil }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await gateCreationFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        let spawnFailure = ProcessRunner(
            onTimeout: { _ in },
            spawnProcess: { _, _, _, _, _, _ in EIO }
        )
        await #expect(throws: (any Error).self) {
            try await spawnFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        let gatedSpawnFailure = ProcessRunner(
            processDidStart: { _ in }, onTimeout: { _ in },
            spawnProcess: { _, _, _, _, _, _ in EIO }
        )
        await #expect(throws: (any Error).self) {
            try await gatedSpawnFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        #expect(waitForExit(Int32.max) == -1)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let destroyed = ProcessLifecycleRecorder()
        #expect(
            !ProcessRunner.initializeSpawnResources(
                actions: &actions,
                attributes: &attributes,
                initializeActions: { pointer in posix_spawn_file_actions_init(pointer) },
                initializeAttributes: { _ in EIO },
                destroyActions: { pointer in
                    destroyed.abort(1)
                    return posix_spawn_file_actions_destroy(pointer)
                }
            ))
        #expect(destroyed.aborted == [1])
        #expect(
            !ProcessRunner.initializeSpawnResources(
                actions: &actions, attributes: &attributes,
                initializeActions: { _ in EIO }, initializeAttributes: { _ in 0 },
                destroyActions: { _ in
                    destroyed.abort(2)
                    return 0
                }
            ))
        #expect(destroyed.aborted == [1])

        #expect(posix_spawn_file_actions_init(&actions) == 0)
        #expect(posix_spawnattr_init(&attributes) == 0)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        #expect(
            ProcessRunner.configureSpawnResources(
                actions: &actions, attributes: &attributes, output: STDERR_FILENO, directory: "/tmp"
            ))
        let inputActions = SpawnInputRecorder()
        #expect(
            !ProcessRunner.configureSpawnResources(
                actions: &actions,
                attributes: &attributes,
                output: STDERR_FILENO,
                directory: "/tmp",
                addInput: { _, descriptor, path, flags, _ in
                    inputActions.record(descriptor: descriptor, path: path, flags: flags)
                    return EIO
                }
            ))
        #expect(inputActions.descriptor == STDIN_FILENO)
        #expect(inputActions.path == "/dev/null")
        #expect(inputActions.flags == O_RDONLY)
        var flags: Int16 = 0
        #expect(posix_spawnattr_getflags(&attributes, &flags) == 0)
        #expect(flags & Int16(POSIX_SPAWN_SETPGROUP) != 0)
        #expect(flags & Int16(POSIX_SPAWN_CLOEXEC_DEFAULT) != 0)

        let gateCloses = ProcessLifecycleRecorder()
        #expect(
            ProcessRunner.makeLaunchGate(
                actions: &actions, createPipe: { _ in EIO },
                closeFile: { gateCloses.abort($0) }) == nil)
        #expect(gateCloses.aborted.isEmpty)
        #expect(
            ProcessRunner.makeLaunchGate(
                actions: &actions, setCloseOnExec: { _ in EIO }) == nil)
        func fakePipe(_ pointer: UnsafeMutablePointer<Int32>) -> Int32 {
            pointer[0] = 101
            pointer[1] = 102
            return 0
        }
        #expect(
            ProcessRunner.makeLaunchGate(
                actions: &actions, createPipe: fakePipe, setCloseOnExec: { _ in EIO },
                closeFile: { gateCloses.abort($0) }) == nil)
        var closeOnExecCalls = 0
        #expect(
            ProcessRunner.makeLaunchGate(
                actions: &actions, createPipe: fakePipe,
                setCloseOnExec: { _ in
                    closeOnExecCalls += 1
                    return closeOnExecCalls == 2 ? EIO : 0
                }, closeFile: { gateCloses.abort($0) }) == nil)
        #expect(
            ProcessRunner.makeLaunchGate(
                actions: &actions, createPipe: fakePipe, setCloseOnExec: { _ in 0 },
                addDuplicate: { _, _, _ in EIO }, closeFile: { gateCloses.abort($0) }) == nil)
        let fakeGate = ProcessRunner.makeLaunchGate(
            actions: &actions, createPipe: fakePipe, setCloseOnExec: { _ in 0 },
            addDuplicate: { _, _, _ in 0 }, closeFile: { gateCloses.abort($0) })
        #expect(fakeGate?.read == 101)
        #expect(fakeGate?.write == 102)
        #expect(gateCloses.aborted.count == 6)
        #expect(
            ProcessRunner.releaseLaunchGateDescriptor(
                1, writeByte: { _, _, _ in -1 }, closeFile: { _ in 0 }) == false)
        #expect(
            ProcessRunner.releaseLaunchGateDescriptor(
                1, writeByte: { _, _, _ in 1 }, closeFile: { _ in -1 }) == false)
        var interruptedWrites = 0
        #expect(
            ProcessRunner.releaseLaunchGateDescriptor(
                1,
                writeByte: { _, _, _ in
                    interruptedWrites += 1
                    if interruptedWrites == 1 {
                        errno = EINTR
                        return -1
                    }
                    return 1
                },
                closeFile: { _ in 0 }) == true)
        #expect(interruptedWrites == 2)

        let releaseFailure = ProcessRunner(
            processDidStart: { _ in }, onTimeout: { _ in },
            releaseLaunchGate: { descriptor in
                _ = close(descriptor)
                return false
            })
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await releaseFailure.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1)
        }

        let captureCloseCalls = ProcessLifecycleRecorder()
        var captureCloseFailure = ProcessRunner(
            onTimeout: { _ in },
            createCaptureDescriptor: { ProcessRunner.openPrivateCaptureFile($0) },
            configureSpawn: { actions, attributes, output, directory in
                ProcessRunner.configureSpawnResources(
                    actions: actions, attributes: attributes, output: output, directory: directory)
            }
        )
        captureCloseFailure.closeCaptureDescriptor = { descriptor in
            captureCloseCalls.abort(descriptor)
            _ = close(descriptor)
            return -1
        }
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await captureCloseFailure.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        #expect(captureCloseCalls.aborted.count == 1)

        let identityFailurePath = CapturePathRecorder()
        var identityFailure = ProcessRunner(
            onTimeout: { _ in },
            createCaptureDescriptor: { path in
                identityFailurePath.path = path
                return ProcessRunner.openPrivateCaptureFile(path)
            }
        )
        identityFailure.captureDescriptorIdentity = { _ in nil }
        #expect(ProcessRunner(onTimeout: { _ in }).captureDescriptorIdentity(-1) == nil)
        await #expect(throws: PreparedCacheError.unsafeCachePath) {
            try await identityFailure.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }

        var readFailure = ProcessRunner(
            onTimeout: { _ in },
            createCaptureDescriptor: { ProcessRunner.openPrivateCaptureFile($0) }
        )
        readFailure.readCaptureDescriptor = { _ in nil }
        await #expect(throws: PreparedCacheError.unsafeCachePath) {
            try await readFailure.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
    }

    @Test("waitpid retries EINTR and returns the eventual child status")
    func waitRetriesEINTR() {
        let recorder = WaitRecorder(results: [-1, 77], statuses: [0, 3 << 8], errors: [EINTR, 0])
        #expect(
            waitForExit(
                77,
                wait: { pid, status, options in
                    recorder.wait(pid: pid, status: status, options: options)
                }) == 3)
        #expect(recorder.calls == 2)
    }

    @Test("Capturing uses and scrubs the authenticated active-run root")
    func authenticatedCaptureRoot() async throws {
        let root = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        chmod(root.path, 0o700)
        let launcher = XcodeProcessLauncher(captureRoot: root)
        let result = try await launcher.launchCapturing(
            .init(
                executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["private-output"],
                environment: nil, additionalEnvironment: [:], workingDirectoryURL: root, timeout: 10
            ))
        #expect(result.output.contains("private-output"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await #expect(throws: (any Error).self) {
            try await launcher.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/missing/executable"), arguments: [],
                    environment: nil, additionalEnvironment: [:], workingDirectoryURL: root, timeout: 10
                ))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let capturePath = CapturePathRecorder()
        let swappedRunner = ProcessRunner(
            onTimeout: { _ in },
            createCaptureDescriptor: { path in
                capturePath.path = path
                return ProcessRunner.openPrivateCaptureFile(path)
            },
            captureRoot: root,
            configureSpawn: { actions, attributes, output, directory in
                guard let path = capturePath.path else { return false }
                try? FileManager.default.removeItem(atPath: path)
                guard
                    FileManager.default.createFile(
                        atPath: path,
                        contents: Data("spoofed-output".utf8),
                        attributes: [.posixPermissions: 0o600]
                    )
                else { return false }
                return ProcessRunner.configureSpawnResources(
                    actions: actions, attributes: attributes, output: output, directory: directory)
            }
        )
        let swappedResult = try await swappedRunner.launchCapturing(
            .init(
                executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["descriptor-output"],
                environment: nil, additionalEnvironment: [:], workingDirectoryURL: root, timeout: 10
            ))
        #expect(swappedResult.output.contains("descriptor-output"))
        #expect(!swappedResult.output.contains("spoofed-output"))
        let replacement = try #require(capturePath.path)
        #expect(FileManager.default.fileExists(atPath: replacement))
        #expect(try String(contentsOfFile: replacement, encoding: .utf8) == "spoofed-output")
        try FileManager.default.removeItem(atPath: replacement)

        let earlyFailurePath = CapturePathRecorder()
        let earlyFailure = ProcessRunner(
            onTimeout: { _ in },
            createCaptureDescriptor: { path in
                earlyFailurePath.path = path
                _ = FileManager.default.createFile(
                    atPath: path, contents: Data("unowned".utf8),
                    attributes: [.posixPermissions: 0o644])
                return open("/dev/null", O_RDWR | O_CLOEXEC)
            },
            captureRoot: root
        )
        await #expect(throws: PreparedCacheError.unsafeCachePath) {
            try await earlyFailure.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                    environment: nil, additionalEnvironment: [:], workingDirectoryURL: root, timeout: 10
                ))
        }
        let unownedPath = try #require(earlyFailurePath.path)
        #expect(FileManager.default.fileExists(atPath: unownedPath))
        #expect(try String(contentsOfFile: unownedPath, encoding: .utf8) == "unowned")
        try FileManager.default.removeItem(atPath: unownedPath)

        let directorySwapRoot = root.appendingPathComponent("directory-swap")
        let movedDirectory = root.appendingPathComponent("directory-swap-owned")
        let externalDirectory = root.appendingPathComponent("directory-swap-external")
        try FileManager.default.createDirectory(at: directorySwapRoot, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        chmod(directorySwapRoot.path, 0o700)
        chmod(externalDirectory.path, 0o700)
        let directorySwapPath = CapturePathRecorder()
        let directorySwapRunner = ProcessRunner(
            onTimeout: { _ in },
            createCaptureDescriptor: { path in
                directorySwapPath.path = path
                return ProcessRunner.openPrivateCaptureFile(path)
            },
            captureRoot: directorySwapRoot,
            configureSpawn: { actions, attributes, output, directory in
                guard let path = directorySwapPath.path else { return false }
                try? FileManager.default.moveItem(at: directorySwapRoot, to: movedDirectory)
                try? FileManager.default.createSymbolicLink(
                    at: directorySwapRoot, withDestinationURL: externalDirectory)
                _ = FileManager.default.createFile(
                    atPath: externalDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path,
                    contents: Data("directory-spoof".utf8), attributes: [.posixPermissions: 0o600])
                return ProcessRunner.configureSpawnResources(
                    actions: actions, attributes: attributes, output: output, directory: directory)
            }
        )
        let directorySwapResult = try await directorySwapRunner.launchCapturing(
            .init(
                executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: ["owned-directory-output"],
                environment: nil, additionalEnvironment: [:], workingDirectoryURL: root, timeout: 10
            ))
        #expect(directorySwapResult.output.contains("owned-directory-output"))
        let directoryReplacement = externalDirectory.appendingPathComponent(
            URL(fileURLWithPath: try #require(directorySwapPath.path)).lastPathComponent)
        #expect(try String(contentsOf: directoryReplacement, encoding: .utf8) == "directory-spoof")
        try FileManager.default.removeItem(at: directorySwapRoot)
        try FileManager.default.removeItem(at: movedDirectory)
        try FileManager.default.removeItem(at: externalDirectory)
    }

    @Test("Escalation is identity-checked and lifecycle-cancellable")
    func escalationLifecycle() async throws {
        let group = CustodiedProcessGroup(pid: 44, processGroupID: 44, birthIdentity: "birth")
        let signals = ProcessLifecycleRecorder()
        let escalation = ProcessEscalationController(
            identity: { _ in group }, status: { _ in .matching },
            signal: { _, signal in
                signals.abort(signal)
                return 0
            }, delay: {}
        )
        escalation.begin(pid: 44)
        for _ in 0 ..< 50 where signals.aborted.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(signals.aborted == [SIGTERM, SIGKILL])

        let cancelledSignals = ProcessLifecycleRecorder()
        let cancelled = ProcessEscalationController(
            identity: { _ in group }, status: { _ in .matching },
            signal: { _, signal in
                cancelledSignals.abort(signal)
                return 0
            },
            delay: { try await Task.sleep(for: .seconds(30)) }
        )
        cancelled.begin(pid: 44)
        for _ in 0 ..< 50 where cancelledSignals.aborted.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        cancelled.cancel(pid: 44)
        try await Task.sleep(for: .milliseconds(10))
        #expect(cancelledSignals.aborted == [SIGTERM])

        let directSignals = ProcessLifecycleRecorder()
        let wrongGroup = ProcessEscalationController(
            identity: { _ in .init(pid: 44, processGroupID: 1, birthIdentity: "caller") },
            status: { _ in .matching },
            signal: { process, signal in
                directSignals.recordSignal(process: process, signal: signal)
                return 0
            },
            delay: {}
        )
        wrongGroup.begin(pid: 44)
        for _ in 0 ..< 500 where directSignals.signaledProcesses.count < 2 {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(directSignals.signaledProcesses == [44, 44])
        #expect(directSignals.signals == [SIGTERM, SIGKILL])

        let statuses = ProcessStatusRecorder([.mismatched])
        let rejectedSignals = ProcessLifecycleRecorder()
        let rejected = ProcessEscalationController(
            identity: { _ in group }, status: { _ in statuses.next() },
            signal: { _, signal in
                rejectedSignals.abort(signal)
                return 0
            }, delay: {}
        )
        rejected.begin(pid: 44)
        rejected.begin(pid: 44)
        try await Task.sleep(for: .milliseconds(10))
        #expect(rejectedSignals.aborted.isEmpty)

        let preKillStatuses = ProcessStatusRecorder([.matching, .mismatched])
        let preKillSignals = ProcessLifecycleRecorder()
        let preKill = ProcessEscalationController(
            identity: { _ in group }, status: { _ in preKillStatuses.next() },
            signal: { _, signal in
                preKillSignals.abort(signal)
                return 0
            }, delay: {}
        )
        preKill.begin(pid: 44)
        for _ in 0 ..< 50 where preKillSignals.aborted.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(preKillSignals.aborted == [SIGTERM])
    }

    @Test("Observed build counter counts delegated attempts including failures")
    func observedBuildCounter() async {
        let base = RecordingBuildLauncher()
        let counter = ObservedBuildCountingLauncher(base: base)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await counter.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                    arguments: ["build-for-testing"], environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        #expect(counter.buildForTestingAttempts == 1)
        #expect(counter.fullBuildAttempts == 1)
        #expect(counter.incrementalBuildAttempts == 0)
        #expect(counter.fallbackBuildAttempts == 0)

        let incrementalCounter = ObservedBuildCountingLauncher(
            base: base, countBuildForTestingAsIncremental: true)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await incrementalCounter.launchCapturing(
                .init(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                    arguments: ["build-for-testing"], environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        #expect(incrementalCounter.buildForTestingAttempts == 1)
        #expect(incrementalCounter.fullBuildAttempts == 0)
        #expect(incrementalCounter.incrementalBuildAttempts == 1)

        let fallbackCounter = ObservedBuildCountingLauncher(base: base, countAsFallback: true)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await fallbackCounter.launchCapturing(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                    arguments: ["build-for-testing"], environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        #expect(fallbackCounter.buildForTestingAttempts == 1)
        #expect(fallbackCounter.fallbackBuildAttempts == 0)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await fallbackCounter.launchCapturing(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                    arguments: ["test", "-scheme", "App"], environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        #expect(fallbackCounter.fallbackBuildAttempts == 1)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await fallbackCounter.launchCapturing(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                    arguments: ["test-without-building"], environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        #expect(fallbackCounter.testWithoutBuildingRuns == 1)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await fallbackCounter.launchCapturing(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                    arguments: ["test"], environment: nil, additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
                ))
        }
        #expect(fallbackCounter.fallbackBuildAttempts == 1)

        let nonBuildCounter = ObservedBuildCountingLauncher(base: base)
        await #expect(throws: PreparedCacheError.invalidCacheState) {
            try await nonBuildCounter.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 1
            )
        }
        #expect(nonBuildCounter.buildForTestingAttempts == 0)
    }

    @Test("Custody unregister failures fail the command instead of being swallowed")
    func unregisterFailurePropagates() async {
        let runner = ProcessRunner(
            processDidStart: nil,
            postTerminationCleanup: { _ in throw PreparedCacheError.unverifiableProcessIdentity },
            onTimeout: { _ in }
        )
        await #expect(throws: PreparedCacheError.unverifiableProcessIdentity) {
            try await runner.launch(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"), timeout: 10
            )
        }
    }

    @Test("Custodial launcher persists the live process group and clears it on termination")
    func custodialLauncherRegistryLifecycle() async throws {
        let directory = CachePathGuard.canonicalURL(FileManager.default.temporaryDirectory)!.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        chmod(directory.path, 0o700)
        let registry = directory.appendingPathComponent("process-custody.json")
        let custody = try ProcessCustody.system(registrationURL: registry)
        let launcher = XcodeProcessLauncher(custody: custody)
        let release = directory.appendingPathComponent("release")

        let task = Task {
            try await launcher.launch(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while [ ! -f '\(release.path)' ]; do sleep 0.01; done"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        }
        for _ in 0 ..< 50 where !FileManager.default.fileExists(atPath: registry.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).count == 1)
        try Data().write(to: release)
        #expect(try await task.value == 0)
        #expect(try ProcessCustody.readRegisteredGroups(from: registry).isEmpty)
    }

    @Test("Given a successful executable, when launched, then returns zero exit code")
    func launchReturnsSuccessExitCode() async throws {
        let exitCode = try await launcher.launch(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            timeout: 10
        )

        #expect(exitCode == 0)
    }

    @Test("Given a failing executable, when launched, then returns non-zero exit code")
    func launchReturnsFailureExitCode() async throws {
        let exitCode = try await launcher.launch(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            timeout: 10
        )

        #expect(exitCode != 0)
    }

    @Test("Given echo command, when launched capturing, then output contains the argument")
    func launchCapturingReturnsStdout() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello world"],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("hello world"))
    }

    @Test("Given environment variables, when launched capturing, then process receives the variables")
    func launchCapturingPassesEnvironment() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $TEST_VAR"],
                environment: ["TEST_VAR": "expected_value"],
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("expected_value"))
    }

    @Test("Given stderr output, when launched capturing, then stderr is included in output")
    func launchCapturingCapturesStderr() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo error_text >&2"],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        )

        #expect(result.output.contains("error_text"))
    }

    @Test("Given long-running process and short timeout, when timeout expires, then returns minus one exit code")
    func launchTimesOutAndReturnsMinus1() async throws {
        let exitCode = try await launcher.launch(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["60"],
            workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
            timeout: 0.5
        )

        #expect(exitCode == -1)
    }

    @Test("Given non-existent executable, when launched, then throws")
    func launchThrowsForNonExistentExecutable() async {
        await #expect(throws: (any Error).self) {
            try await launcher.launch(
                executableURL: URL(fileURLWithPath: "/nonexistent/binary"),
                arguments: [],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        }
    }

    @Test("Given non-existent executable, when launchCapturing called, then throws")
    func launchCapturingThrowsForNonExistentExecutable() async {
        await #expect(throws: (any Error).self) {
            try await launcher.launchCapturing(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/nonexistent/binary"),
                    arguments: [],
                    environment: nil,
                    additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                    timeout: 10
                )
            )
        }
    }

    @Test("Given long-running process and short timeout, when launchCapturing times out, then returns minus one")
    func launchCapturingTimesOut() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                environment: nil,
                additionalEnvironment: [:],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 0.5
            )
        )

        #expect(result.exitCode == -1)
    }

    @Test("Given task is cancelled while launch running, when cancelled, then process is terminated")
    func cancelledLaunchTerminatesProcess() async throws {
        let task = Task {
            try await launcher.launch(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["60"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 60
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let exitCode = try await task.value
        #expect(exitCode == -1)
    }

    @Test("Given additionalEnvironment, when launched capturing, then process receives merged variable")
    func launchCapturingMergesAdditionalEnvironment() async throws {
        let result = try await launcher.launchCapturing(
            ProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $EXTRA_VAR"],
                environment: nil,
                additionalEnvironment: ["EXTRA_VAR": "merged_value"],
                workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                timeout: 10
            )
        )

        #expect(result.exitCode == 0)
        #expect(result.output.contains("merged_value"))
    }

    @Test("Given task is cancelled while launchCapturing running, when cancelled, then process is terminated")
    func cancelledLaunchCapturingTerminatesProcess() async throws {
        let task = Task {
            try await launcher.launchCapturing(
                ProcessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sleep"),
                    arguments: ["60"],
                    environment: nil,
                    additionalEnvironment: [:],
                    workingDirectoryURL: URL(fileURLWithPath: "/tmp"),
                    timeout: 60
                )
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let result = try await task.value
        #expect(result.exitCode == -1)
    }
}

private final class ProcessLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var started: [Int32] = []
    private(set) var finished: [Int32] = []
    private(set) var aborted: [Int32] = []
    private(set) var signaledProcesses: [Int32] = []
    private(set) var signals: [Int32] = []

    func start(_ pid: Int32) throws { lock.withLock { started.append(pid) } }
    func finish(_ pid: Int32) { lock.withLock { finished.append(pid) } }
    func abort(_ pid: Int32) { lock.withLock { aborted.append(pid) } }
    func recordSignal(process: Int32, signal: Int32) {
        lock.withLock {
            signaledProcesses.append(process)
            signals.append(signal)
        }
    }
}

private final class SpawnInputRecorder: @unchecked Sendable {
    private(set) var descriptor: Int32?
    private(set) var path: String?
    private(set) var flags: Int32?

    func record(descriptor: Int32, path: String, flags: Int32) {
        self.descriptor = descriptor
        self.path = path
        self.flags = flags
    }
}

private final class CapturePathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPath: String?
    var path: String? {
        get { lock.withLock { storedPath } }
        set { lock.withLock { storedPath = newValue } }
    }
}

private final class WaitRecorder: @unchecked Sendable {
    private var results: [Int32]
    private var statuses: [Int32]
    private var errors: [Int32]
    private(set) var calls = 0

    init(results: [Int32], statuses: [Int32], errors: [Int32]) {
        self.results = results
        self.statuses = statuses
        self.errors = errors
    }

    func wait(pid: Int32, status: UnsafeMutablePointer<Int32>?, options: Int32) -> Int32 {
        _ = options
        status?.pointee = statuses[calls]
        errno = errors[calls]
        defer { calls += 1 }
        return results[calls]
    }
}

private final class RecordingBuildLauncher: @unchecked Sendable, ProcessLaunching {
    func launch(
        executableURL: URL, arguments: [String], workingDirectoryURL: URL, timeout: Double
    ) async throws -> Int32 {
        throw PreparedCacheError.invalidCacheState
    }

    func launchCapturing(_ request: ProcessRequest) async throws -> (exitCode: Int32, output: String) {
        throw PreparedCacheError.invalidCacheState
    }
}

private final class ProcessStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [ProcessIdentityStatus]

    init(_ statuses: [ProcessIdentityStatus]) { self.statuses = statuses }

    func next() -> ProcessIdentityStatus {
        lock.withLock { statuses.isEmpty ? .mismatched : statuses.removeFirst() }
    }
}
