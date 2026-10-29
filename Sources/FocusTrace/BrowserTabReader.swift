import AppKit
import TrackingCore

/// Serializes blocking Apple Events away from the main actor. Full URLs are
/// classified here and never leave this boundary or enter persistent storage.
final class BrowserTabReader: Sendable {
    struct Target: Sendable {
        let browser: Browser
        let processIdentifier: pid_t

        func matches(bundleIdentifier: String?, processIdentifier: pid_t?) -> Bool {
            bundleIdentifier == browser.bundleID && processIdentifier == self.processIdentifier
        }
    }

    struct Result: Sendable {
        let source: Source?
        let errorCode: Int?
    }

    private let queue = DispatchQueue(label: "FocusTrace.browser", qos: .utility)
    private let sendEvent: @Sendable (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor

    init(sendEvent: @escaping @Sendable (NSAppleEventDescriptor) throws -> NSAppleEventDescriptor = {
        try $0.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2)
    }) {
        self.sendEvent = sendEvent
    }

    func read(_ target: Target, sources: [Source]) async -> Result {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let reply = try self.sendEvent(Self.urlEvent(for: target))
                    if let error = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, error != 0 {
                        continuation.resume(returning: Self.failure(Int(error)))
                    } else if let value = reply.paramDescriptor(forKeyword: keyDirectObject) {
                        let source = value.stringValue.flatMap { SourceCatalog.website(url: $0, sources: sources) }
                        continuation.resume(returning: Result(source: source, errorCode: nil))
                    } else {
                        continuation.resume(returning: Self.failure(Int(errAECoercionFail)))
                    }
                } catch {
                    continuation.resume(returning: Self.failure((error as NSError).code))
                }
            }
        }
    }

    private static func failure(_ code: Int) -> Result {
        // A window/tab can disappear between sampling the foreground app and reading it.
        Result(source: nil, errorCode: code == errAENoSuchObject ? nil : code)
    }

    private static func urlEvent(for target: Target) -> NSAppleEventDescriptor {
        // Bundle-ID addressing can resolve to an automation instance of the same browser.
        // Address the captured foreground PID directly, with no launch or bundle fallback.
        let event = NSAppleEventDescriptor(eventClass: kAECoreSuite, eventID: kAEGetData,
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: target.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let window = object(want: cWindow, form: OSType(formAbsolutePosition),
                            key: NSAppleEventDescriptor(int32: 1), container: .null())
        // Property codes from the Chrome and Safari scripting dictionaries.
        let tab = property(target.browser == .chrome ? 0x61635461 : 0x63546162, of: window) // acTa / cTab
        let url = property(target.browser == .chrome ? 0x55524C20 : 0x7055524C, of: tab) // URL  / pURL
        event.setParam(url, forKeyword: keyDirectObject)
        return event
    }

    private static func property(_ code: OSType, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        object(want: cProperty, form: OSType(formPropertyID), key: NSAppleEventDescriptor(typeCode: code), container: container)
    }

    private static func object(want: OSType, form: OSType, key: NSAppleEventDescriptor,
                               container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: typeObjectSpecifier)!
    }
}
