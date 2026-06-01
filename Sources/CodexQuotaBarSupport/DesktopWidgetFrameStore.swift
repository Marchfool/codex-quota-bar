import CoreGraphics
import Foundation

package enum DesktopWidgetFrameStore {
    package static let defaultSize = CGSize(width: 396, height: 596)
    package static let minimumSize = CGSize(width: 360, height: 420)

    private static let xKey = "desktopWidgetFrameX"
    private static let yKey = "desktopWidgetFrameY"
    private static let widthKey = "desktopWidgetFrameWidth"
    private static let heightKey = "desktopWidgetFrameHeight"
    private static let rightMargin: CGFloat = 16
    private static let topMargin: CGFloat = 30

    package static func initialFrame(visibleFrame: CGRect, defaults: UserDefaults = .standard) -> CGRect {
        if let storedFrame = storedFrame(defaults: defaults) {
            return clampedFrame(storedFrame, visibleFrame: visibleFrame)
        }

        return clampedFrame(defaultFrame(visibleFrame: visibleFrame), visibleFrame: visibleFrame)
    }

    package static func save(_ frame: CGRect, defaults: UserDefaults = .standard) {
        defaults.set(Double(frame.origin.x), forKey: xKey)
        defaults.set(Double(frame.origin.y), forKey: yKey)
        defaults.set(Double(frame.width), forKey: widthKey)
        defaults.set(Double(frame.height), forKey: heightKey)
    }

    package static func clampedFrame(_ frame: CGRect, visibleFrame: CGRect) -> CGRect {
        let width = min(max(frame.width, minimumSize.width), visibleFrame.width)
        let height = min(max(frame.height, minimumSize.height), visibleFrame.height)
        let x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - height)

        return snappedFrame(CGRect(x: x, y: y, width: width, height: height))
    }

    private static func snappedFrame(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
    }

    private static func defaultFrame(visibleFrame: CGRect) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - defaultSize.width - rightMargin,
            y: visibleFrame.maxY - defaultSize.height - topMargin,
            width: defaultSize.width,
            height: defaultSize.height
        )
    }

    private static func storedFrame(defaults: UserDefaults) -> CGRect? {
        guard defaults.object(forKey: xKey) != nil,
              defaults.object(forKey: yKey) != nil,
              defaults.object(forKey: widthKey) != nil,
              defaults.object(forKey: heightKey) != nil
        else {
            return nil
        }

        return CGRect(
            x: CGFloat(defaults.double(forKey: xKey)),
            y: CGFloat(defaults.double(forKey: yKey)),
            width: CGFloat(defaults.double(forKey: widthKey)),
            height: CGFloat(defaults.double(forKey: heightKey))
        )
    }
}
