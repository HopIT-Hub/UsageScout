import AppKit
import CommonCrypto
import Foundation
import LocalAuthentication
import Security
import ServiceManagement
import SQLite3

struct AppBrand {
    static let appName = "UsageScout"
    static let companyName = "HopIT"
    static let settingsFolderName = "UsageScout"
    static let legacySettingsFolderName = "ClaudeMonitor"
    static let githubRepoOwner = "HopIT-Hub"
    static let githubRepoName = "UsageScout"
    static var latestReleaseAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(githubRepoOwner)/\(githubRepoName)/releases/latest")!
    }
}

struct MonitorConfig {
    static let sessionWindowHours: Int = 5
    static let weeklyResetWeekday: Int = 6 // 1=Sun, 2=Mon, ... 7=Sat
    static let weeklyResetHour: Int = 20
    static let weeklyResetMinute: Int = 0
    static let refreshIntervalSeconds: TimeInterval = 30
    static let recentFileLimit: Int = 60
    static let sessionBillableTokenLimit: Int = 200_000
    static let weeklyAllBillableTokenLimit: Int = 2_000_000
    static let weeklySonnetBillableTokenLimit: Int = 1_500_000
    static let dashboardRequestTimeoutSeconds: TimeInterval = 10
    static let dashboardAutoExtractCooldownSeconds: TimeInterval = 900
    static let updateCheckIntervalSeconds: TimeInterval = 21_600
    static let claudeStatusCheckIntervalSeconds: TimeInterval = 300
    static let claudeStatusRequestTimeoutSeconds: TimeInterval = 8
}

struct TokenUsage {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheCreation: Int = 0

    var billable: Int { input + output }
    var total: Int { input + output + cacheRead + cacheCreation }

    mutating func add(_ other: TokenUsage) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheCreation += other.cacheCreation
    }
}

struct SessionSummary {
    let id: String
    let firstEvent: Date
    let lastEvent: Date
    let usage: TokenUsage
    let messageCount: Int
}

struct DashboardLimitSummary {
    let utilizationPercent: Double
    let resetAt: Date?
}

struct DashboardUsageSummary {
    let fiveHour: DashboardLimitSummary?
    let sevenDay: DashboardLimitSummary?
    let sevenDayOpus: DashboardLimitSummary?
    let sevenDaySonnet: DashboardLimitSummary?
    let sevenDayCowork: DashboardLimitSummary?
    let orgUUID: String
}

struct UsageSnapshot {
    let generatedAt: Date
    let session: SessionSummary?
    let sessionResetAt: Date?
    let weeklyAllUsage: TokenUsage
    let weeklySonnetUsage: TokenUsage
    let weeklySessionCount: Int
    let weeklyStart: Date
    let weeklyResetAt: Date
    let scannedFileCount: Int
    let sourcePath: String
    let dashboard: DashboardUsageSummary?
    let sourceDescription: String
}

struct MonitorSettings: Codable {
    var sessionKey: String?
    var cookieHeader: String?
    var orgUUID: String?
    var dashboardAuthEnabled: Bool?
    var startAtLoginEnabled: Bool?
    var sessionResetCalibrationISO8601: String?
    var weeklyResetCalibrationISO8601: String?
    var onboardingCompleted: Bool?
    var onboardingMode: String?
}

struct ClaudeStatusResponse: Decodable {
    struct Status: Decodable {
        let indicator: String
        let description: String
    }

    let status: Status
}

struct GitHubLatestRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
    }
}

final class MonitorSettingsStore {
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "\(AppBrand.appName).SettingsStore")

    private lazy var settingsDirectoryURL: URL = {
        let base = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(AppBrand.settingsFolderName)
        return base
    }()

    private lazy var settingsURL: URL = {
        settingsDirectoryURL.appendingPathComponent("settings.json")
    }()

    private lazy var legacySettingsURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(AppBrand.legacySettingsFolderName)
            .appendingPathComponent("settings.json")
    }()

    func load() -> MonitorSettings {
        queue.sync {
            if let data = try? Data(contentsOf: settingsURL),
               let decoded = try? JSONDecoder().decode(MonitorSettings.self, from: data) {
                return decoded
            }
            if let data = try? Data(contentsOf: legacySettingsURL),
               let decoded = try? JSONDecoder().decode(MonitorSettings.self, from: data) {
                return decoded
            }
            return MonitorSettings()
        }
    }

    func save(_ settings: MonitorSettings) {
        queue.sync {
            try? fileManager.createDirectory(at: settingsDirectoryURL, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(settings) else { return }
            try? data.write(to: settingsURL, options: [.atomic])
        }
    }
}

struct DashboardCredentials {
    let sessionKey: String
    let orgUUID: String?
}

enum ClaudeDesktopCredentialExtractor {
    enum ExtractionError: Error {
        case message(String)
    }

    static func extract() -> DashboardCredentials? {
        switch extractDetailed() {
        case .success(let creds):
            return creds
        case .failure:
            return nil
        }
    }

    static func extractDetailed() -> Result<DashboardCredentials, ExtractionError> {
        let cookieSources = candidateCookieDBPaths()
        guard !cookieSources.isEmpty else {
            return .failure(.message("Claude cookie database not found."))
        }

        var diagnostics: [String] = []

        for source in cookieSources {
            guard let copied = copyCookiesDBToTemp(from: source) else {
                diagnostics.append("Failed to copy cookie DB: \(source.path)")
                continue
            }
            defer { try? FileManager.default.removeItem(at: copied.tempDirectory) }

            guard let row = readCookiesRow(from: copied.mainDB) else {
                diagnostics.append("Cookie DB has no sessionKey row: \(source.lastPathComponent)")
                continue
            }

            let sessionResult = decodeCookieValueDetailed(
                value: row.sessionValue,
                encryptedValue: row.sessionEncrypted,
                cookieName: "sessionKey"
            )
            guard let sessionKey = sessionResult.value else {
                diagnostics.append(sessionResult.error ?? "Could not decode sessionKey cookie.")
                continue
            }

            let orgDecoded = decodeCookieValueDetailed(
                value: row.lastActiveOrgValue,
                encryptedValue: row.lastActiveOrgEncrypted,
                cookieName: "lastActiveOrg"
            )
            let orgUUID = orgDecoded.value.flatMap(extractUUID)

            return .success(DashboardCredentials(sessionKey: sessionKey, orgUUID: orgUUID))
        }

        if diagnostics.isEmpty {
            diagnostics = ["Auto-extract failed for unknown reason."]
        }
        return .failure(.message(diagnostics.joined(separator: "\n")))
    }

    private struct CookieRow {
        let sessionValue: String?
        let sessionEncrypted: Data?
        let lastActiveOrgValue: String?
        let lastActiveOrgEncrypted: Data?
    }

    private struct CopiedCookieDB {
        let mainDB: URL
        let tempDirectory: URL
    }

    private static func candidateCookieDBPaths() -> [URL] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")

