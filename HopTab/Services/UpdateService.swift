import AppKit
import CryptoKit
import Foundation
import Security

// MARK: - Feed constants

/// Developer ID team that signs every official HopTab build. A download that
/// is not signed by this team is never offered to the user, no matter what the
/// feed says.
private let hopTabTeamIdentifier = "GP4Y23ZTR6"

/// Code-signing requirement every downloaded build must satisfy: Apple-rooted
/// chain, Developer ID intermediate + leaf markers, and *our* team OU. This is
/// the same requirement `codesign -R` accepts.
private let hopTabDeveloperIDRequirement = """
anchor apple generic \
and certificate leaf[subject.OU] = "\(hopTabTeamIdentifier)" \
and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
and certificate leaf[field.1.2.840.113635.100.6.1.13] exists
"""

// MARK: - Errors

/// Everything that can go wrong between "there is an update" and "here is a
/// verified copy of it". Every case carries a message the UI can show as-is.
enum UpdateServiceError: LocalizedError {
    case invalidFeedURL
    case insecureURL(String)
    case http(status: Int, context: String)
    case malformedFeed
    case offline
    case timedOut
    case malformedChecksum(String)
    case checksumMismatch(expected: String, actual: String)
    case unpackFailed(String)
    case appNotFoundInArchive
    case signatureUnreadable(OSStatus)
    case signatureInvalid(OSStatus)
    case wrongDeveloper(found: String?)
    case systemTooOld(required: String)
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .invalidFeedURL:
            return "The update feed URL is not a valid URL."
        case .insecureURL(let url):
            return "Refusing to fetch an update over an insecure connection:\n\(url)"
        case .http(let status, let context):
            switch status {
            case 404: return "\(context) was not found on the server (404)."
            case 403: return "The server refused access to \(context.lowercased()) (403)."
            case 500...599: return "The update server is having problems (HTTP \(status)). Try again later."
            default: return "Unexpected response while fetching \(context.lowercased()) (HTTP \(status))."
            }
        case .malformedFeed:
            // hoptab.app answers unknown paths with a 200 + the homepage, so a
            // missing feed arrives as HTML, not as a 404.
            return "The update server did not return a valid update feed. Try again later."
        case .offline:
            return "No internet connection."
        case .timedOut:
            return "The connection timed out."
        case .malformedChecksum(let value):
            return "The update feed advertises a malformed SHA-256 checksum (\(value)). Refusing to download."
        case .checksumMismatch(let expected, let actual):
            return """
            The download does not match the checksum published in the update feed, so it was deleted.

            Expected: \(expected)
            Received: \(actual)

            Download HopTab from hoptab.app or GitHub Releases instead, and report this.
            """
        case .unpackFailed(let detail):
            let detail = detail.isEmpty ? "" : "\n\(detail)"
            return "Could not unpack the downloaded archive.\(detail)"
        case .appNotFoundInArchive:
            return "The downloaded archive does not contain HopTab.app."
        case .signatureUnreadable(let status):
            return "The downloaded app has no readable code signature (OSStatus \(status))."
        case .signatureInvalid(let status):
            return "The downloaded app failed Apple's code-signature check (OSStatus \(status)). It was deleted."
        case .wrongDeveloper(let found):
            let who = found.map { "“\($0)”" } ?? "an unknown developer"
            return """
            The downloaded app is signed by \(who), not by HopTab's Developer ID team \
            (\(hopTabTeamIdentifier)). It was deleted — do not install it.
            """
        case .systemTooOld(let required):
            return "HopTab \(required) or later requires a newer version of macOS than this Mac is running."
        case .fileSystem(let detail):
            return "A file-system error interrupted the update: \(detail)"
        }
    }

    /// Maps `URLError` onto the cases above so offline/timeout/404 all read well.
    static func from(_ error: Error, context: String) -> UpdateServiceError {
        if let already = error as? UpdateServiceError { return already }
        if error is DecodingError { return .malformedFeed }
        guard let urlError = error as? URLError else {
            return .fileSystem(error.localizedDescription)
        }
        switch urlError.code {
        case .cancelled:
            return .fileSystem("cancelled")
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut
        case .fileDoesNotExist, .resourceUnavailable:
            return .http(status: 404, context: context)
        default:
            return .fileSystem(urlError.localizedDescription)
        }
    }
}

// MARK: - Service

