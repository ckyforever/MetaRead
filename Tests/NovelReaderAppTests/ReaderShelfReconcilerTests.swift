import XCTest
@testable import NovelReaderApp

final class ReaderShelfReconcilerTests: XCTestCase {
    func testSourceSwitchKeepsBookAndRemapsProgressWithoutOldCachedText() {
        var old = book("https://old.test/book", source: "旧书源")
        old.lastReadAt = Date(timeIntervalSince1970: 100)
        old.status = .reading
        old.progress = ReadingProgress(chapterIndex: 1, scrollOffset: 20, percentage: 1, pageCharacterOffset: 128)
        old.chapters[1].localText = "旧书源正文"
        old.chapters[1].isDownloaded = true
        var incoming = book("https://new.test/book", source: "新书源")
        incoming.chapters = chapters(["序言", "第一章", "第二章"])

        let result = reconcile(incoming, [old])
        XCTAssertEqual(result.book.id, old.id)
        XCTAssertEqual(result.book.remoteBookURLString, incoming.remoteBookURLString)
        XCTAssertEqual(result.book.sourceName, "新书源")
        XCTAssertEqual(result.book.lastReadAt, old.lastReadAt)
        XCTAssertEqual(result.book.addedAt, old.addedAt)
        XCTAssertEqual(result.book.progress.chapterIndex, 2)
        XCTAssertNil(result.book.progress.pageCharacterOffset)
        XCTAssertEqual(result.book.progress.scrollOffset, 0)
        XCTAssertTrue(result.book.chapters.allSatisfy { $0.localText.isEmpty && !$0.isDownloaded })
        XCTAssertEqual(result.invalidatedDownloadBookIDs, [old.id])
        XCTAssertTrue(result.hasPendingProgress)
    }

    func testExistingDuplicatesCollapseAndRepeatedSyncIsStable() {
        var original = book("https://old.test/book")
        original.lastReadAt = Date(timeIntervalSince1970: 100)
        original.progress.chapterIndex = 1
        var duplicate = book("https://new.test/book")
        duplicate.addedAt = original.addedAt.addingTimeInterval(10)
        duplicate.chapters[0].localText = "新书源缓存"
        duplicate.chapters[0].isDownloaded = true
        let incoming = book("https://new.test/book")

        let first = reconcile(incoming, [duplicate, original], pending: [original.id])
        XCTAssertEqual(first.replacedBookIDs, [original.id, duplicate.id])
        XCTAssertEqual(first.book.id, original.id)
        XCTAssertEqual(first.book.progress.chapterIndex, 1)
        XCTAssertEqual(first.book.chapters[0].localText, "新书源缓存")
        XCTAssertTrue(first.hasPendingProgress)
        XCTAssertEqual(first.invalidatedDownloadBookIDs, [original.id, duplicate.id])

        let again = reconcile(incoming, [first.book], pending: [first.book.id])
        XCTAssertEqual(again.replacedBookIDs, [original.id])
        XCTAssertEqual(again.book.id, original.id)
        XCTAssertEqual(again.book.progress.chapterIndex, 1)
        XCTAssertTrue(again.invalidatedDownloadBookIDs.isEmpty)
    }

    func testDifferentAuthorLocalBooksAndOtherServersAreNotMerged() {
        let incoming = book("https://new.test/book")
        var otherAuthor = book("https://old.test/other")
        otherAuthor.author = "另一位作者"
        var otherServer = book("https://old.test/server")
        otherServer.readerServerConnectionID = UUID()
        var local = book("https://old.test/local")
        local.isReaderServerBacked = false
        XCTAssertTrue(reconcile(incoming, [otherAuthor, otherServer, local]).replacedBookIDs.isEmpty)
    }

    func testUnknownAuthorsDoNotCauseTitleOnlyMerges() {
        for author in ["", "未知作者", "佚名"] {
            var old = book("https://old.test/book")
            old.author = author
            var incoming = book("https://new.test/book")
            incoming.author = author
            XCTAssertTrue(reconcile(incoming, [old]).replacedBookIDs.isEmpty)
        }
    }

