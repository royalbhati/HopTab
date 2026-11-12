import AppKit
import Darwin
import Foundation

#if canImport(MetricKit)
import MetricKit
#endif

// MARK: - Crash-time primitives
//
// Everything in this section runs inside `NSSetUncaughtExceptionHandler`, i.e.
// in a process the Objective-C runtime has already decided to kill. It must not
// allocate, take locks, or dispatch: the file descriptor is opened while the app
// is healthy and the handler only ever calls write(2)/backtrace_symbols_fd(3).

/// Append-only descriptor for `crashes.log`, opened once at start-up.
/// -1 means "diagnostics are off / the log could not be opened": the handler
/// then does nothing except chain to whoever was installed before us.
private nonisolated(unsafe) var hopTabCrashLogFD: Int32 = -1

/// Whatever handler was installed before ours (e.g. by a future SDK). Always
/// chained so we never swallow someone else's report.
private nonisolated(unsafe) var hopTabPreviousExceptionHandler: (@convention(c) (NSException) -> Void)?

/// write(2) with EINTR/partial-write handling. No allocation.
private func hopTabWriteRaw(_ fd: Int32, _ pointer: UnsafePointer<CChar>, _ length: Int) {
    guard fd >= 0, length > 0 else { return }
    var offset = 0
    while offset < length {
        let written = write(fd, pointer + offset, length - offset)
        if written > 0 {
            offset += written
        } else if written < 0 && errno == EINTR {
            continue
        } else {
            return
        }
    }
}

/// Literals live in the binary's text segment — writing one allocates nothing.
private func hopTabWrite(_ fd: Int32, _ text: StaticString) {
    guard fd >= 0 else { return }
    if text.hasPointerRepresentation {
        text.utf8Start.withMemoryRebound(to: CChar.self, capacity: text.utf8CodeUnitCount) {
            hopTabWriteRaw(fd, $0, text.utf8CodeUnitCount)
        }
    }
}

/// `withCString` on a bridged NSString is the cheapest safe path to bytes here;
/// it may touch the allocator, which is acceptable for an *uncaught exception*
/// (unlike a signal handler, the heap is still in a defined state).
private func hopTabWrite(_ fd: Int32, _ text: String) {
    guard fd >= 0 else { return }
    text.withCString { hopTabWriteRaw(fd, $0, strlen($0)) }
}

/// Decimal integer via a stack buffer — no allocation, no formatter.
private func hopTabWrite(_ fd: Int32, integer value: Int) {
    guard fd >= 0 else { return }
    withUnsafeTemporaryAllocation(of: CChar.self, capacity: 24) { buffer in
        var index = 24
        var remaining = value
        let negative = remaining < 0
        if negative { remaining = -remaining }
        repeat {
            index -= 1
            buffer[index] = CChar(48 + (remaining % 10))
            remaining /= 10
        } while remaining > 0 && index > 1
        if negative {
            index -= 1
            buffer[index] = CChar(45) // '-'
        }
        if let base = buffer.baseAddress {
            hopTabWriteRaw(fd, base + index, 24 - index)
        }
    }
}

/// The uncaught-exception handler itself. Global (never a closure) so it can be
/// converted to the `@convention(c)` pointer `NSSetUncaughtExceptionHandler`
/// wants without capturing anything.
private func hopTabUncaughtExceptionHandler(_ exception: NSException) {
    let fd = hopTabCrashLogFD
    if fd >= 0 {
        hopTabWrite(fd, "\n=== HopTab uncaught exception (epoch ")
        hopTabWrite(fd, integer: Int(time(nil)))
        hopTabWrite(fd, ") ===\nname: ")
        hopTabWrite(fd, exception.name.rawValue)
        hopTabWrite(fd, "\nreason: ")
        hopTabWrite(fd, exception.reason ?? "(none)")
        hopTabWrite(fd, "\nstack:\n")

        // backtrace_symbols_fd(3) is async-signal-safe: it symbolicates straight
        // into the descriptor without malloc'ing an array of strings.
        let addresses = exception.callStackReturnAddresses
        let frameCount = min(addresses.count, 128)
        if frameCount > 0 {
            withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: frameCount) { buffer in
                for index in 0..<frameCount {
                    buffer[index] = UnsafeMutableRawPointer(bitPattern: UInt(truncating: addresses[index]))
                }
                if let base = buffer.baseAddress {
                    backtrace_symbols_fd(base, Int32(frameCount), fd)
                }
            }
        } else {
            hopTabWrite(fd, "(no return addresses)\n")
        }
        hopTabWrite(fd, "=== end ===\n")
        fsync(fd)
    }

    hopTabPreviousExceptionHandler?(exception)
}

// MARK: - CrashReporter

