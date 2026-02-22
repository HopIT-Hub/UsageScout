import AppKit
import CommonCrypto
import Foundation
import Security
import ServiceManagement
import SQLite3

struct AppBrand {
    static let appName = "UsageScout"
    static let companyName = "HopIT"
    static let settingsFolderName = "UsageScout"
    static let legacySettingsFolderName = "ClaudeMonitor"
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
    var startAtLoginEnabled: Bool?
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
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow
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
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow
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
        if let dashboard = fetchDashboardUsage() {
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

    private func collectLocalSnapshot(now: Date) -> UsageSnapshot {
        let sourceRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        let weekWindow = weeklyWindow(now: now)
        let files = candidateJSONLFiles(
            sourceRoot: sourceRoot,
            weeklyStart: weekWindow.start
        )

        var sessions: [String: MutableSession] = [:]
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

                if sessions[event.sessionId] == nil {
                    sessions[event.sessionId] = MutableSession(
                        id: event.sessionId,
                        firstEvent: event.timestamp,
                        lastEvent: event.timestamp
                    )
                }

                guard var session = sessions[event.sessionId] else { continue }
                session.absorb(
                    timestamp: event.timestamp,
                    usage: normalizedUsage,
                    countsAsMessage: event.countsAsMessage
                )
                sessions[event.sessionId] = session

                if event.timestamp >= weekWindow.start && event.timestamp < weekWindow.nextReset {
                    weeklyAllUsage.add(normalizedUsage)
                    if let model = event.model?.lowercased(), model.contains("sonnet") {
                        weeklySonnetUsage.add(normalizedUsage)
                    }
                }
            }
        }

        let sessionSummaries = sessions.values.map { $0.toSummary() }
        let currentSession = sessionSummaries.max(by: { $0.lastEvent < $1.lastEvent })
        let sessionResetAt = currentSession.map { nextSessionReset(anchor: $0.firstEvent, now: now) }
        let weeklySessionCount = sessionSummaries.filter {
            $0.lastEvent >= weekWindow.start && $0.firstEvent < weekWindow.nextReset
        }.count

        return UsageSnapshot(
            generatedAt: now,
            session: currentSession,
            sessionResetAt: sessionResetAt,
            weeklyAllUsage: weeklyAllUsage,
            weeklySonnetUsage: weeklySonnetUsage,
            weeklySessionCount: weeklySessionCount,
            weeklyStart: weekWindow.start,
            weeklyResetAt: weekWindow.nextReset,
            scannedFileCount: files.count,
            sourcePath: sourceRoot.path,
            dashboard: nil,
            sourceDescription: "Local CLI logs (approximate)"
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

    private func candidateJSONLFiles(sourceRoot: URL, weeklyStart: Date) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var candidates: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                continue
            }
            candidates.append((fileURL, values.contentModificationDate ?? .distantPast))
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

        guard let sessionId = object["sessionId"] as? String,
              let timestampString = object["timestamp"] as? String,
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
        guard let message = object["message"] as? [String: Any],
              let usageDict = message["usage"] as? [String: Any] else {
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

    private func weeklyWindow(now: Date) -> (start: Date, nextReset: Date) {
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
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settingsStore = MonitorSettingsStore()
    private let startAtLoginManager = StartAtLoginManager()
    private lazy var service = ClaudeUsageService(settingsStore: settingsStore)
    private let queue = DispatchQueue(label: "\(AppBrand.appName).Refresh", qos: .utility)

    private var refreshTimer: Timer?
    private var snapshot: UsageSnapshot?

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem.button?.title = "\(AppBrand.appName) --"
        applySavedStartAtLoginPreference()
        refreshData()

        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: MonitorConfig.refreshIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            self?.refreshData()
        }
    }

    @objc private func refreshNowAction(_ sender: Any?) {
        refreshData()
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
                message: reason
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
            statusItem.button?.title = "\(progressCircle(sessionRatio)) \(percentText(sessionRatio))"
        } else {
            statusItem.button?.title = "○ --"
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

        let settings = settingsStore.load()
        let authStatus = dashboardAuthStatus(settings: settings)
        menu.addItem(disabledItem("Auth: \(authStatus)"))

        let authItem = NSMenuItem(title: "Dashboard Auth", action: nil, keyEquivalent: "")
        let authMenu = NSMenu(title: "Dashboard Auth")

        let autoExtractItem = NSMenuItem(title: "Auto Extract from Claude Desktop", action: #selector(autoExtractDashboardAuthAction(_:)), keyEquivalent: "")
        autoExtractItem.target = self
        authMenu.addItem(autoExtractItem)

        let sessionKeyItem = NSMenuItem(title: "Enter Session Key...", action: #selector(enterSessionKeyAction(_:)), keyEquivalent: "")
        sessionKeyItem.target = self
        authMenu.addItem(sessionKeyItem)

        let cookieHeaderItem = NSMenuItem(title: "Enter Cookie Header...", action: #selector(enterCookieHeaderAction(_:)), keyEquivalent: "")
        cookieHeaderItem.target = self
        authMenu.addItem(cookieHeaderItem)

        let orgUUIDItem = NSMenuItem(title: "Set Org UUID (Optional)...", action: #selector(enterOrgUUIDAction(_:)), keyEquivalent: "")
        orgUUIDItem.target = self
        authMenu.addItem(orgUUIDItem)

        authMenu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear Saved Auth", action: #selector(clearSavedDashboardAuthAction(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = settings.sessionKey != nil || settings.cookieHeader != nil || settings.orgUUID != nil
        authMenu.addItem(clearItem)

        authItem.submenu = authMenu
        menu.addItem(authItem)

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
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNowAction(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openItem = NSMenuItem(title: "Open Claude Data Folder", action: #selector(openDataFolderAction(_:)), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

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

    private func progressCircle(_ ratio: Double) -> String {
        let glyphs = ["○", "◔", "◑", "◕", "●"]
        let clamped = max(0.0, min(1.0, ratio))
        let index = Int((clamped * Double(glyphs.count - 1)).rounded())
        return glyphs[index]
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
        return "not configured (local fallback)"
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