/// Lightweight auto-update checker with an end-to-end *verified* download path.
///
/// ## Feed format (v2)
///
/// ```json
/// {
///   "version": "1.4.0",
///   "build": 8,
///   "downloadURL": "https://github.com/royalbhati/HopTab/releases/download/v1.4.0/HopTab-1.4.0.zip",
///   "sha256": "b03651533efa10f515eedc3e4a9fe5bb77d8529f371201a5c650d632dbb2a00a",
///   "minimumSystemVersion": "14.0",
///   "releaseNotes": "New layout templates, bug fixes."
/// }
/// ```
///
/// `sha256` (lowercase hex of the **zip**, exactly what `shasum -a 256` prints —
/// the release workflow already emits it) and `minimumSystemVersion` are new in
/// v2 and both optional, so a v1 feed still decodes. A feed with no `sha256`
/// degrades to the old "open the download page in the browser" behaviour after
/// logging a warning; a feed *with* one gets the verified in-app flow:
///
///   download → SHA-256 (CryptoKit, constant-time compare) → unzip →
///   `SecStaticCodeCheckValidity` + Developer ID team check → reveal in Finder.
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    // MARK: - TODO(Sparkle)
    //
    // This is a *verified assisted* updater, not a silent one: it proves the
    // bytes are ours, then hands the user a verified HopTab.app in Finder.
    // It deliberately does NOT replace the running bundle — swapping the app
    // you are executing from needs a separate process (a relaunch helper) and,
    // for anything under /Applications the user does not own, a privileged
    // helper installed with SMAppService + SMJobBless-style authorization.
    // That is out of scope here.
    //
    // Migration path when a dependency change is acceptable (Sparkle 2.x):
    //   1. Add the Sparkle SPM package (github.com/sparkle-project/Sparkle) —
    //      this touches HopTab.xcodeproj/project.pbxproj, which is why it is
    //      not done here.
    //   2. Replace update.json with an RSS appcast (`appcast.xml`) carrying
    //      `sparkle:edSignature` (EdDSA) + `sparkle:minimumSystemVersion`;
    //      generate it in .github/workflows/release.yml with `generate_appcast`.
    //      The `sha256` field below stays useful for Homebrew's cask.
    //   3. Put the EdDSA public key in Info.plist as `SUPublicEDKey` and the
    //      feed URL as `SUFeedURL`; keep the private key in the release
    //      keychain only (never in the repo).
    //   4. Swap this class's body for `SPUStandardUpdaterController`, keep the
    //      published property names below so MenuBarView/SettingsView do not
    //      have to change, and delete the verification helpers — Sparkle's
    //      installer does signature + EdDSA validation and the in-place swap
    //      (including the relaunch helper) itself.

    /// The URL to check for updates. Set this to your hosted JSON endpoint.
    private static let defaultFeedURL = "https://hoptab.app/update.json"
    private static let feedURLKey = "updateFeedURL"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 4 * 3600 // every 4 hours
    /// Launch is the worst moment to spend the main actor and the network on an
    /// update check — let the menu bar, the event tap and onboarding settle first.
    private static let launchCheckDelay: TimeInterval = 8

    // MARK: - Observable state
    //
    // UI binds to these; nothing here ever blocks the main thread.

    /// The newest update the feed advertises and this Mac can actually run,
    /// or nil when up to date.
    @Published private(set) var availableUpdate: UpdateInfo?
    /// True while the feed itself is being fetched.
    @Published private(set) var isChecking = false
    /// Where the verified-download pipeline currently is.
    @Published private(set) var downloadStage: DownloadStage = .idle
    /// 0…1 for the zip download, 1 once verification finished.
    @Published private(set) var downloadProgress: Double = 0
    /// One-line human status for the current stage ("Verifying signature…").
    @Published private(set) var statusMessage: String?
    /// Last failure (already localized). Cleared when a new attempt starts.
    @Published private(set) var lastError: String?
    /// Set only after a download passed **both** checksum and signature checks.
    @Published private(set) var verifiedAppURL: URL?
    /// When the feed was last fetched successfully.
    @Published private(set) var lastCheckDate: Date?

    @Published var autoCheckEnabled: Bool = UserDefaults.standard.object(forKey: "autoCheckUpdates") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "autoCheckUpdates") {
        didSet { UserDefaults.standard.set(autoCheckEnabled, forKey: "autoCheckUpdates") }
    }

    /// True while a download/verification is in flight (for spinners + disabling).
    var isDownloading: Bool { downloadStage.isBusy }

    /// Stages of the verified download, in order.
    enum DownloadStage: Equatable {
        case idle
        case downloading
        case verifyingChecksum
        case verifyingSignature
        /// Verified and revealed in Finder; `verifiedAppURL` is set.
        case ready
        case failed

        var isBusy: Bool {
            switch self {
            case .downloading, .verifyingChecksum, .verifyingSignature: return true
            case .idle, .ready, .failed: return false
            }
        }
    }

    private var downloadTask: Task<Void, Never>?

    struct UpdateInfo: Codable, Equatable {
        let version: String
        let build: Int?
        let downloadURL: String
        let releaseNotes: String?
        /// Lowercase hex SHA-256 of the zip at `downloadURL`. Optional purely
        /// for backwards compatibility with v1 feeds.
        let sha256: String?
        /// Lowest macOS version this build runs on, e.g. "14.0". Optional;
        /// absent means "same floor as the running build".
        let minimumSystemVersion: String?

        /// True when the feed gave us something to verify against.
        var isVerifiable: Bool {
            guard let sha256 else { return false }
            return !sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var feedURL: String {
        get { UserDefaults.standard.string(forKey: Self.feedURLKey) ?? Self.defaultFeedURL }
        set { UserDefaults.standard.set(newValue, forKey: Self.feedURLKey) }
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var currentBuild: Int {
        let str = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return Int(str) ?? 0
    }

    // MARK: - Check on Launch

    func checkOnLaunchIfNeeded() {
        guard autoCheckEnabled else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - last > Self.checkInterval else { return }
        Task { [weak self] in
            // Deferred so the menu-bar item is up before we touch the network.
            try? await Task.sleep(nanoseconds: UInt64(Self.launchCheckDelay * 1_000_000_000))
            await self?.checkForUpdates(silent: true)
        }
    }

    // MARK: - Manual Check

    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

        guard let url = URL(string: feedURL) else {
            report(UpdateServiceError.invalidFeedURL, title: "Update Error", silent: silent)
            return
        }
        guard url.scheme?.lowercased() == "https" else {
            report(UpdateServiceError.insecureURL(feedURL), title: "Update Error", silent: silent)
            return
        }

        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("HopTab/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response, context: "the update feed")
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)
            lastCheckDate = Date()
            lastError = nil

            guard isNewer(remote: info) else {
                availableUpdate = nil
                if !silent {
                    showAlert(title: "No Updates", message: "You're running the latest version (\(currentVersion)).")
                }
                return
            }

            // A release that drops this Mac's macOS version must not be offered
            // at all — not in the menu bar, not as an alert.
            guard Self.systemSatisfies(info.minimumSystemVersion) else {
                availableUpdate = nil
                NSLog("[UpdateService] HopTab %@ requires macOS %@ — not offering it on this Mac",
                      info.version, info.minimumSystemVersion ?? "?")
                if !silent {
                    showAlert(
                        title: "Update Requires a Newer macOS",
                        message: "HopTab \(info.version) requires macOS \(info.minimumSystemVersion ?? "newer") or later. "
                            + "You'll keep getting updates that support this Mac."
                    )
                }
                return
            }

            if !info.isVerifiable {
                NSLog("[UpdateService] Feed for %@ carries no sha256 — the download cannot be verified in-app. "
                      + "Publish a v2 feed (sha256 of the zip) to enable verified updates.", info.version)
            }

            availableUpdate = info
            if silent {
                // Never steal focus with a modal on launch — MenuBarView and the
                // Settings About pane both surface `availableUpdate`.
                NSLog("[UpdateService] Update available: %@ (have %@)", info.version, currentVersion)
            } else {
                showUpdateAvailable(info)
            }
        } catch {
            let wrapped = UpdateServiceError.from(error, context: "the update feed")
            report(wrapped, title: "Update Check Failed", silent: silent)
        }
    }

    // MARK: - Download + verify

    /// Kept synchronous and non-throwing for existing call sites (menu bar and
    /// Settings); the actual work runs in a detached-from-the-caller task.
    func downloadUpdate(_ info: UpdateInfo) {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            await self?.downloadAndVerify(info)
            self?.downloadTask = nil
        }
    }

    /// Cancels an in-flight download. Safe to call at any time.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if downloadStage.isBusy {
            downloadStage = .idle
            downloadProgress = 0
            statusMessage = nil
        }
    }

    /// Re-reveals the last verified build (for a "Show in Finder" button).
    func revealVerifiedApp() {
        guard let url = verifiedAppURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Downloads, checksums, unpacks and signature-checks `info`, then reveals
    /// the verified app in Finder. Never blocks the main thread: the network is
    /// `await`ed and hashing/unzipping/`SecStaticCode` run off the main actor.
    func downloadAndVerify(_ info: UpdateInfo) async {
        lastError = nil
        verifiedAppURL = nil
        downloadProgress = 0

        guard let url = URL(string: info.downloadURL) else {
            fail(.invalidFeedURL)
            return
        }
        // App Transport Security would block plain http anyway; failing loudly
        // beats a silent ATS error the user cannot interpret.
        guard url.scheme?.lowercased() == "https" else {
            fail(.insecureURL(info.downloadURL))
            return
        }
        guard Self.systemSatisfies(info.minimumSystemVersion) else {
            fail(.systemTooOld(required: info.version))
            return
        }

        // v1 feed (no sha256): nothing to verify against, so do not pretend.
        // Degrade to the historical behaviour and say why in the log.
        guard let expectedHex = info.sha256?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(), !expectedHex.isEmpty
        else {
            NSLog("[UpdateService] No sha256 in feed — opening %@ in the browser instead of verifying it",
                  info.downloadURL)
            downloadStage = .idle
            statusMessage = "Opened the download page. This feed publishes no checksum, so HopTab could not verify the download itself."
            NSWorkspace.shared.open(url)
            return
        }
        guard Self.isValidSHA256Hex(expectedHex) else {
            fail(.malformedChecksum(expectedHex))
            return
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("HopTabUpdate-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            fail(.fileSystem(error.localizedDescription))
            return
        }

        do {
            downloadStage = .downloading
            statusMessage = "Downloading HopTab \(info.version)…"
            let zipURL = try await downloadZip(from: url, into: workDir, version: info.version)

            try Task.checkCancellation()
            downloadStage = .verifyingChecksum
            downloadProgress = 1
            statusMessage = "Verifying checksum…"
            try await Self.verifyChecksum(of: zipURL, expectedHex: expectedHex)

            try Task.checkCancellation()
            downloadStage = .verifyingSignature
            statusMessage = "Verifying Apple code signature…"
            let appURL = try await Self.unpackAndVerify(zipURL: zipURL, workDir: workDir, version: info.version)

            // Housekeeping: the zip and the staging copy are no longer needed.
            try? fm.removeItem(at: workDir)

            downloadStage = .ready
            verifiedAppURL = appURL
            statusMessage = "HopTab \(info.version) verified — drag it into Applications to finish."
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
            showVerifiedAlert(info: info, appURL: appURL)
        } catch is CancellationError {
            try? fm.removeItem(at: workDir)
            downloadStage = .idle
            downloadProgress = 0
            statusMessage = nil
        } catch {
            try? fm.removeItem(at: workDir)
            fail(UpdateServiceError.from(error, context: "the download"))
        }
    }

    private func downloadZip(from url: URL, into dir: URL, version: String) async throws -> URL {
        let destination = dir.appendingPathComponent("HopTab-\(version).zip")
        try? FileManager.default.removeItem(at: destination)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false

        let delegate = DownloadToFileDelegate(destination: destination) { [weak self] fraction in
            Task { @MainActor in self?.downloadProgress = fraction }
        }
        // The delegate has to be the *session* delegate: a task-scoped delegate
        // (the `delegate:` argument of `download(for:delegate:)`) never receives
        // `didWriteData`, so the progress bar would sit at 0 for the whole
        // download — measured, not assumed.
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("HopTab/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let response = try await delegate.download(using: session, request: request)
        try Self.validate(response, context: "the download")
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw UpdateServiceError.fileSystem("the download produced no file")
        }
        return destination
    }

    // MARK: - Checksum (off the main actor)

    /// Streams the file through CryptoKit and compares against the feed value in
    /// constant time. Deletes the file on mismatch so a tampered zip cannot be
    /// opened by accident.
    private nonisolated static func verifyChecksum(of fileURL: URL, expectedHex: String) async throws {
        guard let expected = bytes(fromHex: expectedHex) else {
            throw UpdateServiceError.malformedChecksum(expectedHex)
        }
        let actual = try await Task.detached(priority: .userInitiated) {
            try sha256(ofFileAt: fileURL)
        }.value

        guard constantTimeEquals(actual, expected) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw UpdateServiceError.checksumMismatch(expected: expectedHex, actual: hexString(actual))
        }
    }

    private nonisolated static func sha256(ofFileAt url: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Array(hasher.finalize())
    }

    /// Length-independent byte comparison — no early exit on the first
    /// differing byte.
    private nonisolated static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    nonisolated static func isValidSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private nonisolated static func bytes(fromHex hex: String) -> [UInt8]? {
        guard isValidSHA256Hex(hex) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private nonisolated static func hexString(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Unpack + code-signature verification (off the main actor)

    /// Unzips with `/usr/bin/ditto`, moves the app somewhere the user can find
    /// it, then validates the signature **at its final location** so what the
    /// user is handed is exactly what was verified.
    private nonisolated static func unpackAndVerify(zipURL: URL, workDir: URL, version: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try unzip(zipURL, into: extractDir)

            let stagedApp = try locateApp(in: extractDir)
            let finalURL = try relocate(stagedApp, version: version)
            do {
                try verifyCodeSignature(of: finalURL)
            } catch {
                // Never leave an unverified bundle lying around with our name on it.
                try? fm.removeItem(at: finalURL)
                throw error
            }
            return finalURL
        }.value
    }

    private nonisolated static func unzip(_ zipURL: URL, into destination: URL) throws {
        // `ditto` ships with macOS, understands the AppleDouble/`--sequesterRsrc`
        // archives the release workflow produces, and preserves symlinks and
        // extended attributes that a naive unzip would flatten (which alone
        // would invalidate the signature).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw UpdateServiceError.unpackFailed(error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateServiceError.unpackFailed(detail)
        }
    }

    private nonisolated static func locateApp(in directory: URL) throws -> URL {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let candidates = contents.filter { $0.lastPathComponent != "__MACOSX" }

        if let app = candidates.first(where: { $0.pathExtension == "app" }) {
            return app
        }
        // Some archives wrap the app in a folder — look one level deeper.
        for child in candidates {
            let nested = (try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)) ?? []
            if let app = nested.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        throw UpdateServiceError.appNotFoundInArchive
    }

    /// Moves the verified build into ~/Downloads (falling back to the work dir)
    /// so Finder reveals it somewhere the user recognises and the system's temp
    /// sweeper cannot delete it out from under them.
    private nonisolated static func relocate(_ app: URL, version: String) throws -> URL {
        let fm = FileManager.default
        guard let downloads = try? fm.url(for: .downloadsDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: false) else {
            return app
        }
        let destination = downloads.appendingPathComponent("HopTab-\(version).app")
        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: app, to: destination)
            return destination
        } catch {
            NSLog("[UpdateService] Could not move the verified app to Downloads (%@) — leaving it in the temp dir",
                  error.localizedDescription)
            return app
        }
    }

    /// `SecStaticCode` validation: the signature must be intact across every
    /// architecture and nested bundle, *and* the chain must be our Developer ID.
    /// A merely-valid signature is not enough — anyone can sign anything.
    private nonisolated static func verifyCodeSignature(of appURL: URL) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw UpdateServiceError.signatureUnreadable(createStatus)
        }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate)

        // 1. Is the signature itself intact (all slices, all sealed resources)?
        let validity = SecStaticCodeCheckValidity(code, flags, nil)
        guard validity == errSecSuccess else {
            throw UpdateServiceError.signatureInvalid(validity)
        }

        // 2. Is it *ours*? Team OU + Developer ID marker OIDs, Apple anchor.
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            hopTabDeveloperIDRequirement as CFString, SecCSFlags(), &requirement)
        guard requirementStatus == errSecSuccess, let requirement else {
            throw UpdateServiceError.signatureUnreadable(requirementStatus)
        }
        let identityStatus = SecStaticCodeCheckValidity(code, flags, requirement)
        guard identityStatus == errSecSuccess else {
            throw UpdateServiceError.wrongDeveloper(found: teamIdentifier(of: code))
        }

        // 3. Belt and braces: the Team ID the signature actually carries.
        let team = teamIdentifier(of: code)
        guard team == hopTabTeamIdentifier else {
            throw UpdateServiceError.wrongDeveloper(found: team)
        }
    }

    private nonisolated static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Version comparison

    private func isNewer(remote: UpdateInfo) -> Bool {
        // Compare build number first if available
        if let remoteBuild = remote.build, remoteBuild > currentBuild {
            return true
        }
        // Fall back to semantic version comparison
        return Self.compareVersions(remote.version, isGreaterThan: currentVersion)
    }

    private nonisolated static func compareVersions(_ a: String, isGreaterThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    /// True when this Mac's macOS is at least `required` ("14.0", "15", "15.2.1").
    /// A missing or unparseable value is treated as "no floor" so a typo in the
    /// feed never silently hides updates from everyone.
    nonisolated static func systemSatisfies(_ required: String?) -> Bool {
        guard let required, !required.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let parts = required.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else {
            NSLog("[UpdateService] Unparseable minimumSystemVersion '%@' — ignoring it", required)
            return true
        }
        let version = OperatingSystemVersion(
            majorVersion: parts.count > 0 ? parts[0] : 0,
            minorVersion: parts.count > 1 ? parts[1] : 0,
            patchVersion: parts.count > 2 ? parts[2] : 0
        )
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(version)
    }

    private nonisolated static func validate(_ response: URLResponse, context: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw UpdateServiceError.http(status: http.statusCode, context: context)
        }
    }

    // MARK: - UI

    private func fail(_ error: UpdateServiceError) {
        downloadStage = .failed
        downloadProgress = 0
        statusMessage = nil
        lastError = error.errorDescription
        NSLog("[UpdateService] %@", error.errorDescription ?? "unknown error")
        showAlert(title: "Update Failed", message: error.errorDescription ?? "Unknown error.")
    }

    private func report(_ error: UpdateServiceError, title: String, silent: Bool) {
        lastError = error.errorDescription
        NSLog("[UpdateService] %@", error.errorDescription ?? "unknown error")
        if !silent {
            showAlert(title: title, message: error.errorDescription ?? "Unknown error.")
        }
    }

    private func showUpdateAvailable(_ info: UpdateInfo) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "HopTab \(info.version) is available (you have \(currentVersion))."
        if let notes = info.releaseNotes, !notes.isEmpty {
            alert.informativeText += "\n\n\(notes)"
        }
        if !info.isVerifiable {
            alert.informativeText += "\n\nThis feed publishes no checksum, so the download opens in your browser and HopTab cannot verify it."
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: info.isVerifiable ? "Download & Verify" : "Download")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            downloadUpdate(info)
        }
    }

    private func showVerifiedAlert(info: UpdateInfo, appURL: URL) {
        // NOTE: we deliberately stop here rather than replacing the running
        // bundle. Self-replacement requires a separate helper process (and
        // privileges we do not hold) — see TODO(Sparkle) at the top.
        let alert = NSAlert()
        alert.messageText = "HopTab \(info.version) Verified"
        alert.informativeText = """
        The download matches the published SHA-256 checksum and is signed by HopTab's Developer ID team \
        (\(hopTabTeamIdentifier)), notarized by Apple.

        To finish:
        1. Quit HopTab.
        2. Drag \(appURL.lastPathComponent) into your Applications folder, replacing the old copy.
        3. Launch HopTab again.

        Homebrew users can instead run: brew upgrade --cask hoptab
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Download progress

/// Session-scoped download delegate: reports byte progress and moves the
/// finished file into place. Callbacks arrive serialized on URLSession's own
/// delegate queue, so the stored state below needs no extra locking.
private final class DownloadToFileDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    private var finalResponse: URLResponse?

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Runs the download to completion, honouring task cancellation.
    func download(using session: URLSession, request: URLRequest) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, Error>) in
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.task?.cancel()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // URLSession deletes `location` the moment this returns — move now,
        // synchronously, and report any failure through didCompleteWithError.
        finalResponse = downloadTask.response
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil

        if let error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
        } else if let moveError {
            continuation.resume(throwing: UpdateServiceError.fileSystem(moveError.localizedDescription))
        } else if let response = finalResponse ?? task.response {
            continuation.resume(returning: response)
        } else {
            continuation.resume(throwing: UpdateServiceError.fileSystem("the download returned no response"))
        }
    }
}
