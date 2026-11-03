import Combine
import Foundation
import MetricKit
import UIKit

/// App-wide logging and crash capture, all kept on the phone. A rolling in-memory buffer feeds
/// the Logs screen; the same lines are appended to a session file. Crashes are caught two ways:
/// MetricKit delivers a full diagnostic on the next launch (the reliable path), and lightweight
/// exception/signal handlers leave a short report immediately (best-effort).
final class Diagnostics: NSObject, @unchecked Sendable {
    static let shared = Diagnostics()

    /// Fires (coalesced) when new lines arrive, so an open Logs screen can refresh.
    let didLog = PassthroughSubject<Void, Never>()

    private let lock = NSLock()
    private var buffer: [String] = []
    private let maxLines = 3000
    private let writeQueue = DispatchQueue(label: "colon3.diagnostics")
    private var sessionHandle: FileHandle?

    let logsDirectory: URL
    let crashesDirectory: URL
    private let sessionFile: URL

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private override init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        logsDirectory = base
        crashesDirectory = base.appendingPathComponent("Crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: crashesDirectory, withIntermediateDirectories: true)
        sessionFile = base.appendingPathComponent("session.log")
        super.init()
    }

    /// Call once, early. Opens the session file, installs crash handlers and MetricKit.
    func start() {
        // Keep the previous session's log so a crash's lead-up survives the relaunch.
        let previous = logsDirectory.appendingPathComponent("session-previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: sessionFile, to: previous)
        FileManager.default.createFile(atPath: sessionFile.path, contents: nil)
        sessionHandle = try? FileHandle(forWritingTo: sessionFile)

        let device = UIDevice.current
        log("colon3 \(Bundle.appVersion) on \(device.systemName) \(device.systemVersion)", category: "app")
        installCrashHandlers()
        MXMetricManager.shared.add(self)
    }

    /// Settings › Diagnostics & Logs › Detailed Logging (off by default): extra lines for tracking
    /// down a problem (cover lookups, file protection, open files). Off, they cost nothing.
    static let detailedKey = "diagnostics.detailed"
    static var isDetailed: Bool { UserDefaults.standard.bool(forKey: detailedKey) }

    /// A line only written with Detailed Logging on; the text isn't even built otherwise.
    func detail(_ message: @autoclosure () -> String, category: String = "app") {
        guard Self.isDetailed else { return }
        log(message(), category: category)
    }

    /// Checked when you come back to the app: running out of file descriptors makes everything
    /// that opens a file fail at once (covers, fonts, the network), so if it's happening, what's
    /// holding them is noted, whatever the setting.
    func checkOpenFiles() {
        let count = Self.openFileCount()
        if count > 1000 {
            log("Open files: \(count) of \(Self.fileLimit()). \(Self.openFileSummary())", category: "app")
        } else {
            detail("Open files: \(count) of \(Self.fileLimit())")
        }
    }

    /// What the open descriptors are: how many sockets, files and folders, and the folders most
    /// of the files are in.
    static func openFileSummary() -> String {
        var kinds: [String: Int] = [:]
        var places: [String: Int] = [:]
        var paths: [String: Int] = [:]
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for fd in 0..<Int32(min(Int(getdtablesize()), 8192)) {
            var info = stat()
            guard fstat(fd, &info) == 0 else { continue }
            let kind: String
            switch info.st_mode & S_IFMT {
            case S_IFSOCK: kind = "sockets"
            case S_IFREG: kind = "files"
            case S_IFDIR: kind = "folders"
            case S_IFIFO: kind = "pipes"
            case S_IFCHR: kind = "devices"
            default: kind = "other"
            }
            kinds[kind, default: 0] += 1
            if kind == "files" || kind == "folders", fcntl(fd, F_GETPATH, &path) != -1 {
                let url = URL(fileURLWithPath: String(cString: path))
                let place = url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: "/")
                places[place, default: 0] += 1
                paths[url.pathComponents.suffix(2).joined(separator: "/"), default: 0] += 1
            }
        }
        let counts = kinds.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        let top = places.sorted { $0.value > $1.value }.prefix(4).map { "\($0.value)× …/\($0.key)" }.joined(separator: "; ")
        // The same file open many times over is a leak; many different files in one folder isn't.
        let repeated = paths.filter { $0.value > 20 }.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.value)× \($0.key)" }.joined(separator: "; ")
        return counts + (top.isEmpty ? "" : ". Most in: " + top) + (repeated.isEmpty ? "" : ". Same file: " + repeated)
    }

    /// How many file descriptors (files and connections) the app has open right now.
    static func openFileCount() -> Int {
        let limit = min(Int(getdtablesize()), 4096)
        return (0..<limit).reduce(0) { count, fd in fcntl(Int32(fd), F_GETFD) != -1 ? count + 1 : count }
    }

    static func fileLimit() -> Int {
        var limit = rlimit()
        getrlimit(RLIMIT_NOFILE, &limit)
        return Int(limit.rlim_cur)
    }

    // MARK: Logging

    func log(_ message: String, category: String = "app") {
        let line = "\(Self.stamp.string(from: Date())) [\(category)] \(message)"
        lock.lock()
        buffer.append(line)
        if buffer.count > maxLines { buffer.removeFirst(buffer.count - maxLines) }
        lock.unlock()

        writeQueue.async { [weak self] in
            guard let self, let data = (line + "\n").data(using: .utf8) else { return }
            self.sessionHandle?.write(data)
        }
        didLog.send()
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func clearSession() {
        lock.lock(); buffer.removeAll(); lock.unlock()
        writeQueue.async { [weak self] in
            self?.sessionHandle?.truncateFile(atOffset: 0)
        }
        didLog.send()
    }

    /// The whole session log as text, for sharing.
    func exportSessionText() -> String {
        lines.joined(separator: "\n")
    }

    // MARK: Crash reports

    struct CrashReport: Identifiable {
        let url: URL
        let date: Date
        let kind: String
        var id: String { url.lastPathComponent }
        var title: String {
            DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short) + " · " + kind
        }
    }

    func crashReports() -> [CrashReport] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: crashesDirectory, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.pathExtension == "txt" || $0.pathExtension == "json" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                let kind = url.pathExtension == "json" ? "MetricKit" : "Signal"
                return CrashReport(url: url, date: date, kind: kind)
            }
            .sorted { $0.date > $1.date }
    }

    func readCrash(_ report: CrashReport) -> String {
        (try? String(contentsOf: report.url, encoding: .utf8)) ?? "Couldn't read this report."
    }

    func clearCrashes() {
        for file in (try? FileManager.default.contentsOfDirectory(at: crashesDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Crash capture

    private func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let text = """
            Uncaught exception
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "–")

            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            Diagnostics.shared.writeCrash(text)
        }
        for signalNumber in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            signal(signalNumber) { received in
                let text = "Signal \(received)\n\n" + Thread.callStackSymbols.joined(separator: "\n")
                Diagnostics.shared.writeCrash(text)
                // Restore the default handler and re-raise so the OS still records it.
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    /// Best-effort synchronous write from a crash context.
    fileprivate func writeCrash(_ text: String) {
        // The signal may have landed while the lock was held; don't block, just skip the tail.
        var recent = ""
        if lock.try() {
            recent = buffer.suffix(80).joined(separator: "\n")
            lock.unlock()
        }
        let full = text + "\n\n--- recent log ---\n" + recent + "\n"
        let url = crashesDirectory.appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970)).txt")
        try? full.data(using: .utf8)?.write(to: url)
    }
}

extension Diagnostics: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {}

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !payload.crashDiagnostics.isNilOrEmpty {
            let date = payload.timeStampEnd
            let name = "metrickit-\(Int(date.timeIntervalSince1970)).json"
            try? payload.jsonRepresentation().write(to: crashesDirectory.appendingPathComponent(name))
        }
    }
}

private extension Optional where Wrapped == [MXCrashDiagnostic] {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

extension Bundle {
    static var appVersion: String {
        let version = main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}
