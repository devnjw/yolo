import XCTest
@testable import TrackingCore

final class WebsiteIconCandidatesTests: XCTestCase {
    func testRanksLargeOfficialIconsAheadOfShortcut() {
        let html = """
        <link rel="shortcut icon" href="/favicon.ico">
        <link rel="icon" href="/32.png" sizes="32x32">
        <link rel="icon" href="/144.png" sizes="144x144">
        <link rel="icon" href="/48.png" sizes="48x48">
        """
        XCTAssertEqual(urls(html).map(\.lastPathComponent), ["144.png", "48.png", "favicon.ico", "32.png"])
    }

    func testRelativeCDNAndMixedAttributeFormats() {
        let html = """
        <LINK HREF='../touch.png?v=1&amp;x=2' REL='apple-touch-icon'>
        <link sizes=96x96 href=//cdn.example.com/icon.png rel=icon>
        """
        XCTAssertEqual(urls(html).map(\.absoluteString), [
            "https://example.com/touch.png?v=1&x=2", "https://cdn.example.com/icon.png"
        ])
    }

    func testSkipsUnsafeUnsupportedAndUnrelatedLinks() {
        let html = """
        <link rel=stylesheet href=/theme.css>
        <link rel=icon href=http://example.com/insecure.png>
        <link rel=icon href='https://user:pass@example.com/private.png'>
        <link rel=icon href='data:image/png;base64,abc'>
        <link rel=icon href=/icon.svg>
        <link rel=icon href=/valid.png sizes=64x64>
        <link rel=icon href=/valid.png sizes=128x128>
        """
        XCTAssertEqual(urls(html).map(\.lastPathComponent), ["valid.png"])
    }

    private func urls(_ html: String) -> [URL] {
        WebsiteIconCandidates.urls(in: html, relativeTo: URL(string: "https://example.com/home/")!)
    }
}
