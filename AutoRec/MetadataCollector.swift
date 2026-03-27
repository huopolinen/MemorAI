import AppKit
import ApplicationServices

class MetadataCollector {

    func activeAppBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func collect() -> [String: Any] {
        let app = NSWorkspace.shared.frontmostApplication
        var result: [String: Any] = [
            "app_name": app?.localizedName ?? "",
            "app_bundle_id": app?.bundleIdentifier ?? "",
        ]

        if let title = windowTitle(for: app) {
            result["window_title"] = title
        }

        if let url = browserURL(for: app) {
            result["url"] = url
        }

        return result
    }

    // MARK: - Window Title via Accessibility API

    private func windowTitle(for app: NSRunningApplication?) -> String? {
        guard let pid = app?.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(pid)

        var window: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success else {
            return nil
        }

        var title: AnyObject?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else {
            return nil
        }
        return title as? String
    }

    // MARK: - Browser URL

    private func browserURL(for app: NSRunningApplication?) -> String? {
        guard let bundleId = app?.bundleIdentifier else { return nil }
        let browsers = [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
        ]
        guard browsers.contains(bundleId) else { return nil }

        let axApp = AXUIElementCreateApplication(app!.processIdentifier)

        // Try AXDocument on focused window (works for Chrome-based browsers)
        var window: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success {
            var doc: AnyObject?
            if AXUIElementCopyAttributeValue(window as! AXUIElement, "AXDocument" as CFString, &doc) == .success,
               let urlString = doc as? String {
                return urlString
            }
        }

        // Fallback: search for address bar text field
        if let window = window {
            return findURLField(in: window as! AXUIElement, depth: 0)
        }

        return nil
    }

    private func findURLField(in element: AXUIElement, depth: Int) -> String? {
        if depth > 6 { return nil }

        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)

        if let roleStr = role as? String, roleStr == kAXTextFieldRole as String {
            var val: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &val) == .success,
               let str = val as? String,
               str.contains("."), !str.contains(" ") {
                return str
            }
        }

        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let arr = children as? [AXUIElement] else { return nil }

        for child in arr.prefix(20) {
            if let url = findURLField(in: child, depth: depth + 1) {
                return url
            }
        }
        return nil
    }
}
