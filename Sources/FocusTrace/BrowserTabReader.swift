import AppKit
import TrackingCore

/// Serializes blocking Apple Events away from the main actor. Full URLs are
/// classified here and never leave this boundary or enter persistent storage.
final class BrowserTabReader {
    struct Result: Sendable {
        let source: Source?
        let errorCode: Int?
    }

    private let queue = DispatchQueue(label: "FocusTrace.browser", qos: .utility)

    func read(_ browser: Browser, sources: [Source]) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                let script = """
                with timeout of 2 seconds
                    tell application id "\(browser.bundleID)"
                        if (count of windows) is 0 then return ""
                        return URL of \(browser == .chrome ? "active tab" : "current tab") of front window
                    end tell
                end timeout
                """
                var error: NSDictionary?
                let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                let source = result?.stringValue.flatMap { SourceCatalog.website(url: $0, sources: sources) }
                continuation.resume(returning: Result(source: source,
                    errorCode: error?[NSAppleScript.errorNumber] as? Int))
            }
        }
    }
}