/// Opt-in, **local-first** diagnostics. No third party, no personal data, and
/// nothing is ever transmitted: MetricKit hands us on-device crash/hang reports,
/// we write them under `~/Library/Application Support/HopTab/Diagnostics/`, and
/// the only "upload" path is the user attaching the folder to a GitHub issue
/// themselves.
///
/// Why this exists: HopTab holds a session-level `CGEvent` tap. If it dies, the
/// app switcher and every global shortcut stop working with no visible cause —
/// previously with no diagnostic either.
///
/// Deliberately **not** implemented: any network upload. If one is ever added it
/// must be a separate, default-off switch — this flag governs local collection
/// only, which is why it defaults to on.
final class CrashReporter: NSObject {
    static let shared = CrashReporter()

    /// UserDefaults key: local diagnostics collection. Default **on** (nothing
    /// leaves the machine). Absent key == enabled.
    static let enabledDefaultsKey = "diagnosticsEnabled"

    /// Keep the folder small and bounded: newest N payloads, hard size ceiling.
    private static let maxPayloadFiles = 20
    private static let maxDirectoryBytes = 5 * 1024 * 1024   // 5 MB
    private static let maxCrashLogBytes = 512 * 1024         // 512 KB before rotation

    private let queue = DispatchQueue(label: "com.hoptab.crashreporter", qos: .utility)
    private var didStart = false

    // MARK: Locations

    /// `~/Library/Application Support/HopTab/Diagnostics`
    var diagnosticsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("HopTab", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Human-readable append-only log (uncaught exceptions + MetricKit summaries).
    var crashLogURL: URL { diagnosticsDirectory.appendingPathComponent("crashes.log") }
    private var rotatedCrashLogURL: URL { diagnosticsDirectory.appendingPathComponent("crashes-previous.log") }

    // MARK: Opt-in flag

    var isEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        }
        set {
            guard newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
            if newValue {
                start()
            } else {
                stop()
            }
        }
    }

    /// True when there is something worth revealing (for enabling a UI button).
    var hasDiagnostics: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: crashLogURL.path) { return true }
        let contents = (try? fm.contentsOfDirectory(at: diagnosticsDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { $0.pathExtension == "json" }
    }

    // MARK: - Lifecycle

    /// Call once, as early as possible in `applicationDidFinishLaunching`, so a
    /// crash during the rest of start-up is still captured.
    func start() {
        guard !didStart else { return }
        guard isEnabled else {
            NSLog("[CrashReporter] Diagnostics disabled (%@ = false) — collecting nothing", Self.enabledDefaultsKey)
            return
        }
        didStart = true

        prepareDirectory()
        rotateCrashLogIfNeeded()
        installUncaughtExceptionHandler()

        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        NSLog("[CrashReporter] MetricKit subscribed; diagnostics at %@", diagnosticsDirectory.path)
        #else
        NSLog("[CrashReporter] MetricKit unavailable on this platform — exception logging only")
        #endif

        queue.async { [weak self] in self?.prune() }
    }

    /// Stops collecting. The installed C handler stays in place (there is no
    /// safe way to un-install one that may be chained) but goes inert as soon as
    /// the descriptor is gone.
    func stop() {
        #if canImport(MetricKit)
        MXMetricManager.shared.remove(self)
        #endif
        let fd = hopTabCrashLogFD
        hopTabCrashLogFD = -1   // publish the sentinel *before* closing
        if fd >= 0 { close(fd) }
        didStart = false
        NSLog("[CrashReporter] Diagnostics collection stopped")
    }

    /// Breadcrumb for anything that fails silently but is not a crash — e.g. the
    /// event tap being disabled by the system. Cheap, async, never on the hot path.
    func log(_ message: String) {
        guard isEnabled else { return }
        let line = "[\(Self.timestamp())] \(message)\n"
        queue.async { [weak self] in self?.append(line) }
    }

    // MARK: - Packaging (the only way anything leaves this machine: by hand)

    /// Writes a single summary report next to the raw payloads and returns it,
    /// so a UI can offer "Reveal diagnostics in Finder" for the user to attach
    /// to a GitHub issue themselves. Returns nil when there is nothing to show.
    @discardableResult
    func packageLatestDiagnostics() -> URL? {
        let fm = FileManager.default
        guard hasDiagnostics else { return nil }
        prepareDirectory()

        let payloads = (try? fm.contentsOfDirectory(at: diagnosticsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in modificationDate(of: lhs) > modificationDate(of: rhs) } ?? []

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var report = """
        HopTab diagnostics
        ==================
        Generated:  \(Self.timestamp())
        App:        \(version) (build \(build))
        macOS:      \(ProcessInfo.processInfo.operatingSystemVersionString)
        Uptime:     \(Int(ProcessInfo.processInfo.systemUptime))s

        Nothing in this folder is transmitted anywhere. Attach it to a GitHub
        issue at https://github.com/royalbhati/HopTab/issues if you want it read.

        MetricKit payloads (newest first): \(payloads.count)

        """
        for payload in payloads.prefix(Self.maxPayloadFiles) {
            report += "  - \(payload.lastPathComponent)\n"
        }

        if let log = try? String(contentsOf: crashLogURL, encoding: .utf8), !log.isEmpty {
            let tail = log.count > 20_000 ? String(log.suffix(20_000)) : log
            report += "\nLast entries from crashes.log\n-----------------------------\n\(tail)\n"
        } else {
            report += "\nNo uncaught exceptions recorded.\n"
        }

        let destination = diagnosticsDirectory
            .appendingPathComponent("HopTab-diagnostics-\(Self.fileStamp()).txt")
        do {
            try report.write(to: destination, atomically: true, encoding: .utf8)
            return destination
        } catch {
            NSLog("[CrashReporter] Could not write the diagnostics report: %@", error.localizedDescription)
            return payloads.first ?? crashLogURL
        }
    }

    /// Packages, then reveals the result in Finder. Safe to call with nothing
    /// collected — it then just opens the (empty) folder.
    func revealDiagnosticsInFinder() {
        prepareDirectory()
        if let report = packageLatestDiagnostics() {
            NSWorkspace.shared.activateFileViewerSelecting([report])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([diagnosticsDirectory])
        }
    }

    /// Deletes every collected diagnostic (for a "Clear diagnostics" button).
    func clearDiagnostics() {
        stop()
        try? FileManager.default.removeItem(at: diagnosticsDirectory)
        if isEnabled { start() }
    }

    // MARK: - Storage

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
    }

    private func rotateCrashLogIfNeeded() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: crashLogURL.path)[.size]) as? NSNumber,
              size.intValue > Self.maxCrashLogBytes else { return }
        try? fm.removeItem(at: rotatedCrashLogURL)
        try? fm.moveItem(at: crashLogURL, to: rotatedCrashLogURL)
    }

    private func installUncaughtExceptionHandler() {
        guard hopTabCrashLogFD < 0 else { return }
        let fd = crashLogURL.path.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o600) }
        guard fd >= 0 else {
            NSLog("[CrashReporter] Could not open %@ (errno %d) — exception logging disabled",
                  crashLogURL.path, errno)
            return
        }
        hopTabCrashLogFD = fd
        hopTabPreviousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(hopTabUncaughtExceptionHandler)
    }

    /// Appends to the same log the crash handler writes to. Used off the main
    /// thread only.
    private func append(_ text: String) {
        prepareDirectory()
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: crashLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: crashLogURL, options: .atomic)
        }
    }

    /// Keeps the folder under both caps, oldest-first.
    private func prune() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let contents = try? fm.contentsOfDirectory(at: diagnosticsDirectory,
                                                         includingPropertiesForKeys: keys) else { return }
        let payloads = contents
            .filter { $0.pathExtension == "json" || $0.pathExtension == "txt" }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }

        var kept: [URL] = []
        for (index, url) in payloads.enumerated() {
            if index >= Self.maxPayloadFiles {
                try? fm.removeItem(at: url)
            } else {
                kept.append(url)
            }
        }

        var total = kept.reduce(0) { $0 + fileSize(of: $1) }
        for url in kept.reversed() where total > Self.maxDirectoryBytes {
            total -= fileSize(of: url)
            try? fm.removeItem(at: url)
        }
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - MetricKit

