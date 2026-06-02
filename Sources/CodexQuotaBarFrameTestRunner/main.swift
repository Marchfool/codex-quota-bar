import CodexQuotaBarSupport
import CoreGraphics
import Foundation

@main
struct CodexQuotaBarFrameTestRunner {
    static func main() throws {
        clampedFrameRespectsMinimumSizeAndVisibleFrame()
        initialFrameUsesDefaultSizeNearTopRightWhenNothingIsStored()
        initialFrameRestoresSavedFrame()
        claudeCookieDomainFilterOnlyAllowsClaudeHosts()
        print("All CodexQuotaBar frame tests passed.")
    }

    private static func clampedFrameRespectsMinimumSizeAndVisibleFrame() {
        let restored = CGRect(x: 900, y: 740, width: 100, height: 100)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let frame = DesktopWidgetFrameStore.clampedFrame(restored, visibleFrame: visibleFrame)

        expect(frame.width == 360, "expected width to clamp to minimum")
        expect(frame.height == 420, "expected height to clamp to minimum")
        expect(frame.maxX == visibleFrame.maxX, "expected frame to fit visible maxX")
        expect(frame.maxY == visibleFrame.maxY, "expected frame to fit visible maxY")
    }

    private static func initialFrameUsesDefaultSizeNearTopRightWhenNothingIsStored() {
        let defaults = isolatedDefaults()
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

        let frame = DesktopWidgetFrameStore.initialFrame(visibleFrame: visibleFrame, defaults: defaults)

        expect(frame.width == DesktopWidgetFrameStore.defaultSize.width, "expected default width")
        expect(frame.height == DesktopWidgetFrameStore.defaultSize.height, "expected default height")
        expect(frame.maxX == visibleFrame.maxX - 16, "expected default frame near right edge")
        expect(frame.maxY == visibleFrame.maxY - 30, "expected default frame near top edge")
    }

    private static func initialFrameRestoresSavedFrame() {
        let defaults = isolatedDefaults()
        let visibleFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let saved = CGRect(x: 120, y: 140, width: 420, height: 520)

        DesktopWidgetFrameStore.save(saved, defaults: defaults)
        let frame = DesktopWidgetFrameStore.initialFrame(visibleFrame: visibleFrame, defaults: defaults)

        expect(frame == saved, "expected saved frame to restore unchanged when visible")
    }

    private static func claudeCookieDomainFilterOnlyAllowsClaudeHosts() {
        expect(ClaudeCookieDomainFilter.isAllowedDomain("claude.ai"), "expected apex Claude domain")
        expect(ClaudeCookieDomainFilter.isAllowedDomain(".claude.ai"), "expected cookie domain form")
        expect(ClaudeCookieDomainFilter.isAllowedDomain("console.claude.ai"), "expected Claude subdomain")
        expect(!ClaudeCookieDomainFilter.isAllowedDomain("evilclaude.ai"), "expected suffix lookalike to be rejected")
        expect(!ClaudeCookieDomainFilter.isAllowedDomain("claude.ai.evil.example"), "expected superdomain lookalike to be rejected")
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suiteName = "CodexQuotaBarFrameTestRunner.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("expected isolated defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
