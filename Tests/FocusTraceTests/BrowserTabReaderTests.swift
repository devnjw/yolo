import AppKit
import XCTest
import TrackingCore
@testable import FocusTrace

final class BrowserTabReaderTests: XCTestCase {
    func testSameBrowserInstancesAreAddressedSeparately() async {
        let userPID: pid_t = 101
        let automationPID: pid_t = 202
        let reader = BrowserTabReader { event in
            let address = try XCTUnwrap(event.attributeDescriptor(forKeyword: keyAddressAttr))
            XCTAssertEqual(address.descriptorType, DescType(typeKernelProcessID))
            // Model the incident: the user's Chrome has YouTube; automation has a blank tab.
            let isUser = address.data == NSAppleEventDescriptor(processIdentifier: userPID).data
            XCTAssertTrue(isUser || address.data == NSAppleEventDescriptor(processIdentifier: automationPID).data)
            return Self.reply(value: NSAppleEventDescriptor(string: isUser
                ? "https://www.youtube.com/watch?v=private-video-id" : "about:blank"))
        }
        let user = await reader.read(.init(browser: .chrome, processIdentifier: userPID), sources: Source.defaults)
        XCTAssertEqual(user.source?.id, .youtube)
        XCTAssertEqual(user.source?.identifier, "youtube.com")
        XCTAssertNil(user.errorCode)
        let automation = await reader.read(.init(browser: .chrome, processIdentifier: automationPID), sources: [])
        XCTAssertNil(automation.source)
        XCTAssertNil(automation.errorCode)
    }

    func testAResponseFromAnotherInstanceCannotBeAccepted() {
        let target = BrowserTabReader.Target(browser: .chrome, processIdentifier: 101)
        XCTAssertTrue(target.matches(bundleIdentifier: Browser.chrome.bundleID, processIdentifier: 101))
        XCTAssertFalse(target.matches(bundleIdentifier: Browser.chrome.bundleID, processIdentifier: 202))
        XCTAssertFalse(target.matches(bundleIdentifier: Browser.safari.bundleID, processIdentifier: 101))
        XCTAssertFalse(target.matches(bundleIdentifier: nil, processIdentifier: nil))
    }

    func testChromeAndSafariReadOnlyTheFrontWindowsActiveTabURL() async {
        for (browser, tabCode, urlCode): (Browser, OSType, OSType) in [
            (.chrome, 0x61635461, 0x55524C20), // acTa / URL
            (.safari, 0x63546162, 0x7055524C)  // cTab / pURL
        ] {
            let reader = BrowserTabReader { event in
                XCTAssertEqual(event.eventClass, AEEventClass(kAECoreSuite))
                XCTAssertEqual(event.eventID, AEEventID(kAEGetData))
                let url = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
                XCTAssertEqual(url.descriptorType, DescType(typeObjectSpecifier))
                XCTAssertEqual(url.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue, urlCode)
                let tab = try XCTUnwrap(url.forKeyword(AEKeyword(keyAEContainer)))
                XCTAssertEqual(tab.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue, tabCode)
                let window = try XCTUnwrap(tab.forKeyword(AEKeyword(keyAEContainer)))
                XCTAssertEqual(window.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue, OSType(cWindow))
                XCTAssertEqual(window.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, OSType(formAbsolutePosition))
                XCTAssertEqual(window.forKeyword(AEKeyword(keyAEKeyData))?.int32Value, 1)
                return Self.reply(value: NSAppleEventDescriptor(string: "https://example.com/private?q=secret"))
            }
            let result = await reader.read(.init(browser: browser, processIdentifier: 101), sources: [])
            XCTAssertEqual(result.source?.identifier, "example.com")
            XCTAssertEqual(result.source?.name, "example.com")
            XCTAssertNil(result.errorCode)
        }
    }

    func testEmptyAndInternalTabsFallBackWithoutAnAccessError() async {
        for url in ["", "about:blank", "chrome://newtab/", "file:///private/local.html"] {
            let reader = BrowserTabReader { _ in Self.reply(value: NSAppleEventDescriptor(string: url)) }
            let result = await reader.read(.init(browser: .chrome, processIdentifier: 101), sources: [])
            XCTAssertNil(result.source)
            XCTAssertNil(result.errorCode)
        }
    }

    func testClosingTheLastWindowIsNotAPermissionFailure() async {
        let reader = BrowserTabReader { _ in Self.reply(error: Int32(errAENoSuchObject)) }
        let result = await reader.read(.init(browser: .chrome, processIdentifier: 101), sources: [])
        XCTAssertNil(result.source)
        XCTAssertNil(result.errorCode)
    }

    func testPermissionDenialAndTimeoutRemainErrors() async {
        for code: Int32 in [-1743, -1712, -600] {
            for throwsError in [false, true] {
                let reader = BrowserTabReader { _ in
                    if throwsError { throw NSError(domain: NSOSStatusErrorDomain, code: Int(code)) }
                    return Self.reply(error: code)
                }
                let result = await reader.read(.init(browser: .chrome, processIdentifier: 101), sources: [])
                XCTAssertNil(result.source)
                XCTAssertEqual(result.errorCode, Int(code))
            }
        }
    }

    func testMalformedReplyDoesNotReportAConnection() async {
        let reader = BrowserTabReader { _ in Self.reply() }
        let result = await reader.read(.init(browser: .chrome, processIdentifier: 101), sources: [])
        XCTAssertNil(result.source)
        XCTAssertEqual(result.errorCode, Int(errAECoercionFail))
    }

    private static func reply(value: NSAppleEventDescriptor? = nil, error: Int32? = nil) -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEAnswer,
            targetDescriptor: nil, returnID: 1, transactionID: 0)
        if let value { reply.setParam(value, forKeyword: keyDirectObject) }
        if let error { reply.setParam(NSAppleEventDescriptor(int32: error), forKeyword: keyErrorNumber) }
        return reply
    }
}
