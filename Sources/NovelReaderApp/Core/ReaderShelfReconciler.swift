import Foundation

enum ReaderShelfReconciler {
    struct Result {
        var book: Book
        var replacedBookIDs: Set<UUID>
        var invalidatedDownloadBookIDs: Set<UUID>
        var hasPendingProgress: Bool
    }

    static func reconcile(
        incoming: Book, localBooks: [Book], serverBookURLs: Set<String>,
        eligibleBookIDs: Set<UUID>, pendingProgressIDs: Set<UUID>
    ) -> Result {
        let identity = identityKey(incoming)
        let matches = localBooks.filter { local in
            guard eligibleBookIDs.contains(local.id),
                  local.readerServerConnectionID == nil || local.readerServerConnectionID == incoming.readerServerConnectionID else {
                return false
            }
            if sameSource(local, incoming) { return true }
            // Keep distinct editions that are still explicitly present on the server.
            let stillOnShelf = serverBookURLs.contains(remoteURL(local) ?? "")
                || serverBookURLs.contains { URL(string: $0) == local.remoteBookURL }
            guard !stillOnShelf, let identity else { return false }
            return identityKey(local) == identity
        }
        guard !matches.isEmpty else {
            return Result(book: incoming, replacedBookIDs: [], invalidatedDownloadBookIDs: [], hasPendingProgress: false)
        }

        // Keep the most recently read copy's identity, or the original import if unread.
        let ordered = matches.sorted {
            if $0.lastReadAt != $1.lastReadAt {
                return ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast)
            }
            return $0.addedAt < $1.addedAt
        }
        let original = ordered[0]
        let pending = ordered.filter { pendingProgressIDs.contains($0.id) }
        let readingCopy = pending.first ?? original
        var merged = incoming
        merged.id = original.id
        merged.addedAt = matches.map(\.addedAt).min() ?? original.addedAt
        merged.lastReadAt = matches.compactMap(\.lastReadAt).max()
        merged.status = original.status
        merged.coverImageURL = incoming.coverImageURL ?? original.coverImageURL

        // Cached chapter indexes are meaningful only within the same book source.
        for local in ordered where sameSource(local, incoming) {
            merged.chapters = mergeChapters(existing: local.chapters, incoming: merged.chapters)
        }
        if !pending.isEmpty || !sameSource(readingCopy, incoming) {
            merged.progress = remapProgress(from: readingCopy, to: merged)
            merged.status = readingCopy.status
        }

        return Result(
            book: merged,
            replacedBookIDs: Set(matches.map(\.id)),
            invalidatedDownloadBookIDs: Set(matches.filter { $0.id != merged.id || !sameSource($0, incoming) }.map(\.id)),
            hasPendingProgress: !pending.isEmpty || (!sameSource(readingCopy, incoming) && readingCopy.lastReadAt != nil)
        )
    }

    private static func remoteURL(_ book: Book) -> String? {
        book.remoteBookURLString ?? book.remoteBookURL?.absoluteString
    }

    private static func sameSource(_ lhs: Book, _ rhs: Book) -> Bool {
        if let left = remoteURL(lhs), let right = remoteURL(rhs), left == right { return true }
        return lhs.remoteBookURL != nil && lhs.remoteBookURL == rhs.remoteBookURL
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace }
    }

    private static func identityKey(_ book: Book) -> [String]? {
        let title = normalized(book.title)
        let author = normalized(book.author)
        guard !title.isEmpty, !author.isEmpty,
              !["未知作者", "佚名", "作者不详", "unknown"].contains(author) else { return nil }
        return [title, author]
    }

    private static func remapProgress(from old: Book, to new: Book) -> ReadingProgress {
        guard !new.chapters.isEmpty else { return new.progress }
        let oldIndex = min(max(old.progress.chapterIndex, 0), max(old.chapters.count - 1, 0))
        let previous = old.chapters.indices.contains(oldIndex) ? old.chapters[oldIndex] : nil
        var newIndex: Int?
        if let previous {
            if sameSource(old, new), let remoteIndex = previous.remoteIndex {
                newIndex = new.chapters.firstIndex { $0.remoteIndex == remoteIndex }
            }
            if newIndex == nil {
                let titleMatches = new.chapters.indices.filter {
                    !normalized(previous.title).isEmpty && normalized(new.chapters[$0].title) == normalized(previous.title)
                }
                if titleMatches.count == 1 { newIndex = titleMatches[0] }
            }
        }
        let index = newIndex ?? min(oldIndex, new.chapters.count - 1)
        var progress = old.progress
        progress.chapterIndex = index
        progress.percentage = Double(index) / Double(max(new.chapters.count - 1, 1))
        if !sameSource(old, new) || newIndex == nil {
            progress.pageCharacterOffset = nil
            progress.scrollOffset = 0
        }
        return progress
    }

    private static func mergeChapters(existing: [Chapter], incoming: [Chapter]) -> [Chapter] {
        incoming.map { chapter in
            guard chapter.localText.isEmpty else { return chapter }
            let match: Chapter?
            if let remoteIndex = chapter.remoteIndex, let byIndex = existing.first(where: { $0.remoteIndex == remoteIndex }) {
                match = byIndex
            } else if let url = chapter.url, let byURL = existing.first(where: { $0.url == url }) {
                match = byURL
            } else {
                match = existing.first { $0.title == chapter.title }
                    ?? (chapter.remoteIndex == nil ? existing.first { $0.remoteIndex == nil && $0.index == chapter.index } : nil)
            }
            guard let match, !match.localText.isEmpty else { return chapter }
            var cached = chapter
            cached.localText = match.localText
            cached.isDownloaded = match.isDownloaded
            return cached
        }
    }
}
