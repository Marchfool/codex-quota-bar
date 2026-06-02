import Foundation
import LocalAuthentication
import Security

public protocol SecretStore: Sendable {
    func set(_ value: String, account: String) throws
    func get(account: String) throws -> String?
    func get(account: String, allowsUserInteraction: Bool) throws -> String?
    func delete(account: String) throws
}

public enum KeychainError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case userInteractionRequired
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            return "Keychain returned status \(status)."
        case .userInteractionRequired:
            return "Keychain requires user approval."
        case .timedOut:
            return "Keychain request timed out."
        }
    }
}

public extension SecretStore {
    func get(account: String, allowsUserInteraction: Bool) throws -> String? {
        try get(account: account)
    }
}

public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service: String
    private let securityTimeout: TimeInterval

    public init(service: String = "com.codexquotabar.secrets", securityTimeout: TimeInterval = 6) {
        self.service = service
        self.securityTimeout = securityTimeout
    }

    public func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        switch runSecurityDelete(account: account, timeout: securityTimeout) {
        case .success:
            switch runSecuritySet(value, account: account, timeout: securityTimeout) {
            case .success:
                return
            case .failedToStart, .timedOut, .unexpected:
                try setInProcess(data, query: query)
            }
        case .failedToStart, .timedOut, .unexpected:
            try setInProcess(data, query: query)
        }
    }

    public func get(account: String) throws -> String? {
        try get(account: account, allowsUserInteraction: true)
    }

    public func get(account: String, allowsUserInteraction: Bool) throws -> String? {
        // Read via the /usr/bin/security CLI instead of an in-process SecItemCopyMatching.
        // The keychain ACL is keyed by the *accessing* binary; /usr/bin/security is a stable,
        // already-trusted Apple binary, so once approved it never re-prompts — even across app
        // rebuilds/restarts (unlike the self-signed app binary, whose trust is unstable and
        // triggers scattered authorization dialogs at launch). The returned secret is identical.
        // Keep both interactive and non-interactive refreshes on this path; the timeout below is
        // the guard against hangs, while avoiding the app-binary ACL prompt is the guard against
        // restart-time keychain popups.
        switch runSecurityGet(account: account, timeout: securityTimeout) {
        case .success(let result):
            if result.terminationStatus == 0 {
                let value = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (value?.isEmpty == false) ? value : nil
            }
            // `security` exits non-zero when the item is absent (errSecItemNotFound == 44) — treat as nil.
            if result.terminationStatus == 44 { return nil }
            throw KeychainError.unexpectedStatus(result.terminationStatus)
        case .failedToStart:
            // Fall back to in-process read if the CLI cannot be spawned.
            return try inProcessGet(account: account, allowsUserInteraction: allowsUserInteraction)
        case .timedOut:
            throw KeychainError.timedOut
        }
    }

    private func inProcessGet(account: String, allowsUserInteraction: Bool) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if !allowsUserInteraction && (status == errSecInteractionNotAllowed || status == errSecAuthFailed) {
            throw KeychainError.userInteractionRequired
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func setInProcess(_ data: Data, query: [String: Any]) throws {
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(updateStatus) }
            return
        }
        throw KeychainError.unexpectedStatus(addStatus)
    }

    private struct SecurityGetResult {
        var terminationStatus: Int32
        var stdout: Data
    }

    private enum SecurityGetOutcome {
        case success(SecurityGetResult)
        case failedToStart
        case timedOut
    }

    private enum SecuritySetOutcome {
        case success
        case failedToStart
        case timedOut
        case unexpected(OSStatus)
    }

    private enum SecurityDeleteOutcome {
        case success
        case failedToStart
        case timedOut
        case unexpected(OSStatus)
    }

    private func runSecuritySet(_ value: String, account: String, timeout: TimeInterval) -> SecuritySetOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // The interactive -w prompt truncates long OAuth tokens; pass the value directly so
        // security creates an item that it can later read without per-app ACL prompts.
        process.arguments = [
            "add-generic-password",
            "-s", service,
            "-a", account,
            "-w", value,
            "-T", "/usr/bin/security"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        let terminationStatus = LockedBox<Int32?>(nil)
        process.terminationHandler = { proc in
            terminationStatus.set(proc.terminationStatus)
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return .failedToStart
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            return .timedOut
        }

        guard let status = terminationStatus.get() else {
            return .failedToStart
        }
        return status == 0 ? .success : .unexpected(status)
    }

    private func runSecurityDelete(account: String, timeout: TimeInterval) -> SecurityDeleteOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "delete-generic-password",
            "-s", service,
            "-a", account
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        let terminationStatus = LockedBox<Int32?>(nil)
        process.terminationHandler = { proc in
            terminationStatus.set(proc.terminationStatus)
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return .failedToStart
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            return .timedOut
        }

        guard let status = terminationStatus.get() else {
            return .failedToStart
        }
        return status == 0 || status == 44 ? .success : .unexpected(status)
    }

    private func runSecurityGet(account: String, timeout: TimeInterval) -> SecurityGetOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<SecurityGetResult?>(nil)

        process.terminationHandler = { proc in
            let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
            result.set(SecurityGetResult(terminationStatus: proc.terminationStatus, stdout: stdout))
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return .failedToStart
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            return .timedOut
        }

        let completedResult = result.get()
        guard let completedResult else {
            return .failedToStart
        }
        return .success(completedResult)
    }
}