    func testSeparateEditionsStillOnServerShelfAreRetained() {
        let old = book("https://old.test/book")
        let incoming = book("https://new.test/book")
        let result = ReaderShelfReconciler.reconcile(
            incoming: incoming, localBooks: [old],
            serverBookURLs: [old.remoteBookURLString!, incoming.remoteBookURLString!],
            eligibleBookIDs: [old.id], pendingProgressIDs: []
        )
        XCTAssertTrue(result.replacedBookIDs.isEmpty)
    }

    func testSameURLUpdatesMetadataKeepsCacheAndUsesServerProgress() {
        var old = book("https://book.test/path")
        old.chapters[1].localText = "已缓存的第二章"
        old.chapters[1].isDownloaded = true
        var incoming = book("https://book.test/path", source: "新名称")
        incoming.title = "更新后的书名"
        incoming.progress.chapterIndex = 1
        let result = reconcile(incoming, [old])
        XCTAssertEqual(result.book.id, old.id)
        XCTAssertEqual(result.book.title, incoming.title)
        XCTAssertEqual(result.book.sourceName, "新名称")
        XCTAssertEqual(result.book.chapters[1].localText, old.chapters[1].localText)
        XCTAssertEqual(result.book.progress, incoming.progress)
        XCTAssertTrue(result.invalidatedDownloadBookIDs.isEmpty)
    }

    func testWhitespaceAndWidthDifferencesMatchLegacyServerBook() throws {
        var old = book("https://old.test/book")
        old.readerServerConnectionID = nil
        old.title = " 测试 书籍 "
        old.author = "Ａｕｔｈｏｒ"
        var incoming = book("https://new.test/book")
        incoming.author = "author"
        XCTAssertEqual(reconcile(incoming, [old]).replacedBookIDs, [old.id])

        // Existing snapshots without the new server scope still decode.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(incoming)) as? [String: Any])
        json.removeValue(forKey: "readerServerConnectionID")
        let decoded = try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.readerServerConnectionID)
    }

    func testSourceSwitchClampsProgressWhenChapterCannotBeMatched() {
        var old = book("https://old.test/book")
        old.progress.chapterIndex = 999
        old.progress.pageCharacterOffset = 80
        var incoming = book("https://new.test/book")
        incoming.chapters = chapters(["新目录唯一章节"])
        let result = reconcile(incoming, [old])
        XCTAssertEqual(result.book.progress.chapterIndex, 0)
        XCTAssertNil(result.book.progress.pageCharacterOffset)
    }

    private let connectionID = UUID()

    private func reconcile(_ incoming: Book, _ existing: [Book], pending: Set<UUID> = []) -> ReaderShelfReconciler.Result {
        ReaderShelfReconciler.reconcile(
            incoming: incoming, localBooks: existing, serverBookURLs: [incoming.remoteBookURLString!],
            eligibleBookIDs: Set(existing.filter { $0.isReaderServerBacked == true }.map(\.id)),
            pendingProgressIDs: pending
        )
    }

    private func book(_ url: String, source: String = "Reader") -> Book {
        Book(
            title: "测试书籍", author: "测试作者", summary: "", coverSymbol: "book", format: .web,
            sourceName: source, localURL: nil, remoteBookURL: URL(string: url), remoteBookURLString: url,
            isReaderServerBacked: true, readerServerConnectionID: connectionID, status: .unread,
            progress: ReadingProgress(chapterIndex: 0, scrollOffset: 0, percentage: 0),
            chapters: chapters(["第一章", "第二章"]),
            addedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func chapters(_ titles: [String]) -> [Chapter] {
        titles.enumerated().map {
            Chapter(index: $0.offset, remoteIndex: $0.offset, title: $0.element, url: nil, localText: "", isDownloaded: false)
        }
    }
}
