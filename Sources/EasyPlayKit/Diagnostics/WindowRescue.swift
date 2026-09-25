import Foundation
import CoreGraphics
import ApplicationServices

/// Brings a game's window back onto the screen when Wine puts it outside it.
///
/// Wine occasionally places a window at coordinates no display covers — on this
/// Mac, Wine 11 opened TrackMania's network dialog at x = −2577 on a 1470-point
/// screen. The game is running and waiting for a click on a window nobody can
/// see or reach, and every recovery a user would try (clicking the Dock icon,
/// Mission Control, moving the mouse to the edge) fails, because the window is
/// not merely behind something — it is nowhere.
///
/// macOS has no way to move another app's window except the accessibility API,
/// which needs the user's permission. So this reports what it found either way,
/// and moves the window only when EasyPlay has been trusted.
public enum WindowRescue {

    public struct Finding {
        public let title: String
        public let frame: CGRect
        /// Where the window was moved to, or nil when it could not be moved.
        public let movedTo: CGPoint?
        /// Why it wasn't moved, when it wasn't.
        public let blockedReason: String?
    }

    /// Is this window somewhere no display covers?
    ///
    /// "Off-screen" means no overlap at all with any display. A window hanging
    /// half off the bottom is normal and is left alone; one whose every corner
    /// is outside every screen is a bug the user cannot work around.
    public static func isOffScreen(_ frame: CGRect, screens: [CGRect]) -> Bool {
        guard !screens.isEmpty, frame.width > 0, frame.height > 0 else { return false }
        return !screens.contains { $0.intersects(frame) }
    }

    /// Where to put a rescued window: centred on the main display, but never
    /// with its title bar above the top of the screen, since a window you cannot
    /// grab is barely better than one you cannot see.
    public static func rescuePosition(for frame: CGRect, on screen: CGRect) -> CGPoint {
        let x = screen.midX - frame.width / 2
        let y = screen.midY - frame.height / 2
        return CGPoint(x: max(screen.minX, x), y: max(screen.minY, y))
    }

    /// The frames of the displays, in the top-left origin coordinates that both
    /// the window list and the accessibility API use.
    public static func screenFrames() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.map { CGDisplayBounds($0) }
    }

    /// Looks at every window belonging to `pids` and moves the stranded ones back.
    ///
    /// Only windows of the processes EasyPlay launched are touched, and only
    /// ones that are genuinely off-screen; nothing else on the Mac is read or
    /// moved.
    @discardableResult
    public static func rescueWindows(ofProcesses pids: [Int32]) -> [Finding] {
        let screens = screenFrames()
        guard let main = screens.first, !pids.isEmpty else { return [] }

        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }

        var findings: [Finding] = []
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  isOffScreen(frame, screens: screens) else { continue }

            let title = window[kCGWindowName as String] as? String ?? "a window"
            let target = rescuePosition(for: frame, on: main)

            guard AXIsProcessTrusted() else {
                findings.append(Finding(title: title, frame: frame, movedTo: nil,
                                        blockedReason: "EasyPlay needs Accessibility permission to move another app's window. Grant it in System Settings › Privacy & Security › Accessibility."))
                continue
            }

            let moved = move(pid: pid, matching: frame, to: target)
            findings.append(Finding(title: title, frame: frame,
                                    movedTo: moved ? target : nil,
                                    blockedReason: moved ? nil : "The window refused to move."))
        }
        return findings
    }

    /// Moves the window of `pid` whose position matches `frame`.
    private static func move(pid: Int32, matching frame: CGRect, to point: CGPoint) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }

        for window in windows {
            var positionValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
                  let positionValue else { continue }
            var position = CGPoint.zero
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
            // The same process can own several windows; only the stranded one
            // should move, so match on where it currently is.
            guard abs(position.x - frame.origin.x) < 2, abs(position.y - frame.origin.y) < 2 else { continue }

            var destination = point
            guard let newValue = AXValueCreate(.cgPoint, &destination) else { continue }
            return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, newValue) == .success
        }
        return false
    }
}
