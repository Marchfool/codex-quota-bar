import Foundation

package enum ClaudeCookieDomainFilter {
    package static let allowedBaseDomain = "claude.ai"

    package static func isAllowedDomain(_ domain: String, baseDomain: String = allowedBaseDomain) -> Bool {
        let host = normalizedHost(domain)
        let base = normalizedHost(baseDomain)
        guard !host.isEmpty, !base.isEmpty else { return false }
        return host == base || host.hasSuffix(".\(base)")
    }

    private static func normalizedHost(_ value: String) -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasPrefix(".") {
            host.removeFirst()
        }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host
    }
}
