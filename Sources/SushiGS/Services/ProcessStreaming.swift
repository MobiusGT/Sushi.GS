import Foundation
import os

/// Thread-safe subprocess runner with line-by-line streaming and clean cancellation.
/// Strictly `nonisolated` so background pipes never touch the MainActor unexpectedly.
nonisolated struct ProcessExecutionResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

nonisolated final class ActiveProcessHandle: Sendable {
    private let lock = OSAllocatedUnfairLock<Process?>(initialState: nil)

    func attach(_ process: Process) {
        lock.withLock { $0 = process }
    }

    func clear() {
        lock.withLock { $0 = nil }
    }

    func terminate() {
        let proc = lock.withLock { $0 }
        guard let proc, proc.isRunning else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        // Allow worker.py up to 4 seconds to terminate child process groups, delete temp/partial
        // files, and emit its cleanup NDJSON log event before escalating to SIGKILL.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4.0) { @Sendable in
            let current = self.lock.withLock { $0 }
            if let current, current.processIdentifier == pid, current.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }
}

nonisolated enum ProcessRunner {
    static func runCapture(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        currentDirectory: URL? = nil
    ) async throws -> ProcessExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let currentDirectory {
                    process.currentDirectoryURL = currentDirectory
                }
                if let environment {
                    process.environment = environment
                }
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                var inPipe: Pipe?
                if stdinData != nil {
                    let p = Pipe()
                    process.standardInput = p
                    inPipe = p
                }

                do {
                    try process.run()
                    if let stdinData, let inPipe {
                        inPipe.fileHandleForWriting.write(stdinData)
                        try? inPipe.fileHandleForWriting.close()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(
                        returning: ProcessExecutionResult(
                            exitCode: process.terminationStatus,
                            stdout: String(decoding: outData, as: UTF8.self),
                            stderr: String(decoding: errData, as: UTF8.self)
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func runStreaming(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        handle: ActiveProcessHandle? = nil,
        mergeStderrIntoStdout: Bool = false,
        onLine: @escaping @Sendable (String) -> Void,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { @Sendable in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let environment {
                    process.environment = environment
                }

                let outPipe = Pipe()
                let errPipe = mergeStderrIntoStdout ? outPipe : Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                var inPipe: Pipe?
                if stdinData != nil {
                    let p = Pipe()
                    process.standardInput = p
                    inPipe = p
                }

                handle?.attach(process)

                let outBuffer = OSAllocatedUnfairLock<Data>(initialState: Data())
                let errBuffer = OSAllocatedUnfairLock<Data>(initialState: Data())

                outPipe.fileHandleForReading.readabilityHandler = { @Sendable fh in
                    let chunk = fh.availableData
                    if chunk.isEmpty {
                        fh.readabilityHandler = nil
                        return
                    }
                    outBuffer.withLock { $0.append(chunk) }
                    Self.drainLines(from: outBuffer, callback: onLine)
                }

                if !mergeStderrIntoStdout, let onStderrLine {
                    errPipe.fileHandleForReading.readabilityHandler = { @Sendable fh in
                        let chunk = fh.availableData
                        if chunk.isEmpty {
                            fh.readabilityHandler = nil
                            return
                        }
                        errBuffer.withLock { $0.append(chunk) }
                        Self.drainLines(from: errBuffer, callback: onStderrLine)
                    }
                }

                do {
                    try process.run()
                    if let stdinData, let inPipe {
                        inPipe.fileHandleForWriting.write(stdinData)
                        try? inPipe.fileHandleForWriting.close()
                    }
                    process.waitUntilExit()

                    outPipe.fileHandleForReading.readabilityHandler = nil
                    let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingOut.isEmpty {
                        outBuffer.withLock { $0.append(remainingOut) }
                    }
                    Self.drainLines(from: outBuffer, callback: onLine, flushAll: true)

                    if !mergeStderrIntoStdout, let onStderrLine {
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                        if !remainingErr.isEmpty {
                            errBuffer.withLock { $0.append(remainingErr) }
                        }
                        Self.drainLines(from: errBuffer, callback: onStderrLine, flushAll: true)
                    }

                    handle?.clear()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    handle?.clear()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func drainLines(
        from buffer: OSAllocatedUnfairLock<Data>,
        callback: @escaping @Sendable (String) -> Void,
        flushAll: Bool = false
    ) {
        let lines: [String] = buffer.withLock { data in
            var extracted: [String] = []
            while let newlineIndex = data.firstIndex(of: 0x0A) {
                let lineData = data.subdata(in: 0..<newlineIndex)
                data.removeSubrange(0...newlineIndex)
                var str = String(decoding: lineData, as: UTF8.self)
                if str.hasSuffix("\r") { str.removeLast() }
                extracted.append(str)
            }
            if flushAll, !data.isEmpty {
                var str = String(decoding: data, as: UTF8.self)
                if str.hasSuffix("\r") { str.removeLast() }
                extracted.append(str)
                data.removeAll(keepingCapacity: false)
            }
            return extracted
        }
        for line in lines {
            callback(line)
        }
    }
}