        let candidates = [
            root.appendingPathComponent("Cookies"),
            root.appendingPathComponent("Network").appendingPathComponent("Cookies"),
            root.appendingPathComponent("Default").appendingPathComponent("Cookies")
        ]

        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func copyCookiesDBToTemp(from source: URL) -> CopiedCookieDB? {
        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-monitor-cookies-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let destination = tempDir.appendingPathComponent(source.lastPathComponent)
            try fm.copyItem(at: source, to: destination)

            // Chromium often uses sidecar files; copy them if present so reads are consistent.
            for suffix in ["-wal", "-shm", "-journal"] {
                let sidecarSource = URL(fileURLWithPath: source.path + suffix)
                if fm.fileExists(atPath: sidecarSource.path) {
                    let sidecarDestination = URL(fileURLWithPath: destination.path + suffix)
                    try? fm.copyItem(at: sidecarSource, to: sidecarDestination)
                }
            }

            return CopiedCookieDB(mainDB: destination, tempDirectory: tempDir)
        } catch {
            try? fm.removeItem(at: tempDir)
            return nil
        }
    }

    private static func readCookiesRow(from dbURL: URL) -> CookieRow? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        let query = """
        SELECT
          MAX(CASE WHEN name = 'sessionKey' THEN value END) AS session_value,
          MAX(CASE WHEN name = 'sessionKey' THEN encrypted_value END) AS session_encrypted,
          MAX(CASE WHEN name = 'lastActiveOrg' THEN value END) AS org_value,
          MAX(CASE WHEN name = 'lastActiveOrg' THEN encrypted_value END) AS org_encrypted
        FROM cookies
        WHERE host_key IN ('.claude.ai', 'claude.ai')
          AND name IN ('sessionKey', 'lastActiveOrg');
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return CookieRow(
            sessionValue: sqliteColumnText(statement, 0),
            sessionEncrypted: sqliteColumnBlob(statement, 1),
            lastActiveOrgValue: sqliteColumnText(statement, 2),
            lastActiveOrgEncrypted: sqliteColumnBlob(statement, 3)
        )
    }

    private static func sqliteColumnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        let value = String(cString: cString)
        return value.isEmpty ? nil : value
    }

    private static func sqliteColumnBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        let length = sqlite3_column_bytes(stmt, index)
        guard length > 0,
              let ptr = sqlite3_column_blob(stmt, index) else {
            return nil
        }
        return Data(bytes: ptr, count: Int(length))
    }

    private static func decodeCookieValueDetailed(
        value: String?,
        encryptedValue: Data?,
        cookieName: String,
        hostKey: String = ".claude.ai"
    ) -> (value: String?, error: String?) {
        if let value {
            let normalized = normalizeCookieValue(value)
            if !normalized.isEmpty {
                return (normalized, nil)
            }
        }

        guard let encryptedValue, encryptedValue.count > 3 else {
            return (nil, "\(cookieName): missing plaintext and encrypted value.")
        }

        if encryptedValue.starts(with: Data("v10".utf8)) {
            let passwords = readSafeStoragePasswords()
            if passwords.isEmpty {
                return (nil, "\(cookieName): no Safe Storage key found in Keychain.")
            }

            var attemptedKeyCount = 0
            for password in passwords {
                for key in deriveChromiumAESKeys(password: password) {
                    attemptedKeyCount += 1
                    guard let decryptedPayload = decryptV10CookiePayload(encryptedValue: encryptedValue, key: key) else {
                        continue
                    }

                    if let decoded = extractCookieValue(
                        from: decryptedPayload,
                        cookieName: cookieName,
                        hostKey: hostKey
                    ) {
                        return (decoded, nil)
                    }
                }
            }

            return (nil, "\(cookieName): failed to decrypt v10 cookie with \(attemptedKeyCount) key derivations.")
        }

        if let text = String(data: encryptedValue, encoding: .utf8) {
            let normalized = normalizeCookieValue(text)
            if !normalized.isEmpty {
                return (normalized, nil)
            }
        }

        return (nil, "\(cookieName): unsupported encrypted cookie format.")
    }

    private static func extractCookieValue(
        from decryptedPayload: Data,
        cookieName: String,
        hostKey: String
    ) -> String? {
        if let direct = String(data: decryptedPayload, encoding: .utf8) {
            let normalized = normalizeCookieValue(direct)
            if isLikelyCookieValue(normalized, for: cookieName) {
                return normalized
            }
        }

        // Chromium DB version >= 24 can prepend SHA256(host_key) before the UTF-8 cookie value.
        if decryptedPayload.count > 32 {
            let candidates = [hostKey, hostKey.hasPrefix(".") ? String(hostKey.dropFirst()) : ".\(hostKey)"]
            let prefix = decryptedPayload.prefix(32)
            let tail = Data(decryptedPayload.dropFirst(32))

            for host in candidates {
                if prefix == sha256(Data(host.utf8)),
                   let text = String(data: tail, encoding: .utf8) {
                    let normalized = normalizeCookieValue(text)
                    if isLikelyCookieValue(normalized, for: cookieName) {
                        return normalized
                    }
                }
            }

            // Fallback for host mismatch edge cases: try tail as UTF-8 without hash validation.
            if let text = String(data: tail, encoding: .utf8) {
                let normalized = normalizeCookieValue(text)
                if isLikelyCookieValue(normalized, for: cookieName) {
                    return normalized
                }
            }
        }

        return nil
    }

    private static func isLikelyCookieValue(_ value: String, for cookieName: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value.contains(where: { $0.isNewline }) {
            return false
        }

        switch cookieName {
        case "sessionKey":
            return value.count >= 16
        case "lastActiveOrg":
            return value.count >= 8
        default:
            return true
        }
    }

    private static func normalizeCookieValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{0}", with: "")
    }

    private static func extractUUID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil {
            return trimmed.lowercased()
        }
        if let regex = try? NSRegularExpression(pattern: "([0-9a-fA-F-]{36})"),
           let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: trimmed.utf16.count)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: trimmed) {
            let candidate = String(trimmed[range]).lowercased()
            if UUID(uuidString: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    private static func readSafeStoragePasswords() -> [String] {
        let candidates: [(service: String, account: String?)] = [
            ("Claude Safe Storage", "Claude"),
            ("Claude Safe Storage", nil),
            ("Claude Desktop Safe Storage", "Claude Desktop"),
            ("Claude Desktop Safe Storage", nil),
            ("Electron Safe Storage", "Claude"),
            ("Electron Safe Storage", nil),
            ("Chromium Safe Storage", nil),
            ("Chrome Safe Storage", nil),
            ("Claude", "Claude"),
            ("Claude", nil),
            ("Anthropic", nil)
        ]

        var collected: [String] = []
        for candidate in candidates {
            if let password = findKeychainPassword(service: candidate.service, account: candidate.account),
               !password.isEmpty,
               !collected.contains(password) {
                collected.append(password)
            }
        }

        for password in findSafeStoragePasswordsByEnumeration() where !collected.contains(password) {
            collected.append(password)
        }

        // Chromium fallback used in some environments when no keychain entry exists.
        if !collected.contains("peanuts") {
            collected.append("peanuts")
        }

        return collected
    }

    private static func findKeychainPassword(service: String, account: String?) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: makeKeychainContext()
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return normalizeCookieValue(String(data: data, encoding: .utf8) ?? "")
    }

    private static func findSafeStoragePasswordsByEnumeration() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: makeKeychainContext()
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return []
        }

        let records: [[String: Any]]
        if let list = item as? [[String: Any]] {
            records = list
        } else if let single = item as? [String: Any] {
            records = [single]
        } else {
            records = []
        }

        var results: [String] = []
        for record in records {
            let service = (record[kSecAttrService as String] as? String ?? "").lowercased()
            let account = (record[kSecAttrAccount as String] as? String ?? "").lowercased()
            let looksLikeSafeStorage =
                service.contains("safe storage")
                && (service.contains("claude")
                    || service.contains("anthropic")
                    || service.contains("electron")
                    || service.contains("chrom"))

            let accountLooksRelevant = account.contains("claude") || account.contains("electron")
            guard looksLikeSafeStorage || accountLooksRelevant else {
                continue
            }

            guard let data = record[kSecValueData as String] as? Data else {
                continue
            }

            let normalized = normalizeCookieValue(String(data: data, encoding: .utf8) ?? "")
            if !normalized.isEmpty, !results.contains(normalized) {
                results.append(normalized)
            }
        }

        return results
    }

    private static func makeKeychainContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = false
        return context
    }

    private static func deriveChromiumAESKeys(password: String) -> [Data] {
        let combinations: [(UInt32, Int)] = [
            (1003, kCCKeySizeAES128),
            (1003, kCCKeySizeAES256),
            (1, kCCKeySizeAES128),
            (1, kCCKeySizeAES256)
        ]

        var keys: [Data] = []
        for (iterations, keyLength) in combinations {
            if let key = deriveChromiumAESKey(password: password, iterations: iterations, keyLength: keyLength),
               !keys.contains(key) {
                keys.append(key)
            }
        }
        return keys
    }

    private static func deriveChromiumAESKey(password: String, iterations: UInt32, keyLength: Int) -> Data? {
        var key = Data(count: keyLength)
        let salt = Data("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { keyBytes -> Int32 in
            let keyPtr = keyBytes.bindMemory(to: UInt8.self).baseAddress
            return salt.withUnsafeBytes { saltBytes -> Int32 in
                let saltPtr = saltBytes.bindMemory(to: UInt8.self).baseAddress
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    password,
                    password.utf8.count,
                    saltPtr,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    iterations,
                    keyPtr,
                    keyLength
                )
            }
        }
        return status == kCCSuccess ? key : nil
    }

    private static func decryptV10CookiePayload(encryptedValue: Data, key: Data) -> Data? {
        let cipher = encryptedValue.dropFirst(3)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        let outputCount = output.count
        let keyCount = key.count
        let cipherCount = cipher.count
        var outLength = 0

        let status = key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
            iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                cipher.withUnsafeBytes { cipherBytes -> CCCryptorStatus in
                    output.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            keyCount,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            cipherCount,
                            outBytes.baseAddress,
                            outputCount,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess, outLength > 0 else { return nil }
        output.removeSubrange(outLength..<output.count)
        return output
    }

    private static func sha256(_ data: Data) -> Data {
        var hash = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        hash.withUnsafeMutableBytes { hashBuffer in
            data.withUnsafeBytes { dataBuffer in
                _ = CC_SHA256(
                    dataBuffer.baseAddress,
                    CC_LONG(data.count),
                    hashBuffer.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }
        return hash
    }
}

final class StartAtLoginManager {
    struct State {
        let enabled: Bool
        let canToggle: Bool
        let requiresApproval: Bool
        let detail: String?
    }

    enum StartAtLoginError: LocalizedError {
        case unsupportedOS
        case notPackagedApp
        case serviceError(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "Start at login requires macOS 13 or newer."
            case .notPackagedApp:
                return "Start at login is available only when running UsageScout as a packaged .app."
            case .serviceError(let text):
                return text
            }
        }
    }

    func currentState() -> State {
        guard #available(macOS 13.0, *) else {
            return State(
                enabled: false,
                canToggle: false,
                requiresApproval: false,
                detail: "Start at login requires macOS 13+."
            )
        }

        guard isPackagedApp() else {
            return State(
                enabled: false,
                canToggle: false,
                requiresApproval: false,
                detail: "Build and run the packaged app to enable start at login."
            )
        }

        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            return State(enabled: true, canToggle: true, requiresApproval: false, detail: nil)
        case .requiresApproval:
            return State(
                enabled: false,
                canToggle: true,
                requiresApproval: true,
                detail: "Approve in System Settings > General > Login Items."
            )
        case .notRegistered:
            return State(enabled: false, canToggle: true, requiresApproval: false, detail: nil)
        case .notFound:
            return State(
                enabled: false,
                canToggle: true,
                requiresApproval: false,
                detail: "Move UsageScout.app to /Applications, then enable start at login."
            )
        @unknown default:
            return State(
                enabled: false,
                canToggle: false,
                requiresApproval: false,
                detail: "Start at login status is unavailable."
            )
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw StartAtLoginError.unsupportedOS
        }
        guard isPackagedApp() else {
            throw StartAtLoginError.notPackagedApp
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw StartAtLoginError.serviceError(error.localizedDescription)
        }
    }

    private func isPackagedApp() -> Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }
}

final class ClaudeUsageService {
    private let fileManager = FileManager.default
    private let settingsStore: MonitorSettingsStore
    private let iso8601WithFractional = ISO8601DateFormatter()
    private let iso8601Basic = ISO8601DateFormatter()
    private var lastDashboardAutoExtractAttempt: Date?

    private enum DashboardFetchFailure {
        case missingCookieHeader
        case missingOrgUUID
        case requestFailed(statusCode: Int?)
        case invalidPayload
    }

    private enum DashboardFetchResult {
        case success(DashboardUsageSummary)
        case failure(DashboardFetchFailure)
    }

    init(settingsStore: MonitorSettingsStore = MonitorSettingsStore()) {
        self.settingsStore = settingsStore
        iso8601WithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso8601Basic.formatOptions = [.withInternetDateTime]
    }

    func collectSnapshot(now: Date = Date()) -> UsageSnapshot {
        if dashboardAuthModeEnabled(), let dashboard = fetchDashboardUsage() {
            let weekWindow = weeklyWindow(now: now)
            return UsageSnapshot(
                generatedAt: now,
                session: nil,
                sessionResetAt: dashboard.fiveHour?.resetAt,
                weeklyAllUsage: TokenUsage(),
                weeklySonnetUsage: TokenUsage(),
                weeklySessionCount: 0,
                weeklyStart: weekWindow.start,
                weeklyResetAt: dashboard.sevenDay?.resetAt ?? weekWindow.nextReset,
                scannedFileCount: 0,
                sourcePath: "https://claude.ai/api/organizations/\(dashboard.orgUUID)/usage",
                dashboard: dashboard,
                sourceDescription: "Dashboard API (/usage)"
            )
        }

        return collectLocalSnapshot(now: now)
    }

    private func dashboardAuthModeEnabled() -> Bool {
        let settings = settingsStore.load()
        return settings.dashboardAuthEnabled ?? false
    }

    private func collectLocalSnapshot(now: Date) -> UsageSnapshot {
        let settings = settingsStore.load()
        let defaultSourceRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
        let sourceRoots = localJSONLSourceRoots(defaultRoot: defaultSourceRoot)
        let primarySourceRoot = sourceRoots.first ?? defaultSourceRoot

        let weekWindow = weeklyWindow(now: now, settings: settings)
        let files = candidateJSONLFiles(
            sourceRoots: sourceRoots,
            weeklyStart: weekWindow.start
        )

        var sessions: [String: MutableSession] = [:]
        var eventsBySession: [String: [UsageEvent]] = [:]
        var weeklyAllUsage = TokenUsage()
        var weeklySonnetUsage = TokenUsage()
        var seenUsageKeys = Set<String>()

        for fileURL in files {
            for line in readLines(from: fileURL) {
                guard let event = parseEvent(from: line) else { continue }

                var normalizedUsage = event.usage
                if normalizedUsage.total > 0, let key = event.usageDedupKey {
                    if seenUsageKeys.contains(key) {
                        normalizedUsage = TokenUsage()
                    } else {
                        seenUsageKeys.insert(key)
                    }
                }

                let normalizedEvent = UsageEvent(
                    sessionId: event.sessionId,
                    timestamp: event.timestamp,
                    usage: normalizedUsage,
                    countsAsMessage: event.countsAsMessage,
                    usageDedupKey: event.usageDedupKey,
                    model: event.model
                )
                eventsBySession[event.sessionId, default: []].append(normalizedEvent)

                if sessions[event.sessionId] == nil {
                    sessions[event.sessionId] = MutableSession(
                        id: event.sessionId,
                        firstEvent: event.timestamp,
                        lastEvent: event.timestamp
                    )
                }

                guard var session = sessions[event.sessionId] else { continue }
                session.absorb(timestamp: normalizedEvent.timestamp, usage: normalizedEvent.usage, countsAsMessage: normalizedEvent.countsAsMessage)
                sessions[event.sessionId] = session

                if normalizedEvent.timestamp >= weekWindow.start && normalizedEvent.timestamp < weekWindow.nextReset {
                    weeklyAllUsage.add(normalizedUsage)
                    if let model = normalizedEvent.model?.lowercased(), model.contains("sonnet") {
                        weeklySonnetUsage.add(normalizedUsage)
                    }
                }
            }
        }

        let sessionSummaries = sessions.values.map { $0.toSummary() }
        let currentSession = sessionSummaries.max(by: { $0.lastEvent < $1.lastEvent })
        let sessionResetAt = calibratedResetDate(
            fromISO8601: settings.sessionResetCalibrationISO8601,
            intervalSeconds: TimeInterval(MonitorConfig.sessionWindowHours * 3_600),
            now: now
        ) ?? currentSession.map { nextSessionReset(anchor: $0.firstEvent, now: now) }
        let currentWindowedSession: SessionSummary? = {
            guard let base = currentSession else { return nil }
            guard let reset = sessionResetAt else { return base }
            let interval = TimeInterval(MonitorConfig.sessionWindowHours * 3_600)
            let windowStart = reset.addingTimeInterval(-interval)
            guard let events = eventsBySession[base.id] else { return base }

            var usage = TokenUsage()
            var messageCount = 0
            for event in events where event.timestamp >= windowStart && event.timestamp < reset {
                usage.add(event.usage)
                if event.countsAsMessage { messageCount += 1 }
            }

            return SessionSummary(
                id: base.id,
                firstEvent: base.firstEvent,
                lastEvent: base.lastEvent,
                usage: usage,
                messageCount: messageCount
            )
        }()
        let weeklySessionCount = sessionSummaries.filter {
            $0.lastEvent >= weekWindow.start && $0.firstEvent < weekWindow.nextReset
        }.count

        return UsageSnapshot(
            generatedAt: now,
            session: currentWindowedSession,
            sessionResetAt: sessionResetAt,
            weeklyAllUsage: weeklyAllUsage,
            weeklySonnetUsage: weeklySonnetUsage,
            weeklySessionCount: weeklySessionCount,
            weeklyStart: weekWindow.start,
            weeklyResetAt: weekWindow.nextReset,
            scannedFileCount: files.count,
            sourcePath: primarySourceRoot.path,
            dashboard: nil,
            sourceDescription: "Local cache logs (approximate)"
        )
    }

    private func fetchDashboardUsage() -> DashboardUsageSummary? {
        switch requestDashboardUsage() {
        case .success(let dashboard):
            return dashboard
        case .failure(let firstFailure):
            guard shouldAutoReextract(for: firstFailure),
                  autoReextractDashboardCredentials() else {
                return nil
            }

            switch requestDashboardUsage() {
            case .success(let dashboard):
                return dashboard
            case .failure:
                return nil
            }
        }
    }

    private func requestDashboardUsage() -> DashboardFetchResult {
        guard let cookieHeader = resolvedCookieHeader() else {
            return .failure(.missingCookieHeader)
        }

        guard let orgUUID = discoverOrgUUID() else {
            return .failure(.missingOrgUUID)
        }

        return requestDashboardUsage(cookieHeader: cookieHeader, orgUUID: orgUUID)
    }

    private func requestDashboardUsage(cookieHeader: String, orgUUID: String) -> DashboardFetchResult {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgUUID)/usage") else {
            return .failure(.missingOrgUUID)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = MonitorConfig.dashboardRequestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseCode: Int?

        URLSession.shared.dataTask(with: request) { data, response, _ in
            responseData = data
            responseCode = (response as? HTTPURLResponse)?.statusCode
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + MonitorConfig.dashboardRequestTimeoutSeconds + 2)

        guard responseCode == 200 else {
            return .failure(.requestFailed(statusCode: responseCode))
        }

        guard let data = responseData,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidPayload)
        }

        let summary = DashboardUsageSummary(
            fiveHour: parseDashboardLimit(object["five_hour"]),
            sevenDay: parseDashboardLimit(object["seven_day"]),
            sevenDayOpus: parseDashboardLimit(object["seven_day_opus"]),
            sevenDaySonnet: parseDashboardLimit(object["seven_day_sonnet"]),
            sevenDayCowork: parseDashboardLimit(object["seven_day_cowork"]),
            orgUUID: orgUUID
        )
        return .success(summary)
    }

    private func shouldAutoReextract(for failure: DashboardFetchFailure) -> Bool {
        let env = ProcessInfo.processInfo.environment
        let hasEnvAuth = (env["CLAUDE_COOKIE_HEADER"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || (env["CLAUDE_SESSION_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        if hasEnvAuth {
            return false
        }

        if let last = lastDashboardAutoExtractAttempt,
           Date().timeIntervalSince(last) < MonitorConfig.dashboardAutoExtractCooldownSeconds {
            return false
        }

        switch failure {
        case .missingCookieHeader, .missingOrgUUID:
            return true
        case .requestFailed(let statusCode):
            return statusCode == 400 || statusCode == 401 || statusCode == 403 || statusCode == 404
        case .invalidPayload:
            return false
        }
    }

    private func autoReextractDashboardCredentials() -> Bool {
        lastDashboardAutoExtractAttempt = Date()

        switch ClaudeDesktopCredentialExtractor.extractDetailed() {
        case .success(let creds):
            var settings = settingsStore.load()
            settings.sessionKey = creds.sessionKey
            settings.cookieHeader = nil
            settings.orgUUID = creds.orgUUID?.lowercased()
            settingsStore.save(settings)
            return true
        case .failure:
            return false
        }
    }

    private func parseDashboardLimit(_ raw: Any?) -> DashboardLimitSummary? {
        guard let dict = raw as? [String: Any] else {
            return nil
        }

        guard let utilization = doubleValue(from: dict["utilization"]) else {
            return nil
        }

        let resetAt: Date?
        if let resetText = dict["resets_at"] as? String {
            resetAt = parseTimestamp(resetText)
        } else {
            resetAt = nil
        }

        return DashboardLimitSummary(
            utilizationPercent: max(0.0, min(100.0, utilization)),
            resetAt: resetAt
        )
    }

    private func resolvedCookieHeader() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let fullCookie = env["CLAUDE_COOKIE_HEADER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fullCookie.isEmpty {
            return fullCookie
        }

        if let sessionKey = env["CLAUDE_SESSION_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionKey.isEmpty {
            return "sessionKey=\(sessionKey)"
        }

        let settings = settingsStore.load()
        if let fullCookie = settings.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !fullCookie.isEmpty {
            return fullCookie
        }

        if let sessionKey = settings.sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionKey.isEmpty {
            return "sessionKey=\(sessionKey)"
        }

        return nil
    }

    private func discoverOrgUUID() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let orgFromEnv = env["CLAUDE_ORG_UUID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUUIDLike(orgFromEnv) {
            return orgFromEnv
        }

        let settings = settingsStore.load()
        if let savedOrg = settings.orgUUID?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUUIDLike(savedOrg) {
            return savedOrg.lowercased()
        }

        if let cookieHeader = resolvedCookieHeader(),
           let cookieOrg = cookieValue(named: "lastActiveOrg", in: cookieHeader),
           let orgUUID = extractUUID(from: cookieOrg) {
            return orgUUID
        }

        let levelDBRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
            .appendingPathComponent("Local Storage")
            .appendingPathComponent("leveldb")

        guard let files = try? fileManager.contentsOfDirectory(
            at: levelDBRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = files
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                return name.hasSuffix(".ldb") || name.hasSuffix(".log")
            }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
            }

        for fileURL in candidates.prefix(6) {
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            if let org = firstMatch(
                pattern: "organization_([0-9a-fA-F-]{36})",
                in: text
            ) {
                return org.lowercased()
            }
        }

        return nil
    }

    private func cookieValue(named key: String, in header: String) -> String? {
        for segment in header.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<eq])
            guard name == key else { continue }
            let rawValue = String(trimmed[trimmed.index(after: eq)...])
            return rawValue.removingPercentEncoding ?? rawValue
        }
        return nil
    }

    private func extractUUID(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isUUIDLike(trimmed) {
            return trimmed.lowercased()
        }
        if let match = firstMatch(pattern: "([0-9a-fA-F-]{36})", in: trimmed),
           isUUIDLike(match) {
            return match.lowercased()
        }
        return nil
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private func isUUIDLike(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private func localJSONLSourceRoots(defaultRoot: URL) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let localAgentRoot = home
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
            .appendingPathComponent("local-agent-mode-sessions")

        let candidates = [defaultRoot, localAgentRoot]
        var roots: [URL] = []
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            roots.append(candidate)
        }
        return roots
    }

    private func shouldIncludeJSONLFile(_ fileURL: URL, sourceRoot: URL) -> Bool {
        if sourceRoot.lastPathComponent == "projects" {
            return true
        }

        // In Claude Desktop local-agent sessions, include embedded .claude/projects logs
        // and per-session audit logs that carry top-level usage summaries.
        return fileURL.path.contains("/.claude/projects/") || fileURL.lastPathComponent == "audit.jsonl"
    }

    private func candidateJSONLFiles(sourceRoots: [URL], weeklyStart: Date) -> [URL] {
        var candidates: [(url: URL, modified: Date)] = []

        for sourceRoot in sourceRoots {
            guard let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "jsonl" else { continue }
                guard shouldIncludeJSONLFile(fileURL, sourceRoot: sourceRoot) else { continue }
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else {
                    continue
                }
                candidates.append((fileURL, values.contentModificationDate ?? .distantPast))
            }
        }

        let sortedByRecent = candidates.sorted { $0.modified > $1.modified }
        let recent = Array(sortedByRecent.prefix(MonitorConfig.recentFileLimit)).map(\.url)
        let weekly = candidates
            .filter { $0.modified >= weeklyStart.addingTimeInterval(-86_400) }
            .map(\.url)

        var seen = Set<String>()
        var merged: [URL] = []
        for url in recent + weekly {
            let key = url.path
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(url)
            }
        }
        return merged
    }

    private func parseEvent(from line: String) -> UsageEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let sessionId = (object["sessionId"] as? String) ?? (object["session_id"] as? String),
              let timestampString = (object["timestamp"] as? String) ?? (object["_audit_timestamp"] as? String),
              let timestamp = parseTimestamp(timestampString) else {
            return nil
        }

        let usage = extractUsage(from: object)
        let type = object["type"] as? String ?? ""
        let isMessage = (type == "assistant" || type == "user")
        let dedupKey = usage.total > 0 ? usageDedupKey(from: object, sessionId: sessionId) : nil
        let model = extractModel(from: object)

        return UsageEvent(
            sessionId: sessionId,
            timestamp: timestamp,
            usage: usage,
            countsAsMessage: isMessage,
            usageDedupKey: dedupKey,
            model: model
        )
    }

    private func extractUsage(from object: [String: Any]) -> TokenUsage {
        let usageDict: [String: Any]?
        if let message = object["message"] as? [String: Any],
           let messageUsage = message["usage"] as? [String: Any] {
            usageDict = messageUsage
        } else if (object["type"] as? String) == "result",
                  let topLevelUsage = object["usage"] as? [String: Any] {
            usageDict = topLevelUsage
        } else {
            usageDict = nil
        }

        guard let usageDict else {
            return TokenUsage()
        }

        return TokenUsage(
            input: intValue(from: usageDict["input_tokens"]),
            output: intValue(from: usageDict["output_tokens"]),
            cacheRead: intValue(from: usageDict["cache_read_input_tokens"]),
            cacheCreation: intValue(from: usageDict["cache_creation_input_tokens"])
        )
    }

    private func parseTimestamp(_ value: String) -> Date? {
        if let date = iso8601WithFractional.date(from: value) {
            return date
        }
        return iso8601Basic.date(from: value)
    }

    private func intValue(from raw: Any?) -> Int {
        if let intValue = raw as? Int {
            return intValue
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let text = raw as? String, let intValue = Int(text) {
            return intValue
        }
        return 0
    }

    private func doubleValue(from raw: Any?) -> Double? {
        if let doubleValue = raw as? Double {
            return doubleValue
        }
        if let intValue = raw as? Int {
            return Double(intValue)
        }
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        if let text = raw as? String, let doubleValue = Double(text) {
            return doubleValue
        }
        return nil
    }

    private func extractModel(from object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else {
            return nil
        }
        return message["model"] as? String
    }

    private func usageDedupKey(from object: [String: Any], sessionId: String) -> String? {
        if let requestId = object["requestId"] as? String,
           let message = object["message"] as? [String: Any],
           let messageId = message["id"] as? String {
            return "\(sessionId)|\(requestId)|\(messageId)"
        }

        if let uuid = object["uuid"] as? String {
            return "\(sessionId)|\(uuid)"
        }
        return nil
    }

    private func readLines(from url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func nextSessionReset(anchor: Date, now: Date) -> Date {
        let interval = TimeInterval(MonitorConfig.sessionWindowHours * 3_600)
        if now <= anchor {
            return anchor.addingTimeInterval(interval)
        }
        let elapsed = now.timeIntervalSince(anchor)
        let completedWindows = Int(elapsed / interval)
        let nextWindow = completedWindows + 1
        return anchor.addingTimeInterval(TimeInterval(nextWindow) * interval)
    }

    private func weeklyWindow(now: Date, settings: MonitorSettings? = nil) -> (start: Date, nextReset: Date) {
        if let weeklyCalibration = calibratedResetDate(
            fromISO8601: settings?.weeklyResetCalibrationISO8601,
            intervalSeconds: 7 * 86_400,
            now: now
        ) {
            return (
                start: weeklyCalibration.addingTimeInterval(-7 * 86_400),
                nextReset: weeklyCalibration
            )
        }

        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current

        var dayCursor = calendar.startOfDay(for: now)
        while calendar.component(.weekday, from: dayCursor) != MonitorConfig.weeklyResetWeekday {
            guard let previous = calendar.date(byAdding: .day, value: -1, to: dayCursor) else {
                break
            }
            dayCursor = previous
        }

        var resetCandidate = calendar.date(
            bySettingHour: MonitorConfig.weeklyResetHour,
            minute: MonitorConfig.weeklyResetMinute,
            second: 0,
            of: dayCursor
        ) ?? dayCursor

        if resetCandidate > now {
            resetCandidate = calendar.date(byAdding: .day, value: -7, to: resetCandidate) ?? resetCandidate
        }

        let next = calendar.date(byAdding: .day, value: 7, to: resetCandidate) ?? resetCandidate
        return (start: resetCandidate, nextReset: next)
    }

    private func calibratedResetDate(
        fromISO8601 value: String?,
        intervalSeconds: TimeInterval,
        now: Date
    ) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              intervalSeconds > 0,
              let base = parseTimestamp(value) else {
            return nil
        }

        if base > now {
            return base
        }

        let elapsed = now.timeIntervalSince(base)
        let intervalsToAdvance = Int(elapsed / intervalSeconds) + 1
        return base.addingTimeInterval(Double(intervalsToAdvance) * intervalSeconds)
    }
}

private struct UsageEvent {
    let sessionId: String
    let timestamp: Date
    let usage: TokenUsage
    let countsAsMessage: Bool
    let usageDedupKey: String?
    let model: String?
}

private struct MutableSession {
    let id: String
    var firstEvent: Date
    var lastEvent: Date
    var usage: TokenUsage = TokenUsage()
    var messageCount: Int = 0

    mutating func absorb(timestamp: Date, usage: TokenUsage, countsAsMessage: Bool) {
        if timestamp < firstEvent {
            firstEvent = timestamp
        }
        if timestamp > lastEvent {
            lastEvent = timestamp
        }
        self.usage.add(usage)
        if countsAsMessage {
            messageCount += 1
        }
    }

    func toSummary() -> SessionSummary {
        SessionSummary(
            id: id,
            firstEvent: firstEvent,
            lastEvent: lastEvent,
            usage: usage,
            messageCount: messageCount
        )
    }
}

final class MenuBarController: NSObject, NSApplicationDelegate {
    private enum WizardDialogActionStyle {
        case primary
        case secondary
    }

    private struct WizardDialogAction {
        let title: String
        let style: WizardDialogActionStyle
    }

    private enum UserProfile: Equatable {
        case api
        case planDashboard
        case planCache
        case unknown
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settingsStore = MonitorSettingsStore()
    private let startAtLoginManager = StartAtLoginManager()
    private lazy var service = ClaudeUsageService(settingsStore: settingsStore)
    private let queue = DispatchQueue(label: "\(AppBrand.appName).Refresh", qos: .utility)

    private var refreshTimer: Timer?
    private var updateCheckTimer: Timer?
    private var claudeStatusTimer: Timer?
    private var snapshot: UsageSnapshot?
    private var latestAvailableVersion: String?
    private var latestReleaseURL: URL?
    private var isCheckingForUpdates = false
    private var isCheckingClaudeStatus = false
    private var claudeStatusLine = "Claude status: checking..."
    private var hasPresentedSetupWizardThisLaunch = false
    private let lastNotifiedVersionKey = "\(AppBrand.appName).LastNotifiedVersion"

    private let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private let iso8601StorageFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private lazy var calibrationInputFormatters: [DateFormatter] = {
        var formatters: [DateFormatter] = []

        let localized = DateFormatter()
        localized.locale = Locale.current
        localized.dateStyle = .medium
        localized.timeStyle = .short
        formatters.append(localized)

        for pattern in [
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd h:mm a",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd h:mm a",
            "M/d/yyyy h:mm a",
            "M/d/yyyy HH:mm",
            "MMM d, yyyy h:mm a"
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = pattern
            formatters.append(formatter)
        }

        return formatters
    }()

    private func runWizardDialog(
        title: String,
        message: String,
        detail: String? = nil,
        actions: [WizardDialogAction]
    ) -> Int? {
        guard !actions.isEmpty else { return nil }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title

        if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            alert.informativeText = "\(message)\n\n\(detail)"
        } else {
            alert.informativeText = message
        }
        alert.alertStyle = .informational

        if let appIcon = NSApp.applicationIconImage.copy() as? NSImage {
            appIcon.size = NSSize(width: 64, height: 64)
            alert.icon = appIcon
        }

        var primaryButton: NSButton?
        for action in actions {
            let button = alert.addButton(withTitle: action.title)
            if action.style == .primary, primaryButton == nil {
                primaryButton = button
            }
        }
        (primaryButton ?? alert.buttons.first)?.keyEquivalent = "\r"

        let response = alert.runModal()
        let firstRaw = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let index = Int(response.rawValue - firstRaw)
        guard index >= 0, index < actions.count else {
            return nil
        }
        return index
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.image = statusProgressImage(nil)
            button.title = "--"
        }
        applySavedStartAtLoginPreference()
        refreshData()
        refreshClaudeStatus()
        checkForUpdates(userInitiated: false)
        presentSetupWizardIfNeeded()

        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: MonitorConfig.refreshIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.refreshData()
        }

        claudeStatusTimer = Timer.scheduledTimer(
            withTimeInterval: MonitorConfig.claudeStatusCheckIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.refreshClaudeStatus()
        }

        updateCheckTimer = Timer.scheduledTimer(
            withTimeInterval: MonitorConfig.updateCheckIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.checkForUpdates(userInitiated: false)
        }
    }

    @objc private func refreshNowAction(_ sender: Any?) {
        refreshData()
    }

    @objc private func checkForUpdatesAction(_ sender: Any?) {
        if let releaseURL = latestReleaseURL,
           let latest = latestAvailableVersion,
           isVersion(latest, greaterThan: currentAppVersion()) {
            NSWorkspace.shared.open(releaseURL)
            return
        }
        checkForUpdates(userInitiated: true)
    }

    @objc private func openDataFolderAction(_ sender: Any?) {
        guard let sourcePath = snapshot?.sourcePath else { return }
        if sourcePath.hasPrefix("http://") || sourcePath.hasPrefix("https://"),
           let url = URL(string: sourcePath) {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: sourcePath))
    }

    @objc private func quitAction(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    @objc private func runSetupWizardAction(_ sender: Any?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.runSetupWizard(force: true)
        }
    }

    @objc private func openClaudeStatusPageAction(_ sender: Any?) {
        guard let url = URL(string: "https://status.claude.com") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openClaudeUsagePageAction(_ sender: Any?) {
        _ = openClaudeUsagePageForOrgLookup(showConfirmation: false)
    }

    @objc private func toggleStartAtLoginAction(_ sender: Any?) {
        let state = startAtLoginManager.currentState()
        guard state.canToggle else {
            showAlert(
                title: "Start at Login Unavailable",
                message: state.detail ?? "Start at login cannot be changed in this environment."
            )
            return
        }

        let target = !state.enabled
        do {
            try startAtLoginManager.setEnabled(target)

            var settings = settingsStore.load()
            settings.startAtLoginEnabled = target
            settingsStore.save(settings)

            let updated = startAtLoginManager.currentState()
            if updated.requiresApproval {
                showAlert(
                    title: "Approval Needed",
                    message: "Enable UsageScout in System Settings > General > Login Items."
                )
            }
            refreshData()
        } catch {
            showAlert(
                title: "Start at Login Failed",
                message: error.localizedDescription
            )
        }
    }

    @objc private func autoExtractDashboardAuthAction(_ sender: Any?) {
        let extraction = ClaudeDesktopCredentialExtractor.extractDetailed()
        let extracted: DashboardCredentials
        switch extraction {
        case .success(let creds):
            extracted = creds
        case .failure(let error):
            let reason: String
            switch error {
            case .message(let message):
                reason = message
            }
            showAlert(
                title: "Auto Extract Failed",
                message: "\(reason)\n\n\(cookieExtractionHelpText())"
            )
            return
        }

        var settings = settingsStore.load()
        settings.sessionKey = extracted.sessionKey
        settings.cookieHeader = nil
        if let orgUUID = extracted.orgUUID {
            settings.orgUUID = orgUUID
        }
        settingsStore.save(settings)
        showAlert(
            title: "Dashboard Auth Saved",
            message: extracted.orgUUID == nil
                ? "Saved session key. Org UUID will be auto-discovered."
                : "Saved session key and org UUID."
        )
        refreshData()
    }

    private func cookieExtractionHelpText() -> String {
        let claudeDesktopPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("Claude")
            .path

        return "Auto-extract uses Claude Desktop cookies at \(claudeDesktopPath). Install Claude Desktop, sign in, and open it once, then retry.\n\nIf you are CLI-only, use cache-only mode or enter session/cookie values manually."
    }

    private func presentSetupWizardIfNeeded() {
        guard !hasPresentedSetupWizardThisLaunch else { return }
        let settings = settingsStore.load()
        guard (settings.onboardingCompleted ?? false) == false else { return }
        hasPresentedSetupWizardThisLaunch = true
        runSetupWizard(force: false)
    }

    private func runSetupWizard(force: Bool) {
        let settings = settingsStore.load()
        if !force, (settings.onboardingCompleted ?? false) {
            return
        }

        let selection = runWizardDialog(
            title: "How do you use Claude?",
            message: "Choose your primary usage type for UsageScout setup.",
            detail: "You can run this again anytime from Dashboard Auth > Setup Wizard.",
            actions: [
                WizardDialogAction(title: "API (Pay As You Go)", style: .primary),
                WizardDialogAction(title: "Plan (Free/Pro/Max)", style: .secondary),
                WizardDialogAction(title: "Cancel", style: .secondary)
            ]
        )

        switch selection {
        case 0:
            runAPIOnboarding(existingSettings: settings)
        case 1:
            runPlanOnboarding(existingSettings: settings)
        default:
            break
        }
    }

    private func runAPIOnboarding(existingSettings: MonitorSettings) {
        while true {
            let selection = runWizardDialog(
                title: "API Usage Setup",
                message: "UsageScout currently reads usage from Claude dashboard data in this mode.",
                detail: "Next step: paste your org UUID. Click Open Claude Usage Page, then copy the UUID in the request URL segment between /organizations/ and /usage.",
                actions: [
                    WizardDialogAction(title: "Continue", style: .primary),
                    WizardDialogAction(title: "Open Claude Usage Page", style: .secondary),
                    WizardDialogAction(title: "Cancel", style: .secondary)
                ]
            )

            if selection == 1 {
                _ = openClaudeUsagePageForOrgLookup(showConfirmation: true)
                return
            }
            guard selection == 0 else {
                return
            }
            break
        }

        guard let orgUUIDInput = promptForText(
            title: "Enter Org UUID",
            message: "Paste UUID only. Example: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
            placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
            defaultValue: existingSettings.orgUUID ?? "",
            secure: false
        ) else {
            return
        }

        let normalizedOrgUUID = orgUUIDInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: normalizedOrgUUID) != nil else {
            showAlert(title: "Invalid UUID", message: "Please enter a valid org UUID.")
            return
        }

        var settings = settingsStore.load()
        settings.orgUUID = normalizedOrgUUID
        settings.dashboardAuthEnabled = true
        settings.onboardingCompleted = true
        settings.onboardingMode = "api"

        let extraction = ClaudeDesktopCredentialExtractor.extractDetailed()
        switch extraction {
        case .success(let creds):
            settings.sessionKey = creds.sessionKey
            settings.cookieHeader = nil
            settingsStore.save(settings)
            showAlert(
                title: "API Setup Complete",
                message: "Saved org UUID and enabled Dashboard Auth mode. Cookies were auto-extracted from Claude Desktop."
            )
        case .failure(let error):
            settingsStore.save(settings)
            let reason: String
            switch error {
            case .message(let message):
                reason = message
            }
            showAlert(
                title: "API Setup Saved (Partial)",
                message: "Saved org UUID and enabled Dashboard Auth mode, but cookie extraction failed.\n\nUse Dashboard Auth menu to add Session Key/Cookie Header.\n\nDetails: \(reason)\n\n\(cookieExtractionHelpText())"
            )
        }

        refreshData()
    }

    private func runPlanOnboarding(existingSettings: MonitorSettings) {
        let selection = runWizardDialog(
            title: "Plan Monitoring Options",
            message: "Monitoring usage may not be ToS compliant. Anthropic has not responded to our request for clarification.",
            actions: [
                WizardDialogAction(title: "Extract Cookies (Dashboard Auth)", style: .primary),
                WizardDialogAction(title: "Use ToS Compliant Cache Monitoring", style: .secondary),
                WizardDialogAction(title: "Cancel", style: .secondary)
            ]
        )

        switch selection {
        case 0:
            var settings = settingsStore.load()
            let extraction = ClaudeDesktopCredentialExtractor.extractDetailed()
            switch extraction {
            case .success(let creds):
                settings.sessionKey = creds.sessionKey
                settings.cookieHeader = nil
                if let org = creds.orgUUID {
                    settings.orgUUID = org
                }
                settings.dashboardAuthEnabled = true
                settings.onboardingCompleted = true
                settings.onboardingMode = "plan_dashboard"
                settingsStore.save(settings)
                showAlert(
                    title: "Dashboard Auth Enabled",
                    message: "Cookies were auto-extracted from Claude Desktop."
                )
            case .failure(let error):
                let reason: String
                switch error {
                case .message(let message):
                    reason = message
                }
                showAlert(
                    title: "Cookie Extraction Failed",
                    message: "UsageScout stayed in cache-only mode.\n\nYou can retry from Dashboard Auth > Setup Wizard.\n\nDetails: \(reason)\n\n\(cookieExtractionHelpText())"
                )
            }
        case 1:
            var settings = settingsStore.load()
            settings.dashboardAuthEnabled = false
            settings.onboardingCompleted = true
            settings.onboardingMode = "plan_cache"
            if settings.orgUUID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                settings.orgUUID = existingSettings.orgUUID
            }
            settingsStore.save(settings)
            showAlert(
                title: "Cache-Only Mode Enabled",
                message: "UsageScout will use local cache/log monitoring. This is less accurate, but avoids dashboard auth."
            )
        default:
            break
        }

        refreshData()
    }

    private func openClaudeUsagePageForOrgLookup(showConfirmation: Bool = false) -> Bool {
        let candidates = [
            "https://claude.ai/settings/usage",
            "https://claude.ai/settings",
            "https://claude.ai"
        ]

        var openedURL: String?
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                openedURL = candidate
                break
            }
        }

        if let openedURL {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(openedURL, forType: .string)

            if showConfirmation {
                showAlert(
                    title: "Opened Claude Page",
                    message: "Opened: \(openedURL)\n\nIf it did not come to front, paste this URL into your browser (already copied to clipboard), then copy org UUID from the request URL segment between /organizations/ and /usage."
                )
            }
            return true
        }

        showAlert(
            title: "Unable to Open Claude Page",
            message: "Please open https://claude.ai/settings/usage manually, then copy org UUID from the request URL segment between /organizations/ and /usage."
        )
        return false
    }

    @objc private func toggleDashboardAuthModeAction(_ sender: Any?) {
        var settings = settingsStore.load()
        let nextValue = !(settings.dashboardAuthEnabled ?? false)

        if nextValue {
            NSApp.activate(ignoringOtherApps: true)

            let warning = NSAlert()
            warning.messageText = "Dashboard Auth May Violate Terms"
            warning.informativeText = "UsageScout has not received written Anthropic approval for dashboard API usage. We do not recommend enabling Dashboard Auth mode at this time.\n\nEnable anyway at your own risk?"
            warning.alertStyle = .warning
            warning.addButton(withTitle: "Enable Anyway")
            warning.addButton(withTitle: "Cancel")

            let response = warning.runModal()
            guard response == .alertFirstButtonReturn else {
                return
            }
        }

        settings.dashboardAuthEnabled = nextValue
        settingsStore.save(settings)

        if nextValue {
            showAlert(
                title: "Dashboard Auth Enabled",
                message: "UsageScout will now attempt dashboard API reads when credentials are available. Use this mode at your own risk."
            )
        } else {
            showAlert(
                title: "Cache-Only Mode Enabled",
                message: "UsageScout will now use local cache/log data only."
            )
        }

        refreshData()
    }

    @objc private func enterSessionKeyAction(_ sender: Any?) {
        let existing = settingsStore.load().sessionKey ?? ""
        guard let sessionKey = promptForText(
            title: "Set Claude Session Key",
            message: "Paste only the value of the sessionKey cookie.",
            placeholder: "sessionKey value",
            defaultValue: existing,
            secure: true
        ) else {
            return
        }
        guard !sessionKey.isEmpty else {
            showAlert(title: "Not Saved", message: "Session key cannot be empty.")
            return
        }

        var settings = settingsStore.load()
        settings.sessionKey = sessionKey
        settings.cookieHeader = nil
        settingsStore.save(settings)
        refreshData()
    }

    @objc private func enterCookieHeaderAction(_ sender: Any?) {
        let existing = settingsStore.load().cookieHeader ?? ""
        guard let cookieHeader = promptForText(
            title: "Set Cookie Header",
            message: "Paste a full Cookie header. Example: sessionKey=...; lastActiveOrg=...",
            placeholder: "sessionKey=...; ...",
            defaultValue: existing,
            secure: false
        ) else {
            return
        }
        guard !cookieHeader.isEmpty else {
            showAlert(title: "Not Saved", message: "Cookie header cannot be empty.")
            return
        }

        var settings = settingsStore.load()
        settings.cookieHeader = cookieHeader
        settingsStore.save(settings)
        refreshData()
    }

    @objc private func enterOrgUUIDAction(_ sender: Any?) {
        let existing = settingsStore.load().orgUUID ?? ""
        guard let orgUUID = promptForText(
            title: "Set Org UUID (Optional)",
            message: "Use this only if auto-discovery is wrong.",
            placeholder: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
            defaultValue: existing,
            secure: false
        ) else {
            return
        }

        if !orgUUID.isEmpty && UUID(uuidString: orgUUID) == nil {
            showAlert(title: "Invalid UUID", message: "Please enter a valid org UUID.")
            return
        }

        var settings = settingsStore.load()
        settings.orgUUID = orgUUID.isEmpty ? nil : orgUUID.lowercased()
        settingsStore.save(settings)
        refreshData()
    }

    @objc private func clearSavedDashboardAuthAction(_ sender: Any?) {
        var settings = settingsStore.load()
        settings.sessionKey = nil
        settings.cookieHeader = nil
        settings.orgUUID = nil
        settingsStore.save(settings)
        showAlert(
            title: "Saved Auth Cleared",
            message: "Environment variables still take precedence if they are set."
        )
        refreshData()
    }

    @objc private func setSessionResetCalibrationAction(_ sender: Any?) {
        var settings = settingsStore.load()
        let defaultDate = parsedStoredDate(settings.sessionResetCalibrationISO8601)
            ?? snapshot?.sessionResetAt
            ?? Date().addingTimeInterval(TimeInterval(MonitorConfig.sessionWindowHours * 3_600))
        let defaultValue = absoluteDateFormatter.string(from: defaultDate)

        guard let input = promptForText(
            title: "Set Session Reset Time",
            message: "Enter the next session reset time from your dashboard. Example: \(defaultValue)",
            placeholder: "YYYY-MM-DD HH:MM (local time)",
            defaultValue: defaultValue,
            secure: false
        ) else {
            return
        }

        guard let parsed = parseCalibrationDateInput(input) else {
            showAlert(
                title: "Invalid Date/Time",
                message: "Could not parse that value. Use a local date/time like 2026-02-27 20:00."
            )
            return
        }

        settings.sessionResetCalibrationISO8601 = iso8601StorageFormatter.string(from: parsed)
        settingsStore.save(settings)
        showAlert(
            title: "Session Calibration Saved",
            message: "Local/cache mode will anchor session reset timing to \(absoluteDateFormatter.string(from: parsed))."
        )
        refreshData()
    }

    @objc private func setWeeklyResetCalibrationAction(_ sender: Any?) {
        var settings = settingsStore.load()
        let defaultDate = parsedStoredDate(settings.weeklyResetCalibrationISO8601)
            ?? snapshot?.weeklyResetAt
            ?? Date().addingTimeInterval(7 * 86_400)
        let defaultValue = absoluteDateFormatter.string(from: defaultDate)

        guard let input = promptForText(
            title: "Set Weekly Reset Time",
            message: "Enter the next weekly reset time from your dashboard. Example: \(defaultValue)",
            placeholder: "YYYY-MM-DD HH:MM (local time)",
            defaultValue: defaultValue,
            secure: false
        ) else {
            return
        }

        guard let parsed = parseCalibrationDateInput(input) else {
            showAlert(
                title: "Invalid Date/Time",
                message: "Could not parse that value. Use a local date/time like 2026-02-27 20:00."
            )
            return
        }

        settings.weeklyResetCalibrationISO8601 = iso8601StorageFormatter.string(from: parsed)
        settingsStore.save(settings)
        showAlert(
            title: "Weekly Calibration Saved",
            message: "Local/cache mode will anchor weekly reset timing to \(absoluteDateFormatter.string(from: parsed))."
        )
        refreshData()
    }

    @objc private func clearResetCalibrationsAction(_ sender: Any?) {
        var settings = settingsStore.load()
        settings.sessionResetCalibrationISO8601 = nil
        settings.weeklyResetCalibrationISO8601 = nil
        settingsStore.save(settings)
        showAlert(
            title: "Reset Calibrations Cleared",
            message: "UsageScout reverted to inferred local reset timing."
        )
        refreshData()
    }

    private func refreshData() {
        queue.async { [weak self] in
            guard let self else { return }
            let latest = self.service.collectSnapshot()
            DispatchQueue.main.async {
                self.snapshot = latest
                self.render(latest)
            }
        }
    }

    private func applySavedStartAtLoginPreference() {
        let settings = settingsStore.load()
        guard let preferred = settings.startAtLoginEnabled else { return }
        let current = startAtLoginManager.currentState()
        guard current.canToggle, current.enabled != preferred else { return }
        try? startAtLoginManager.setEnabled(preferred)
    }

    private func render(_ snapshot: UsageSnapshot) {
        let sessionRatio = snapshot.dashboard
            .flatMap { $0.fiveHour }
            .map { max(0.0, min(1.0, $0.utilizationPercent / 100.0)) }
            ?? progressRatio(
                used: snapshot.session?.usage.billable ?? 0,
                limit: MonitorConfig.sessionBillableTokenLimit
            )

        let weeklyAllRatio = snapshot.dashboard
            .flatMap { $0.sevenDay }
            .map { max(0.0, min(1.0, $0.utilizationPercent / 100.0)) }
            ?? progressRatio(
                used: snapshot.weeklyAllUsage.billable,
                limit: MonitorConfig.weeklyAllBillableTokenLimit
            )

        let weeklySonnetRatio = snapshot.dashboard
            .flatMap { $0.sevenDaySonnet }
            .map { max(0.0, min(1.0, $0.utilizationPercent / 100.0)) }
            ?? progressRatio(
                used: snapshot.weeklySonnetUsage.billable,
                limit: MonitorConfig.weeklySonnetBillableTokenLimit
            )

        if snapshot.dashboard?.fiveHour != nil || snapshot.session != nil {
            statusItem.button?.image = statusProgressImage(sessionRatio)
            statusItem.button?.title = percentText(sessionRatio)
        } else {
            statusItem.button?.image = statusProgressImage(nil)
            statusItem.button?.title = "--"
        }

        let menu = NSMenu()
        if let dashboard = snapshot.dashboard {
            menu.addItem(disabledItem("Current Session"))
            if dashboard.fiveHour != nil {
                menu.addItem(disabledItem("Usage: \(progressBar(sessionRatio)) \(percentText(sessionRatio))"))
            } else {
                menu.addItem(disabledItem("Usage data unavailable"))
            }
            if let reset = dashboard.fiveHour?.resetAt {
                menu.addItem(disabledItem("Session reset: \(countdown(until: reset))"))
                menu.addItem(disabledItem("Resets at: \(absoluteDateFormatter.string(from: reset))"))
            }
            menu.addItem(disabledItem("Org: \(shortId(dashboard.orgUUID))"))
        } else if let session = snapshot.session {
            menu.addItem(disabledItem("Current Session"))
            menu.addItem(disabledItem("ID: \(shortId(session.id))"))
            menu.addItem(disabledItem("Started: \(absoluteDateFormatter.string(from: session.firstEvent))"))
            menu.addItem(disabledItem("Last: \(relativeFromNow(session.lastEvent))"))
            menu.addItem(disabledItem("Msgs: \(formattedInt(session.messageCount))"))
            menu.addItem(disabledItem("Usage: \(progressBar(sessionRatio)) \(percentText(sessionRatio))"))
            menu.addItem(disabledItem("Cap: \(formattedInt(MonitorConfig.sessionBillableTokenLimit)) billable tokens"))
            menu.addItem(disabledItem("Billable: \(formattedInt(session.usage.billable)) tokens"))
            menu.addItem(disabledItem("Total: \(formattedInt(session.usage.total)) tokens"))
            if let reset = snapshot.sessionResetAt {
                menu.addItem(disabledItem("Session reset: \(countdown(until: reset))"))
                menu.addItem(disabledItem("Resets at: \(absoluteDateFormatter.string(from: reset))"))
            }
        } else {
            menu.addItem(disabledItem("No usage session data found"))
        }

        menu.addItem(.separator())
        menu.addItem(disabledItem("Weekly Usage"))
        if let dashboard = snapshot.dashboard {
            if dashboard.sevenDay != nil {
                menu.addItem(disabledItem("All models: \(progressBar(weeklyAllRatio)) \(percentText(weeklyAllRatio))"))
            }
            if dashboard.sevenDaySonnet != nil {
                menu.addItem(disabledItem("Sonnet only: \(progressBar(weeklySonnetRatio)) \(percentText(weeklySonnetRatio))"))
            }
            if let opus = dashboard.sevenDayOpus {
                let ratio = max(0.0, min(1.0, opus.utilizationPercent / 100.0))
                menu.addItem(disabledItem("Opus only: \(progressBar(ratio)) \(percentText(ratio))"))
            }
            if let cowork = dashboard.sevenDayCowork {
                let ratio = max(0.0, min(1.0, cowork.utilizationPercent / 100.0))
                menu.addItem(disabledItem("Cowork only: \(progressBar(ratio)) \(percentText(ratio))"))
            }
            if let weeklyReset = dashboard.sevenDay?.resetAt ?? dashboard.sevenDaySonnet?.resetAt {
                menu.addItem(disabledItem("Weekly reset: \(countdown(until: weeklyReset))"))
                menu.addItem(disabledItem("Resets at: \(absoluteDateFormatter.string(from: weeklyReset))"))
            }
        } else {
            menu.addItem(disabledItem("Week start: \(absoluteDateFormatter.string(from: snapshot.weeklyStart))"))
            menu.addItem(disabledItem("All models: \(progressBar(weeklyAllRatio)) \(percentText(weeklyAllRatio))"))
            menu.addItem(disabledItem("All models cap: \(formattedInt(MonitorConfig.weeklyAllBillableTokenLimit)) billable tokens"))
            menu.addItem(disabledItem("All models billable: \(formattedInt(snapshot.weeklyAllUsage.billable)) tokens"))
            menu.addItem(disabledItem("All models total: \(formattedInt(snapshot.weeklyAllUsage.total)) tokens"))
            menu.addItem(disabledItem("Sonnet only: \(progressBar(weeklySonnetRatio)) \(percentText(weeklySonnetRatio))"))
            menu.addItem(disabledItem("Sonnet cap: \(formattedInt(MonitorConfig.weeklySonnetBillableTokenLimit)) billable tokens"))
            menu.addItem(disabledItem("Sonnet billable: \(formattedInt(snapshot.weeklySonnetUsage.billable)) tokens"))
            menu.addItem(disabledItem("Sonnet total: \(formattedInt(snapshot.weeklySonnetUsage.total)) tokens"))
            menu.addItem(disabledItem("Sessions: \(formattedInt(snapshot.weeklySessionCount))"))
            menu.addItem(disabledItem("Weekly reset: \(countdown(until: snapshot.weeklyResetAt))"))
            menu.addItem(disabledItem("Resets at: \(absoluteDateFormatter.string(from: snapshot.weeklyResetAt))"))
        }

        menu.addItem(.separator())
        if snapshot.dashboard == nil {
            menu.addItem(disabledItem("Scanned files: \(formattedInt(snapshot.scannedFileCount))"))
        }
        menu.addItem(disabledItem("Updated: \(absoluteDateFormatter.string(from: snapshot.generatedAt))"))
        menu.addItem(disabledItem("Source: \(snapshot.sourceDescription)"))
        menu.addItem(disabledItem(claudeStatusLine))

        let settings = settingsStore.load()
        let authStatus = dashboardAuthStatus(settings: settings)
        menu.addItem(disabledItem("Auth: \(authStatus)"))

        let authItem = NSMenuItem(title: "Dashboard Auth", action: nil, keyEquivalent: "")
        let authMenu = NSMenu(title: "Dashboard Auth")
        let profile = userProfile(from: settings)
        let dashboardModeEnabled = settings.dashboardAuthEnabled ?? false

        let setupWizardItem = NSMenuItem(title: "Setup Wizard...", action: #selector(runSetupWizardAction(_:)), keyEquivalent: "")
        setupWizardItem.target = self
        authMenu.addItem(setupWizardItem)

        let openUsagePageItem = NSMenuItem(title: "Open Claude Usage Page", action: #selector(openClaudeUsagePageAction(_:)), keyEquivalent: "")
        openUsagePageItem.target = self
        authMenu.addItem(openUsagePageItem)

        authMenu.addItem(.separator())

        let toggleTitle: String
        if dashboardModeEnabled {
            toggleTitle = "Disable Dashboard Auth (Use Cache-Only)"
        } else if profile == .api {
            toggleTitle = "Enable Dashboard Auth Mode"
        } else {
            toggleTitle = "Enable Dashboard Auth (Advanced)"
        }
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleDashboardAuthModeAction(_:)), keyEquivalent: "")
        toggleItem.target = self
        authMenu.addItem(toggleItem)

        switch profile {
        case .api:
            authMenu.addItem(disabledItem("Profile: API (Pay As You Go)"))
        case .planDashboard:
            authMenu.addItem(disabledItem("Profile: Plan (Dashboard Auth)"))
        case .planCache:
            authMenu.addItem(disabledItem("Profile: Plan (Cache-Only)"))
        case .unknown:
            authMenu.addItem(disabledItem(dashboardModeEnabled ? "Mode: dashboard auth enabled" : "Mode: cache-only"))
        }

        if profile == .api {
            authMenu.addItem(.separator())
            let updateItem = NSMenuItem(title: "Update API Auth", action: nil, keyEquivalent: "")
            let updateMenu = NSMenu(title: "Update API Auth")

            let autoExtractItem = NSMenuItem(title: "Auto Extract from Claude Desktop", action: #selector(autoExtractDashboardAuthAction(_:)), keyEquivalent: "")
            autoExtractItem.target = self
            updateMenu.addItem(autoExtractItem)

            let sessionKeyItem = NSMenuItem(title: "Enter Session Key...", action: #selector(enterSessionKeyAction(_:)), keyEquivalent: "")
            sessionKeyItem.target = self
            updateMenu.addItem(sessionKeyItem)

            let cookieHeaderItem = NSMenuItem(title: "Enter Cookie Header...", action: #selector(enterCookieHeaderAction(_:)), keyEquivalent: "")
            cookieHeaderItem.target = self
            updateMenu.addItem(cookieHeaderItem)

            let orgUUIDItem = NSMenuItem(title: "Set Org UUID...", action: #selector(enterOrgUUIDAction(_:)), keyEquivalent: "")
            orgUUIDItem.target = self
            updateMenu.addItem(orgUUIDItem)

            updateMenu.addItem(.separator())
            let clearItem = NSMenuItem(title: "Clear Saved API Auth", action: #selector(clearSavedDashboardAuthAction(_:)), keyEquivalent: "")
            clearItem.target = self
            clearItem.isEnabled = settings.sessionKey != nil || settings.cookieHeader != nil || settings.orgUUID != nil
            updateMenu.addItem(clearItem)

            updateItem.submenu = updateMenu
            authMenu.addItem(updateItem)
        } else if dashboardModeEnabled {
            authMenu.addItem(.separator())
            let reauthItem = NSMenuItem(title: "Re-auth from Claude Desktop", action: #selector(autoExtractDashboardAuthAction(_:)), keyEquivalent: "")
            reauthItem.target = self
            authMenu.addItem(reauthItem)

            let clearItem = NSMenuItem(title: "Clear Saved Dashboard Auth", action: #selector(clearSavedDashboardAuthAction(_:)), keyEquivalent: "")
            clearItem.target = self
            clearItem.isEnabled = settings.sessionKey != nil || settings.cookieHeader != nil || settings.orgUUID != nil
            authMenu.addItem(clearItem)
        }

        authItem.submenu = authMenu
        menu.addItem(authItem)

        if !dashboardModeEnabled {
            let calibrationItem = NSMenuItem(title: "Reset Calibration", action: nil, keyEquivalent: "")
            let calibrationMenu = NSMenu(title: "Reset Calibration")
            calibrationMenu.addItem(disabledItem("Local/cache mode only"))
            if let sessionCalibration = parsedStoredDate(settings.sessionResetCalibrationISO8601) {
                calibrationMenu.addItem(disabledItem("Session anchor: \(absoluteDateFormatter.string(from: sessionCalibration))"))
            }
            if let weeklyCalibration = parsedStoredDate(settings.weeklyResetCalibrationISO8601) {
                calibrationMenu.addItem(disabledItem("Weekly anchor: \(absoluteDateFormatter.string(from: weeklyCalibration))"))
            }
            calibrationMenu.addItem(.separator())

            let setSessionItem = NSMenuItem(title: "Set Session Reset Time...", action: #selector(setSessionResetCalibrationAction(_:)), keyEquivalent: "")
            setSessionItem.target = self
            calibrationMenu.addItem(setSessionItem)

            let setWeeklyItem = NSMenuItem(title: "Set Weekly Reset Time...", action: #selector(setWeeklyResetCalibrationAction(_:)), keyEquivalent: "")
            setWeeklyItem.target = self
            calibrationMenu.addItem(setWeeklyItem)

            calibrationMenu.addItem(.separator())
            let clearCalibrationsItem = NSMenuItem(title: "Clear Reset Calibration", action: #selector(clearResetCalibrationsAction(_:)), keyEquivalent: "")
            clearCalibrationsItem.target = self
            clearCalibrationsItem.isEnabled = settings.sessionResetCalibrationISO8601 != nil || settings.weeklyResetCalibrationISO8601 != nil
            calibrationMenu.addItem(clearCalibrationsItem)
            calibrationItem.submenu = calibrationMenu
            menu.addItem(calibrationItem)
        }

        menu.addItem(.separator())
        let startAtLoginState = startAtLoginManager.currentState()
        let startAtLoginItem = NSMenuItem(
            title: "Auto Start at Login",
            action: #selector(toggleStartAtLoginAction(_:)),
            keyEquivalent: ""
        )
        startAtLoginItem.target = self
        startAtLoginItem.state = startAtLoginState.enabled ? .on : .off
        startAtLoginItem.isEnabled = startAtLoginState.canToggle
        menu.addItem(startAtLoginItem)
        if let detail = startAtLoginState.detail {
            menu.addItem(disabledItem(detail))
        }

        menu.addItem(.separator())
        let updateTitle: String
        if let latest = latestAvailableVersion,
           isVersion(latest, greaterThan: currentAppVersion()) {
            updateTitle = "Update Available: v\(latest)..."
        } else {
            updateTitle = "Check for Updates..."
        }
        let updateItem = NSMenuItem(title: updateTitle, action: #selector(checkForUpdatesAction(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNowAction(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "Open Claude Data Folder", action: #selector(openDataFolderAction(_:)), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let claudeStatusItem = NSMenuItem(title: "Open Claude Status Page", action: #selector(openClaudeStatusPageAction(_:)), keyEquivalent: "")
        claudeStatusItem.target = self
        menu.addItem(claudeStatusItem)

        menu.addItem(.separator())
        menu.addItem(disabledItem("Built with \u{2665} by HopIT"))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func shortId(_ value: String) -> String {
        if value.count <= 12 {
            return value
        }
        return String(value.prefix(8)) + "..." + String(value.suffix(4))
    }

    private func countdown(until date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 {
            return "now"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    private func relativeFromNow(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func formattedInt(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func compact(_ value: Int) -> String {
        let absValue = abs(value)
        if absValue >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000.0)
        }
        if absValue >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000.0)
        }
        return "\(value)"
    }

    private func progressRatio(used: Int, limit: Int) -> Double {
        guard limit > 0 else { return 0.0 }
        let ratio = Double(used) / Double(limit)
        return max(0.0, min(1.0, ratio))
    }

    private func percentText(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100.0)
    }

    private func statusProgressImage(_ ratio: Double?) -> NSImage {
        let iconSize = NSSize(width: 14, height: 14)
        let image = NSImage(size: iconSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            context.saveGState()
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)

            let frame = rect.insetBy(dx: 1.5, dy: 1.5)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let radius = min(frame.width, frame.height) / 2.0
            let lineWidth: CGFloat = 1.5
            let fillRadius = max(0.0, radius - (lineWidth / 2.0))

            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(lineWidth)
            context.strokeEllipse(in: frame)

            if let ratio {
                let clamped = CGFloat(max(0.0, min(1.0, ratio)))
                if clamped > 0.0 {
                    context.setFillColor(NSColor.black.cgColor)

                    if clamped >= 0.999 {
                        context.fillEllipse(
                            in: CGRect(
                                x: center.x - fillRadius,
                                y: center.y - fillRadius,
                                width: fillRadius * 2.0,
                                height: fillRadius * 2.0
                            )
                        )
                    } else {
                        context.beginPath()
                        context.move(to: center)
                        context.addArc(
                            center: center,
                            radius: fillRadius,
                            startAngle: .pi / 2.0,
                            endAngle: (.pi / 2.0) - (clamped * 2.0 * .pi),
                            clockwise: true
                        )
                        context.closePath()
                        context.fillPath()
                    }
                }
            }

            context.restoreGState()
            return true
        }

        image.isTemplate = true
        return image
    }

    private func checkForUpdates(userInitiated: Bool) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true

        let currentVersion = currentAppVersion()
        var request = URLRequest(url: AppBrand.latestReleaseAPIURL)
        request.timeoutInterval = 10
        request.setValue("\(AppBrand.appName)/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }

            var foundVersion: String?
            var foundReleaseURL: URL?
            var checkError: String?
            var isUpToDate = false

            if let error {
                checkError = error.localizedDescription
            } else if let data {
                do {
                    let release = try JSONDecoder().decode(GitHubLatestRelease.self, from: data)
                    if release.draft || release.prerelease {
                        isUpToDate = true
                    } else {
                        let latestVersion = normalizeVersionTag(release.tagName)
                        if latestVersion.isEmpty {
                            checkError = "Latest release tag was empty."
                        } else if isVersion(latestVersion, greaterThan: currentVersion),
                                  let releaseURL = URL(string: release.htmlURL) {
                            foundVersion = latestVersion
                            foundReleaseURL = releaseURL
                        } else {
                            isUpToDate = true
                        }
                    }
                } catch {
                    checkError = "Unable to parse release metadata."
                }
            } else {
                checkError = "No update data returned by GitHub."
            }

            DispatchQueue.main.async {
                self.isCheckingForUpdates = false

                if let checkError {
                    if userInitiated {
                        self.showAlert(title: "Update Check Failed", message: checkError)
                    }
                    return
                }

                if let foundVersion, let foundReleaseURL {
                    self.latestAvailableVersion = foundVersion
                    self.latestReleaseURL = foundReleaseURL

                    let lastNotified = UserDefaults.standard.string(forKey: self.lastNotifiedVersionKey)
                    if userInitiated || lastNotified != foundVersion {
                        UserDefaults.standard.set(foundVersion, forKey: self.lastNotifiedVersionKey)
                        self.showUpdateAvailableAlert(version: foundVersion, releaseURL: foundReleaseURL)
                    }
                    if let snapshot = self.snapshot {
                        self.render(snapshot)
                    }
                    return
                }

                if isUpToDate {
                    self.latestAvailableVersion = nil
                    self.latestReleaseURL = nil
                    if userInitiated {
                        self.showAlert(title: "You're Up to Date", message: "UsageScout \(currentVersion) is the latest release.")
                    }
                    if let snapshot = self.snapshot {
                        self.render(snapshot)
                    }
                }
            }
        }.resume()
    }

    private func refreshClaudeStatus() {
        guard !isCheckingClaudeStatus else { return }
        guard let url = URL(string: "https://status.claude.com/api/v2/status.json") else { return }
        isCheckingClaudeStatus = true

        var request = URLRequest(url: url)
        request.timeoutInterval = MonitorConfig.claudeStatusRequestTimeoutSeconds
        request.setValue("\(AppBrand.appName)/\(currentAppVersion())", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }

            let line: String
            if error != nil {
                line = "Claude status: unavailable"
            } else if let data {
                if let payload = try? JSONDecoder().decode(ClaudeStatusResponse.self, from: data) {
                    let indicator = payload.status.indicator.lowercased()
                    let description = payload.status.description.trimmingCharacters(in: .whitespacesAndNewlines)
                    if indicator == "none" {
                        line = "Claude status: \(description)"
                    } else {
                        line = "Claude status: issue (\(description))"
                    }
                } else {
                    line = "Claude status: unavailable (parse failed)"
                }
            } else {
                line = "Claude status: unavailable"
            }

            DispatchQueue.main.async {
                self.isCheckingClaudeStatus = false
                self.claudeStatusLine = line
                if let snapshot = self.snapshot {
                    self.render(snapshot)
                }
            }
        }.resume()
    }

    private func currentAppVersion() -> String {
        let info = Bundle.main.infoDictionary
        if let short = info?["CFBundleShortVersionString"] as? String,
           !short.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return short
        }
        if let build = info?["CFBundleVersion"] as? String,
           !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return build
        }
        return "0.0.0"
    }

    private func normalizeVersionTag(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }

    private func versionParts(_ value: String) -> [Int] {
        let normalized = normalizeVersionTag(value)
        let parts = normalized
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { component -> Int in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
        if parts.isEmpty {
            return [0]
        }
        return parts
    }

    private func isVersion(_ lhs: String, greaterThan rhs: String) -> Bool {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l > r { return true }
            if l < r { return false }
        }
        return false
    }

    private func showUpdateAvailableAlert(version: String, releaseURL: URL) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "UsageScout v\(version) is available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    private func progressBar(_ ratio: Double, width: Int = 12) -> String {
        let clamped = max(0.0, min(1.0, ratio))
        let filled = Int((clamped * Double(width)).rounded())
        let empty = max(0, width - filled)
        return "[" + String(repeating: "█", count: filled) + String(repeating: "░", count: empty) + "]"
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func dashboardAuthStatus(settings: MonitorSettings) -> String {
        if (settings.dashboardAuthEnabled ?? false) == false {
            return "disabled (cache-only)"
        }

        let env = ProcessInfo.processInfo.environment
        if let fullCookie = env["CLAUDE_COOKIE_HEADER"]?.trimmingCharacters(in: .whitespacesAndNewlines), !fullCookie.isEmpty {
            return "env cookie header"
        }
        if let sessionKey = env["CLAUDE_SESSION_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionKey.isEmpty {
            return "env session key"
        }
        if settings.cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "saved cookie header"
        }
        if settings.sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "saved session key"
        }
        return "enabled, not configured"
    }

    private func userProfile(from settings: MonitorSettings) -> UserProfile {
        if let mode = settings.onboardingMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            switch mode {
            case "api":
                return .api
            case "plan_dashboard":
                return .planDashboard
            case "plan_cache":
                return .planCache
            default:
                break
            }
        }

        if settings.dashboardAuthEnabled ?? false {
            return .unknown
        }
        return .planCache
    }

    private func parsedStoredDate(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return iso8601StorageFormatter.date(from: value)
    }

    private func parseCalibrationDateInput(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let iso = iso8601StorageFormatter.date(from: trimmed) {
            return iso
        }

        for formatter in calibrationInputFormatters {
            if let parsed = formatter.date(from: trimmed) {
                return parsed
            }
        }

        return nil
    }

    private func promptForText(
        title: String,
        message: String,
        placeholder: String,
        defaultValue: String,
        secure: Bool
    ) -> String? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let fieldFrame = NSRect(x: 0, y: 0, width: 380, height: 24)
        let field: NSTextField = secure ? NSSecureTextField(frame: fieldFrame) : NSTextField(frame: fieldFrame)
        field.placeholderString = placeholder
        field.stringValue = defaultValue
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = MenuBarController()
app.delegate = delegate
app.run()
