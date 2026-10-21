import XCTest
@testable import TrackingCore

final class BrowserTests: XCTestCase {
    func testMigratesLegacyBrowserWithoutEnablingAnother() {
        XCTAssertEqual(Browser.restoredSelection(saved: nil, legacy: "safari"), [.safari])
        XCTAssertEqual(Browser.restoredSelection(saved: nil, legacy: nil), [.chrome])
    }

    func testRestoresBothBrowsersAndIntentionallyEmptySelection() {
        XCTAssertEqual(Browser.restoredSelection(saved: ["chrome", "safari", "unknown"], legacy: "chrome"), [.chrome, .safari])
        XCTAssertEqual(Browser.restoredSelection(saved: [], legacy: "chrome"), [])
    }

    func testOnlyFrontmostEnabledBrowserIsSelected() {
        let enabled: Set<Browser> = [.chrome, .safari]
        XCTAssertEqual(Browser.eligibleBrowser(frontmostID: Browser.chrome.bundleID, enabled: enabled, blocked: [], websitesEnabled: true), .chrome)
        XCTAssertEqual(Browser.eligibleBrowser(frontmostID: Browser.safari.bundleID, enabled: enabled, blocked: [], websitesEnabled: true), .safari)
        XCTAssertNil(Browser.eligibleBrowser(frontmostID: "com.apple.finder", enabled: enabled, blocked: [], websitesEnabled: true))
    }

    func testPermissionDenialIsIsolatedToItsBrowser() {
        let enabled: Set<Browser> = [.chrome, .safari]
        XCTAssertNil(Browser.eligibleBrowser(frontmostID: Browser.chrome.bundleID, enabled: enabled, blocked: [.chrome], websitesEnabled: true))
        XCTAssertEqual(Browser.eligibleBrowser(frontmostID: Browser.safari.bundleID, enabled: enabled, blocked: [.chrome], websitesEnabled: true), .safari)
    }

    func testDisabledBrowserOrWebsiteTrackingIsNotRead() {
        XCTAssertNil(Browser.eligibleBrowser(frontmostID: Browser.safari.bundleID, enabled: [.chrome], blocked: [], websitesEnabled: true))
        XCTAssertNil(Browser.eligibleBrowser(frontmostID: Browser.chrome.bundleID, enabled: [.chrome, .safari], blocked: [], websitesEnabled: false))
    }
}