#if canImport(MetricKit)
extension CrashReporter: MXMetricManagerSubscriber {
    /// Performance metrics — not diagnostics, and nothing here is written.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    /// Crash and hang reports the system collected on-device. Written verbatim
    /// (Apple's own JSON) plus a one-line human summary in `crashes.log`.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.prepareDirectory()
            for payload in payloads {
                self.store(payload)
            }
            self.prune()
        }
    }

    private func store(_ payload: MXDiagnosticPayload) {
        let stamp = Self.fileStamp()
        let url = diagnosticsDirectory
            .appendingPathComponent("diagnostic-\(stamp)-\(UInt32.random(in: 0..<0xFFFF)).json")
        let json = payload.jsonRepresentation()
        do {
            try json.write(to: url, options: .atomic)
        } catch {
            NSLog("[CrashReporter] Could not write a MetricKit payload: %@", error.localizedDescription)
        }

        var summary = "[\(Self.timestamp())] MetricKit payload → \(url.lastPathComponent)\n"
        for crash in payload.crashDiagnostics ?? [] {
            let type = crash.exceptionType.map { "\($0)" } ?? "?"
            let code = crash.exceptionCode.map { "\($0)" } ?? "?"
            let signal = crash.signal.map { "\($0)" } ?? "?"
            let reason = crash.terminationReason ?? "(none)"
            summary += "    crash: exceptionType=\(type) code=\(code) signal=\(signal) reason=\(reason)\n"
        }
        for hang in payload.hangDiagnostics ?? [] {
            summary += "    hang: \(hang.hangDuration)\n"
        }
        append(summary)
    }
}
#endif
