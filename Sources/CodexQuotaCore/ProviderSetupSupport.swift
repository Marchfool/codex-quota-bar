import Foundation

public enum ProviderSetupState: String, Codable, Sendable {
    case ready
    case notInstalled
    case notLoggedIn
    case missingDependency
    case fetchFailed
    case configurationRequired
}

public extension APIBalanceSnapshot {
    static func setupPlaceholder(
        balance: String,
        note: String,
        setupState: ProviderSetupState,
        actionHint: String,
        errorCode: String? = nil,
        usedPercent: Int = 100,
        status: QuotaStatus = .warning,
        extras: [String: String] = [:]
    ) -> APIBalanceSnapshot {
        var merged = extras
        merged["setupState"] = setupState.rawValue
        merged["actionHint"] = actionHint
        if let errorCode {
            merged["errorCode"] = errorCode
        }
        return APIBalanceSnapshot(
            balance: balance,
            usedPercent: usedPercent,
            status: status,
            note: note,
            extras: merged
        )
    }

    var setupState: ProviderSetupState? {
        guard let raw = extras["setupState"] else { return nil }
        return ProviderSetupState(rawValue: raw)
    }

    var actionHint: String? {
        extras["actionHint"]
    }

    var errorCode: String? {
        extras["errorCode"]
    }

    func markedReady(actionHint: String? = nil, extras additionalExtras: [String: String] = [:]) -> APIBalanceSnapshot {
        var copy = self
        copy.extras["setupState"] = ProviderSetupState.ready.rawValue
        if let actionHint {
            copy.extras["actionHint"] = actionHint
        }
        for (key, value) in additionalExtras {
            copy.extras[key] = value
        }
        return copy
    }
}

public enum ClaudeFetchError: Error, LocalizedError, Equatable, Sendable {
    case notInstalled
    case notLoggedIn
    case safeStorageMissing
    case cookieDatabaseMissing
    case pythonUnavailable
    case cryptographyMissing
    case cookieDecryptFailed
    case unsupportedCookieSchema
    case timedOut
    case networkFailure
    case webFetchFailed(String)

    public var errorDescription: String? {
        snapshot.note
    }

    public var snapshot: APIBalanceSnapshot {
        switch self {
        case .notInstalled:
            return .setupPlaceholder(
                balance: "Claude Desktop",
                note: "未检测到 Claude Desktop",
                setupState: .notInstalled,
                actionHint: "安装 Claude Desktop 并完成登录后刷新",
                errorCode: "claude_not_installed"
            )
        case .notLoggedIn:
            return .setupPlaceholder(
                balance: "等待登录",
                note: "请先登录 Claude Desktop",
                setupState: .notLoggedIn,
                actionHint: "打开 Claude Desktop 并确认已登录 claude.ai",
                errorCode: "claude_not_logged_in"
            )
        case .safeStorageMissing:
            return .setupPlaceholder(
                balance: "等待授权",
                note: "未找到 Claude Safe Storage",
                setupState: .notLoggedIn,
                actionHint: "重新打开 Claude Desktop 完成一次登录后再刷新",
                errorCode: "claude_safe_storage_missing"
            )
        case .cookieDatabaseMissing:
            return .setupPlaceholder(
                balance: "等待初始化",
                note: "未找到 Claude 本地会话数据库",
                setupState: .notLoggedIn,
                actionHint: "启动 Claude Desktop 并进入主界面一次后刷新",
                errorCode: "claude_cookie_db_missing"
            )
        case .pythonUnavailable:
            return .setupPlaceholder(
                balance: "缺少依赖",
                note: "系统 Python 不可用",
                setupState: .missingDependency,
                actionHint: "确保 macOS 自带 Python 可运行后再刷新",
                errorCode: "python_unavailable"
            )
        case .cryptographyMissing:
            return .setupPlaceholder(
                balance: "缺少依赖",
                note: "缺少 Python cryptography 依赖",
                setupState: .missingDependency,
                actionHint: "为 /usr/bin/python3 安装 cryptography 后再刷新",
                errorCode: "python_cryptography_missing"
            )
        case .cookieDecryptFailed:
            return .setupPlaceholder(
                balance: "读取失败",
                note: "Claude 登录态解密失败",
                setupState: .fetchFailed,
                actionHint: "重新登录 Claude Desktop；若仍失败，可能是本地 Cookie 结构已变更",
                errorCode: "claude_cookie_decrypt_failed"
            )
        case .unsupportedCookieSchema:
            return .setupPlaceholder(
                balance: "读取失败",
                note: "Claude 本地登录态结构暂不支持",
                setupState: .fetchFailed,
                actionHint: "升级应用后重试，或重新登录 Claude Desktop",
                errorCode: "claude_cookie_schema_unsupported"
            )
        case .timedOut:
            return .setupPlaceholder(
                balance: "请求超时",
                note: "Claude 余额请求超时",
                setupState: .fetchFailed,
                actionHint: "检查网络后重试",
                errorCode: "claude_request_timed_out"
            )
        case .networkFailure:
            return .setupPlaceholder(
                balance: "网络异常",
                note: "Claude 余额请求失败",
                setupState: .fetchFailed,
                actionHint: "检查网络连接后重试",
                errorCode: "claude_network_failure"
            )
        case .webFetchFailed(let message):
            return .setupPlaceholder(
                balance: "请求失败",
                note: message,
                setupState: .fetchFailed,
                actionHint: "稍后重试；若持续失败，请重新登录 Claude Desktop",
                errorCode: "claude_web_fetch_failed"
            )
        }
    }
}
