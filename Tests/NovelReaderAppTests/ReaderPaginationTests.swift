import XCTest
@testable import NovelReaderApp

final class ReaderPaginationTests: XCTestCase {
    func testPagesCoverAllTextWithoutGapsIncludingEmoji() {
        let body = String(repeating: "春风吹过山谷，读者继续前行。👨‍👩‍👧‍👦🌿 e\u{301}\n另一段正文，不应丢字或重复。\n", count: 50)
        let pagination = ReaderPagination(title: "第一章", body: body, theme: .classic, size: CGSize(width: 280, height: 360))

        XCTAssertGreaterThan(pagination.ranges.count, 1)
        var nextOffset = 0
        var reconstructed = ""
        for (index, range) in pagination.ranges.enumerated() {
            XCTAssertEqual(range.location, nextOffset)
            XCTAssertGreaterThan(range.length, 0)
            XCTAssertEqual(pagination.pageIndex(containing: range.location), index)
            XCTAssertEqual(pagination.pageIndex(containing: NSMaxRange(range) - 1), index)
            reconstructed += pagination.text.attributedSubstring(from: range).string
            nextOffset = NSMaxRange(range)
        }
        XCTAssertEqual(nextOffset, pagination.text.length)
        XCTAssertEqual(reconstructed, pagination.text.string)
    }

    func testReflowKeepsReadingAnchorAndRespectsFontAndViewport() {
        let body = String(repeating: "这是用于测试分页和阅读位置恢复的长篇正文。\n", count: 150)
        let original = ReaderPagination(title: "章节", body: body, theme: .classic, size: CGSize(width: 320, height: 480))
        let anchor = original.ranges[3].location
        var largeTheme = ReaderTheme.classic
        largeTheme.fontSize = 30
        largeTheme.lineSpacing = 20
        largeTheme.effectiveCharacterSpacing = 3
        let reflowed = ReaderPagination(title: "章节", body: body, theme: largeTheme, size: CGSize(width: 280, height: 350))

        XCTAssertGreaterThan(reflowed.ranges.count, original.ranges.count)
        XCTAssertTrue(NSLocationInRange(anchor, reflowed.ranges[reflowed.pageIndex(containing: anchor)]))
        XCTAssertEqual(reflowed.pageIndex(containing: Int.max), reflowed.ranges.count - 1)
        XCTAssertEqual(reflowed.pageIndex(containing: 0), 0)
    }

    func testTinyViewportDoesNotSkipTextOrLoop() {
        let pagination = ReaderPagination(title: "标题", body: "正文", theme: .classic, size: CGSize(width: 1, height: 1))
        XCTAssertTrue(pagination.ranges.isEmpty)
    }

    func testLegacySettingsAndProgressDecodeAndNewValuesRoundTrip() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let legacyProgress = Data(#"{"chapterIndex":2,"scrollOffset":0,"percentage":0.3}"#.utf8)
        var progress = try decoder.decode(ReadingProgress.self, from: legacyProgress)
        XCTAssertNil(progress.pageCharacterOffset)
        progress.pageCharacterOffset = 1234
        XCTAssertEqual(try decoder.decode(ReadingProgress.self, from: encoder.encode(progress)).pageCharacterOffset, 1234)

        var theme = ReaderTheme.classic
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(theme)) as? [String: Any])
        json.removeValue(forKey: "readingMode")
        json.removeValue(forKey: "tapBothSidesToAdvance")
        let legacyTheme = try decoder.decode(ReaderTheme.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacyTheme.effectiveReadingMode, .scroll)
        XCTAssertFalse(legacyTheme.effectiveTapBothSidesToAdvance)
        theme.effectiveReadingMode = .paged
        theme.effectiveTapBothSidesToAdvance = true
        XCTAssertEqual(try decoder.decode(ReaderTheme.self, from: encoder.encode(theme)).effectiveReadingMode, .paged)
        XCTAssertTrue(try decoder.decode(ReaderTheme.self, from: encoder.encode(theme)).effectiveTapBothSidesToAdvance)
    }
}
