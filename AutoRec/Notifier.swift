import AppKit
import Foundation
import UserNotifications

/// A message the owner has to see while the call is still going.
///
/// Everything MemorAI noticed about a broken recording used to go to
/// memorai.log and nowhere else — which is to say nobody saw it until the
/// call was over and the half that was lost could no longer be asked for
/// again. A system notification with a sound is the least that reaches a
/// person in the middle of a call.
///
/// User Notifications first; if the system refuses (permission denied, an
/// unsigned dev build) the message still goes out through `osascript`'s
/// `display notification`, and a sound plays either way.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var authorized: Bool?

    /// Ask once at launch, not in the middle of the first broken call.
    func prepare() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.authorized = granted
            if let error {
                log("[Notifier] Уведомления недоступны: \(error.localizedDescription) — буду показывать через osascript")
            } else if !granted {
                log("[Notifier] Уведомления запрещены в настройках — буду показывать через osascript")
            }
        }
    }

    /// `id` groups repeats: a newer message with the same id replaces the
    /// older one in Notification Center instead of stacking up.
    func post(title: String, body: String, id: String) {
        log("[Notifier] \(title): \(body)")
        DispatchQueue.main.async { NSSound(named: "Sosumi")?.play() }

        guard authorized != false else { return fallback(title: title, body: body) }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            log("[Notifier] Не удалось показать уведомление (\(error.localizedDescription)) — показываю через osascript")
            self?.fallback(title: title, body: body)
        }
    }

    private func fallback(title: String, body: String) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title)) sound name \"Sosumi\""]
        do { try process.run() } catch {
            log("[Notifier] osascript тоже не смог: \(error.localizedDescription)")
        }
    }

    // An accessory app is rarely frontmost, but when it is (Settings open),
    // the banner must still show.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
