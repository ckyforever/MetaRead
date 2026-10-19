import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let readerBackSwipeEdgeWidth: CGFloat = 24

struct ReaderView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var book: Book
    @State private var chapterIndex: Int
    @State private var showCatalog = false
    @State private var showStylePanel = false
    @State private var loadingChapterIDs: Set<UUID> = []
    @State private var contentLoadError: String?
    @State private var controlsVisible = true
    @State private var pageCharacterOffset: Int
    @State private var chapterPageFraction = 0.0
    #if os(macOS)
    @State private var catalogVisibility: NavigationSplitViewVisibility = .detailOnly
    #endif

    init(book: Book, initialChapterIndex: Int? = nil) {
        _book = State(initialValue: book)
        let requestedIndex = initialChapterIndex ?? book.progress.chapterIndex
        _chapterIndex = State(initialValue: max(0, min(requestedIndex, max(book.chapters.count - 1, 0))))
        _pageCharacterOffset = State(initialValue: initialChapterIndex == nil ? max(0, book.progress.pageCharacterOffset ?? 0) : 0)
    }

    private var displayedBook: Book {
        store.books.first(where: { $0.id == book.id }) ?? book
    }

    private var chapter: Chapter? {
        let book = displayedBook
        guard book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            readerDetail
        }
        .sheet(isPresented: $showCatalog) {
            NavigationStack {
                catalogList
                    .navigationTitle("目录")
            }
        }
        .onChange(of: chapterIndex) { _, newValue in
            updateReadingProgress(newValue)
        }
        .sheet(isPresented: $showStylePanel, onDismiss: store.save) {
            ReaderStylePanel()
                .environmentObject(store)
        }
        #else
        NavigationSplitView(columnVisibility: $catalogVisibility) {
            catalogList
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            readerDetail
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: chapterIndex) { _, newValue in
            updateReadingProgress(newValue)
        }
        .sheet(isPresented: $showStylePanel, onDismiss: store.save) {
            ReaderStylePanel()
                .environmentObject(store)
        }
        #endif
    }

    private var catalogList: some View {
        let book = displayedBook
        return List(book.chapters) { chapter in
            Button {
                pageCharacterOffset = 0
                chapterPageFraction = 0
                chapterIndex = chapter.index
                showCatalog = false
                #if os(macOS)
                catalogVisibility = .detailOnly
                #endif
            } label: {
                Text(chapter.title)
                    .foregroundStyle(chapterIndex == chapter.index ? AppTheme.accent : AppTheme.ink)
            }
        }
        .navigationTitle("目录")
    }

    private var readerDetail: some View {
        let book = displayedBook
        return ZStack {
            Color(hex: store.readerTheme.backgroundHex)
                .ignoresSafeArea()

            if let chapter {
                if store.readerTheme.effectiveReadingMode == .paged && !chapter.localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ReaderPaginatedChapter(
                        book: book,
                        chapter: chapter,
                        chapterIndex: chapterIndex,
                        characterOffset: $pageCharacterOffset,
                        toggleControls: toggleControls,
                        moveChapter: { moveChapter($0, fromPageBoundary: true) },
                        onProgress: { fraction in
                            chapterPageFraction = fraction
                            updateReadingProgress(chapterIndex)
                        }
                    )
                    .id(chapter.id)
                } else {
                    ReaderChapterPage(
                        book: book,
                        chapter: chapter,
                        chapterIndex: chapterIndex,
                        readingPercentage: readingPercentage,
                        isLoadingContent: loadingChapterIDs.contains(chapter.id),
                        contentLoadError: contentLoadError,
                        retryAction: { Task { await loadVisibleChapterIfNeeded() } },
                        onAdvanceToNextChapter: { moveChapter(1) }
                    )
                    .environmentObject(store)
                    .onTapGesture(perform: toggleControls)
                    .accessibilityAction(named: Text("显示或隐藏工具栏"), toggleControls)
                }
            } else {
                EmptyStateView(systemImage: "text.book.closed", title: "暂无章节", subtitle: "这本书还没有下载目录或正文。")
            }
        }
        // Controls overlay the reader without changing the pagination viewport.
        .overlay(alignment: .bottom) {
            if controlsVisible {
                ReaderBottomBar(
                    readingPercentage: readingPercentage,
                    canMoveBack: chapterIndex > 0,
                    canMoveForward: chapterIndex < book.chapters.count - 1,
                    catalogAction: {
                        #if os(macOS)
                        withAnimation {
                            catalogVisibility = catalogVisibility == .detailOnly ? .all : .detailOnly
                        }
                        #else
                        showCatalog = true
                        #endif
                    },
                    previousAction: { moveChapter(-1) },
                    nextAction: { moveChapter(1) },
                    scrubAction: { value in
                        let maxIndex = max(book.chapters.count - 1, 0)
                        guard maxIndex > 0 else { return }
                        let targetIndex = min(max(Int((value * Double(maxIndex)).rounded()), 0), maxIndex)
                        guard targetIndex != chapterIndex else { return }
                        pageCharacterOffset = 0
                        chapterPageFraction = 0
                        chapterIndex = targetIndex
                    },
                    styleAction: { showStylePanel = true },
                    hideAction: toggleControls
                )
                .environmentObject(store)
            }
        }
        .navigationTitle("")
        .platformInlineNavigationTitle()
        #if os(iOS)
        // Observe alongside scrolling; only rightward drags from the left edge exit.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global)
                .onEnded { value in
                    guard value.startLocation.x >= 0,
                          value.startLocation.x <= readerBackSwipeEdgeWidth,
                          value.translation.width > 80,
                          value.translation.width > abs(value.translation.height) * 1.5 else { return }
                    dismiss()
                }
        )
        .toolbar(.hidden, for: .navigationBar)
        // Keep system safe-area insets stable when the controls are toggled.
        .statusBarHidden(false)
        .overlay(alignment: .top) {
            if controlsVisible {
                HStack {
                    closeButton
                    Spacer()
                    readerActions
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        #else
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if controlsVisible {
                    closeButton
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if controlsVisible {
                    readerActions
                }
            }
        }
        #endif
        .onAppear {
            if chapter != nil {
                store.recordReading(bookID: book.id)
            }
        }
        .task(id: chapter?.id) {
            await loadVisibleChapterIfNeeded()
        }
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Label("关闭", systemImage: "xmark")
                #if os(iOS)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                #endif
        }
    }

    private var readerActions: some View {
        HStack {
            Button {
                store.cacheFollowingChapters(for: displayedBook, limit: 50)
            } label: {
                Label("缓存后续", systemImage: "arrow.down.to.line.compact")
                    #if os(iOS)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    #endif
            }
            .disabled(!canCacheFollowingChapters)

            Button {
                showStylePanel = true
            } label: {
                Label("样式", systemImage: "textformat.size")
                    #if os(iOS)
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    #endif
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible.toggle()
            #if os(macOS)
            if !controlsVisible { catalogVisibility = .detailOnly }
            #endif
        }
    }

    private func moveChapter(_ offset: Int, fromPageBoundary: Bool = false) {
        let book = displayedBook
        let next = chapterIndex + offset
        guard book.chapters.indices.contains(next) else { return }
        pageCharacterOffset = fromPageBoundary && offset < 0 ? Int.max : 0
        chapterPageFraction = 0
        chapterIndex = next
    }

    private func updateReadingProgress(_ newValue: Int) {
        let book = displayedBook
        store.updateProgress(
            bookID: book.id,
            chapterIndex: newValue,
            percentage: readingPercentage,
            pageCharacterOffset: pageCharacterOffset == Int.max ? 0 : pageCharacterOffset
        )
    }

    @MainActor
    private func loadVisibleChapterIfNeeded() async {
        let book = displayedBook
        guard book.chapters.indices.contains(chapterIndex) else { return }
        let chapter = book.chapters[chapterIndex]
        guard chapter.localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              store.canLoadReaderServerContent(for: book) else {
            contentLoadError = nil
            return
        }

        loadingChapterIDs.insert(chapter.id)
        contentLoadError = nil
        let didLoad = await store.loadChapterContentIfNeeded(bookID: book.id, chapterIndex: chapterIndex)
        loadingChapterIDs.remove(chapter.id)
        guard self.chapter?.id == chapter.id else { return }
        if !didLoad {
            contentLoadError = store.activityMessage
        }
    }

    private var readingPercentage: Double {
        let book = displayedBook
        if store.readerTheme.effectiveReadingMode == .paged {
            return min(1, (Double(chapterIndex) + chapterPageFraction) / Double(max(book.chapters.count, 1)))
        }
        guard book.chapters.count > 1 else { return book.progress.percentage }
        return Double(chapterIndex) / Double(max(book.chapters.count - 1, 1))
    }

    private var canCacheFollowingChapters: Bool {
        let book = displayedBook
        guard book.format == .web,
              book.isReaderServerBacked == true || book.chapters.contains(where: { $0.url != nil }) else {
            return false
        }
        let startIndex = min(chapterIndex + 1, book.chapters.count)
        return book.chapters.dropFirst(startIndex).contains { !$0.isDownloaded }
    }
}

// The same Core Text frames are used for measurement and drawing so a page never
// depends on an estimated character count (including emoji and custom fonts).
struct ReaderPagination {
    let text: NSAttributedString
    let ranges: [NSRange]
    let size: CGSize

    init(title: String, body: String, theme: ReaderTheme, size: CGSize) {
        self.size = size
        #if os(macOS)
        let weight: NSFont.Weight = theme.isBold ? .semibold : (theme.fontDesign == .cute ? .medium : .regular)
        let systemFont = NSFont.systemFont(ofSize: theme.fontSize, weight: weight)
        let customFont = theme.customFontName.flatMap { NSFont(name: $0, size: theme.fontSize) }
        let color = NSColor(Color(hex: theme.foregroundHex))
        let design: NSFontDescriptor.SystemDesign = switch theme.fontDesign {
        case .serif: .serif
        case .sans: .default
        case .rounded, .cute: .rounded
        case .mono: .monospaced
        }
        let descriptor = systemFont.fontDescriptor.withDesign(design) ?? systemFont.fontDescriptor
        let font = (customFont ?? NSFont(descriptor: descriptor, size: theme.fontSize) ?? systemFont) as CTFont
        #else
        let weight: UIFont.Weight = theme.isBold ? .semibold : (theme.fontDesign == .cute ? .medium : .regular)
        let systemFont = UIFont.systemFont(ofSize: theme.fontSize, weight: weight)
        let customFont = theme.customFontName.flatMap { UIFont(name: $0, size: theme.fontSize) }
        let color = UIColor(Color(hex: theme.foregroundHex))
        let design: UIFontDescriptor.SystemDesign = switch theme.fontDesign {
        case .serif: .serif
        case .sans: .default
        case .rounded, .cute: .rounded
        case .mono: .monospaced
        }
        let descriptor = systemFont.fontDescriptor.withDesign(design) ?? systemFont.fontDescriptor
        let font = (customFont ?? UIFont(descriptor: descriptor, size: theme.fontSize)) as CTFont
        #endif
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = theme.lineSpacing
        paragraphStyle.paragraphSpacing = theme.paragraphSpacing
        paragraphStyle.firstLineHeadIndent = max(0, theme.effectiveFirstLineIndent) * theme.fontSize
        let tracking = theme.fontDesign == .cute ? max(theme.effectiveCharacterSpacing, 0.4) : theme.effectiveCharacterSpacing
        let paragraphs = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let content = NSMutableAttributedString(string: title + "\n" + paragraphs, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: tracking,
            .paragraphStyle: paragraphStyle
        ])
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 24
        content.addAttributes([
            .font: CTFontCreateCopyWithSymbolicTraits(font, theme.fontSize + 5, nil, .boldTrait, .boldTrait) ?? font,
            .paragraphStyle: titleStyle
        ], range: NSRange(location: 0, length: (title as NSString).length + 1))
        text = content
        guard size.width > 0, size.height > 0 else {
            ranges = []
            return
        }
        let framesetter = CTFramesetterCreateWithAttributedString(content)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var pages: [NSRange] = []
        var offset = 0
        while offset < content.length {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            // A tiny window may not fit even one line. Do not skip text to advance.
            guard visible.length > 0 else {
                ranges = []
                return
            }
            pages.append(NSRange(location: offset, length: visible.length))
            offset += visible.length
        }
        ranges = pages
    }

    func pageIndex(containing offset: Int) -> Int {
        ranges.firstIndex { NSMaxRange($0) > offset } ?? max(ranges.count - 1, 0)
    }
}

private struct ReaderPaginationKey: Hashable {
    var title: String
    var text: String
    var theme: ReaderTheme
    var width: CGFloat
    var height: CGFloat
}

private struct ReaderPaginatedChapter: View {
    @EnvironmentObject private var store: AppStore
    var book: Book
    var chapter: Chapter
    var chapterIndex: Int
    @Binding var characterOffset: Int
    var toggleControls: () -> Void
    var moveChapter: (Int) -> Void
    var onProgress: (Double) -> Void
    @State private var pagination: ReaderPagination?

    private var pageIndex: Int { pagination?.pageIndex(containing: characterOffset) ?? 0 }
    private var pageCount: Int { pagination?.ranges.count ?? 0 }
    private var canGoBack: Bool { pageIndex > 0 || chapterIndex > 0 }
    private var canGoForward: Bool { pageIndex + 1 < pageCount || chapterIndex + 1 < book.chapters.count }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(book.title).lineLimit(1)
                Spacer()
                Text("第 \(chapterIndex + 1) 章").fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GeometryReader { geometry in
                Group {
                    if let pagination, !pagination.ranges.isEmpty {
                        pageCanvas(pagination)
                    } else {
                        Text("正在排版；如窗口过小，请放大阅读区域。")
                            .font(.caption)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if location.x < geometry.size.width * 0.28 {
                        turnPage(store.readerTheme.effectiveTapBothSidesToAdvance ? 1 : -1)
                    } else if location.x > geometry.size.width * 0.72 {
                        turnPage(1)
                    } else {
                        toggleControls()
                    }
                }
                .gesture(DragGesture(minimumDistance: 24, coordinateSpace: .global).onEnded { value in
                    #if os(iOS)
                    // Reserve a rightward swipe from the reader's edge for returning.
                    if value.startLocation.x <= readerBackSwipeEdgeWidth,
                       value.translation.width > 0 { return }
                    #endif
                    guard abs(value.translation.width) > abs(value.translation.height),
                          abs(value.translation.width) > 40 else { return }
                    turnPage(value.translation.width < 0 ? 1 : -1)
                })
                .task(id: ReaderPaginationKey(title: chapter.title, text: chapter.localText, theme: store.readerTheme, width: geometry.size.width, height: geometry.size.height)) {
                    guard !Task.isCancelled else { return }
                    pagination = ReaderPagination(title: chapter.title, body: chapter.localText, theme: store.readerTheme, size: geometry.size)
                    if characterOffset == Int.max, let last = pagination?.ranges.last {
                        characterOffset = last.location
                    }
                    reportProgress()
                }
            }

            HStack {
                Button { turnPage(-1) } label: {
                    Label("上一页", systemImage: "chevron.left")
                }
                .disabled(!canGoBack || pageCount == 0)
                #if os(macOS)
                .keyboardShortcut(.leftArrow, modifiers: [])
                #endif
                Spacer(minLength: 4)
                Text(pageCount > 0 ? "\(pageIndex + 1) / \(pageCount) 页" : "排版中")
                    .monospacedDigit()
                    .accessibilityLabel("本章第 \(pageIndex + 1) 页，共 \(pageCount) 页")
                Spacer(minLength: 4)
                Button { turnPage(1) } label: {
                    Label(canGoForward ? "下一页" : "全书完", systemImage: "chevron.right")
                }
                .disabled(!canGoForward || pageCount == 0)
                #if os(macOS)
                .keyboardShortcut(.rightArrow, modifiers: [])
                #endif
            }
            .font(.caption)
            .buttonStyle(.plain)
            .frame(minHeight: 32)
        }
        .foregroundStyle(Color(hex: store.readerTheme.foregroundHex))
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .onChange(of: characterOffset) { _, _ in reportProgress() }
    }

    private func pageCanvas(_ pagination: ReaderPagination) -> some View {
        let range = pagination.ranges[pageIndex]
        return Canvas { context, _ in
            context.withCGContext { cgContext in
                cgContext.textMatrix = .identity
                cgContext.translateBy(x: 0, y: pagination.size.height)
                cgContext.scaleBy(x: 1, y: -1)
                let framesetter = CTFramesetterCreateWithAttributedString(pagination.text)
                let path = CGPath(rect: CGRect(origin: .zero, size: pagination.size), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: range.location, length: range.length), path, nil)
                CTFrameDraw(frame, cgContext)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pagination.text.attributedSubstring(from: range).string)
        .accessibilityAction(named: Text("上一页")) { turnPage(-1) }
        .accessibilityAction(named: Text("下一页")) { turnPage(1) }
        .accessibilityAction(named: Text("显示或隐藏工具栏"), toggleControls)
        .accessibilityScrollAction { edge in
            if edge == .trailing { turnPage(1) }
            if edge == .leading { turnPage(-1) }
        }
    }

    private func turnPage(_ direction: Int) {
        guard let pagination, !pagination.ranges.isEmpty else { return }
        let target = pageIndex + direction
        if pagination.ranges.indices.contains(target) {
            characterOffset = pagination.ranges[target].location
        } else if (direction < 0 && canGoBack) || (direction > 0 && canGoForward) {
            moveChapter(direction)
        }
    }

    private func reportProgress() {
        guard pageCount > 0 else { return }
        onProgress(Double(pageIndex + 1) / Double(pageCount))
    }
}

private struct ReaderChapterPage: View {
    @EnvironmentObject private var store: AppStore
    var book: Book
    var chapter: Chapter
    var chapterIndex: Int
    var readingPercentage: Double
    var isLoadingContent: Bool
    var contentLoadError: String?
    var retryAction: () -> Void
    var onAdvanceToNextChapter: (() -> Void)?
    private let topAnchorID = "reader-chapter-top"

    private var isEmpty: Bool {
        chapter.localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasNextChapter: Bool {
        chapterIndex < book.chapters.count - 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: store.readerTheme.paragraphSpacing) {
                ReaderChapterHeader(book: book, chapterIndex: chapterIndex)

                Text(chapter.title)
                    .font(.system(size: 26, weight: .semibold, design: .serif))
                    .padding(.bottom, 16)

                // Content states — mutually exclusive
                if isLoadingContent && isEmpty {
                    ReaderChapterLoadingView(title: "正在读取正文…")
                } else if isEmpty {
                    ReaderChapterEmptyState(
                        error: contentLoadError,
                        isReaderServerBacked: book.isReaderServerBacked == true,
                        retryAction: retryAction
                    )
                } else {
                    ReaderBodyText(text: chapter.localText)
                        .environmentObject(store)
                }

                ReaderChapterFooter(book: book, readingPercentage: readingPercentage)
                    .environmentObject(store)

                // Next-chapter trigger zone (iOS only, when content is loaded)
                #if os(iOS)
                if hasNextChapter && !isEmpty {
                    ReaderNextChapterTrigger(
                        nextChapterTitle: book.chapters[chapterIndex + 1].title,
                        onAdvance: { onAdvanceToNextChapter?() }
                    )
                    .foregroundStyle(Color(hex: store.readerTheme.foregroundHex))
                } else if !hasNextChapter && !isEmpty {
                    ReaderEndOfBookView()
                        .foregroundStyle(Color(hex: store.readerTheme.foregroundHex))
                }
                #endif
            }
            .foregroundStyle(Color(hex: store.readerTheme.foregroundHex))
            #if os(macOS)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 56)
            #else
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28)
            #endif
            .padding(.top, 34)
            .padding(.bottom, 132)
        }
        // Force ScrollView recreation on chapter change → always starts at top
        .id(chapterIndex)
    }
}

// MARK: - Next chapter auto-advance trigger

#if os(iOS)
private struct ReaderNextChapterTrigger: View {
    var nextChapterTitle: String
    var onAdvance: () -> Void
    @State private var hasTriggered = false
    @State private var pullProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: 16) {
            Divider()
                .padding(.top, 12)

            VStack(spacing: 10) {
                Image(systemName: pullProgress >= 1.0 ? "checkmark.circle.fill" : "arrow.up.circle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .rotationEffect(.degrees(pullProgress >= 1.0 ? 0 : min(Double(pullProgress) * 180, 180)))
                    .animation(.easeOut(duration: 0.2), value: pullProgress)

                Text(pullProgress >= 1.0 ? "松手进入下一章" : "继续下滑 → 下一章")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(nextChapterTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.frame(in: .global).minY) { _, minY in
                        guard !hasTriggered else { return }
                        let screenHeight = UIScreen.main.bounds.height
                        // Calculate how far past the bottom the user has scrolled
                        let overscroll = screenHeight - minY
                        let threshold: CGFloat = 120
                        pullProgress = min(max(overscroll / threshold, 0), 1.2)

                        if pullProgress >= 1.0 {
                            hasTriggered = true
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            // Small delay so the user sees the checkmark
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                onAdvance()
                            }
                        }
                    }
            }
        )
    }
}

private struct ReaderEndOfBookView: View {
    var body: some View {
        VStack(spacing: 12) {
            Divider()
                .padding(.top, 12)

            VStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary.opacity(0.5))

                Text("已读完全部章节")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }
}
#endif

private struct ReaderChapterLoadingView: View {
    var title: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(title)
                .font(.body.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }
}

private struct ReaderChapterEmptyState: View {
    var error: String?
    var isReaderServerBacked: Bool
    var retryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: error != nil ? "exclamationmark.triangle" : "arrow.down.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary.opacity(0.6))
                .padding(.bottom, 4)

            if let error {
                Text("正文读取失败")
                    .font(.headline.weight(.medium))
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isReaderServerBacked {
                    Text("在家里网络时可正常读取未缓存章节；离家时请提前缓存或使用 VPN。")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                Button(action: retryAction) {
                    Label("重新读取", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 6)
            } else {
                Text("章节尚未缓存")
                    .font(.headline.weight(.medium))
                Text("这一章还没有下载到本机。回到家里网络后可点击右上角下载按钮缓存后续章节。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 32)
    }
}

private struct ReaderChapterHeader: View {
    var book: Book
    var chapterIndex: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(book.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            StatusBadge(title: "\(chapterIndex + 1)/\(max(book.chapters.count, 1))", color: .secondary)
        }
        .padding(.bottom, 16)
    }
}

private struct ReaderBottomBar: View {
    @EnvironmentObject private var store: AppStore
    var readingPercentage: Double
    var canMoveBack: Bool
    var canMoveForward: Bool
    var catalogAction: () -> Void
    var previousAction: () -> Void
    var nextAction: () -> Void
    var scrubAction: (Double) -> Void
    var styleAction: () -> Void
    var hideAction: () -> Void
    @State private var scrubPercentage = 0.0
    @State private var isScrubbing = false

    private var displayedPercentage: Double {
        isScrubbing ? scrubPercentage : readingPercentage
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(action: previousAction) {
                    Image(systemName: "chevron.left")
                        .frame(width: 32, height: 32)
                }
                .disabled(!canMoveBack)
                .accessibilityLabel("上一章")

                Slider(
                    value: Binding(
                        get: { displayedPercentage },
                        set: { scrubPercentage = $0 }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if editing {
                            scrubPercentage = readingPercentage
                            isScrubbing = true
                        } else {
                            isScrubbing = false
                            scrubAction(scrubPercentage)
                        }
                    }
                )
                    .tint(Color(hex: store.readerTheme.foregroundHex).opacity(0.72))

                Button(action: nextAction) {
                    Image(systemName: "chevron.right")
                        .frame(width: 32, height: 32)
                }
                .disabled(!canMoveForward)
                .accessibilityLabel("下一章")

                Text(displayedPercentage.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            HStack(spacing: 8) {
                readerToolButton(title: "目录", icon: "list.bullet", action: catalogAction)
                readerToolButton(title: "亮度", icon: "sun.max", action: {})
                readerToolButton(title: "Aa", icon: "textformat.size", action: styleAction)
                readerToolButton(title: "背景", icon: "circle.lefthalf.filled", action: styleAction)
                readerToolButton(title: "隐藏", icon: "chevron.down", action: hideAction)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .onAppear {
            scrubPercentage = readingPercentage
        }
        .onChange(of: readingPercentage) { _, newValue in
            if !isScrubbing {
                scrubPercentage = newValue
            }
        }
    }

    private func readerToolButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(hex: store.readerTheme.foregroundHex).opacity(0.82))
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ReaderChapterFooter: View {
    @EnvironmentObject private var store: AppStore
    var book: Book
    var readingPercentage: Double

    var body: some View {
        Divider()
            .padding(.top, 22)
        HStack {
            Text(book.title)
                .lineLimit(1)
            Spacer()
            Text(readingPercentage.formatted(.percent.precision(.fractionLength(0))))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        ProgressView(value: readingPercentage)
            .tint(Color(hex: store.readerTheme.foregroundHex).opacity(0.75))
    }
}

struct ReaderBodyText: View {
    @EnvironmentObject private var store: AppStore
    var text: String

    var body: some View {
        ReaderTextColumn(text: text)
    }
}

private struct ReaderTextColumn: View {
    @EnvironmentObject private var store: AppStore
    var text: String

    var body: some View {
        let renderedParagraphs = paragraphs
        LazyVStack(alignment: .leading, spacing: store.readerTheme.paragraphSpacing) {
            ForEach(Array(renderedParagraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(indentedParagraph(paragraph))
                    .readerTextStyle(theme: store.readerTheme)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var paragraphs: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func indentedParagraph(_ paragraph: String) -> String {
        let indent = max(0, store.readerTheme.effectiveFirstLineIndent)
        guard indent > 0 else { return paragraph }
        let fullWidthSpaces = Int(indent.rounded(.down))
        let hasHalfSpace = indent - Double(fullWidthSpaces) >= 0.5
        return String(repeating: "\u{3000}", count: fullWidthSpaces)
            + (hasHalfSpace ? " " : "")
            + paragraph
    }
}

private extension Text {
    func readerTextStyle(theme: ReaderTheme) -> some View {
        let fontWeight: Font.Weight = theme.isBold ? .semibold : (theme.fontDesign == .cute ? .medium : .regular)
        let tracking = theme.fontDesign == .cute ? max(theme.effectiveCharacterSpacing, 0.4) : theme.effectiveCharacterSpacing
        let resolvedFont: Font
        if let customName = theme.customFontName, !customName.isEmpty {
            resolvedFont = .custom(customName, size: theme.fontSize)
        } else {
            resolvedFont = .system(size: theme.fontSize, weight: fontWeight, design: theme.fontDesign.swiftUIDesign)
        }
        return font(resolvedFont)
            .tracking(tracking)
            .lineSpacing(theme.lineSpacing)
    }
}

struct ReaderStylePanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private func fontDisplayName(_ postScriptName: String) -> String {
        CTFontCopyFullName(CTFontCreateWithName(postScriptName as CFString, 12, nil)) as String
    }

    private let themes: [(name: String, foreground: String, background: String)] = [
        ("纸页", "#2A2723", "#F5EFE3"),
        ("清晨", "#1F2A2E", "#EEF5F1"),
        ("夜读", "#D8D2C4", "#1B1D1F"),
        ("墨屏", "#111111", "#F7F7F7")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读方式") {
                    Picker("翻页方式", selection: $store.readerTheme.effectiveReadingMode) {
                        ForEach(ReaderReadingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    if store.readerTheme.effectiveReadingMode == .paged {
                        Toggle("点击两侧均为下一页", isOn: $store.readerTheme.effectiveTapBothSidesToAdvance)
                        if store.readerTheme.effectiveTapBothSidesToAdvance {
                            Text("开启后，点击左右两侧均进入下一页；向右滑动或点击“上一页”仍可返回。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("点击正文中间可隐藏或显示工具栏；左右翻页时，轻点两侧或左右滑动翻页。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("排版") {
                    NavigationLink {
                        FontPickerView()
                            .environmentObject(store)
                    } label: {
                        HStack {
                            Text("字体")
                            Spacer()
                            Text(store.readerTheme.customFontName.map { fontDisplayName($0) } ?? store.readerTheme.fontDesign.title)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Text("字号")
                        Slider(value: $store.readerTheme.fontSize, in: 14...32, step: 1)
                        Text(Int(store.readerTheme.fontSize).formatted())
                            .monospacedDigit()
                    }
                    HStack {
                        Text("行距")
                        Slider(value: $store.readerTheme.lineSpacing, in: 2...20, step: 1)
                        Text(Int(store.readerTheme.lineSpacing).formatted())
                            .monospacedDigit()
                    }
                    HStack {
                        Text("字距")
                        Slider(value: $store.readerTheme.effectiveCharacterSpacing, in: 0...4, step: 0.5)
                        Text(store.readerTheme.effectiveCharacterSpacing.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("首行")
                        Slider(value: $store.readerTheme.effectiveFirstLineIndent, in: 0...4, step: 0.5)
                        Text("\(store.readerTheme.effectiveFirstLineIndent.formatted(.number.precision(.fractionLength(1))))字")
                            .monospacedDigit()
                    }
                    HStack {
                        Text("段距")
                        Slider(value: $store.readerTheme.paragraphSpacing, in: 4...28, step: 1)
                        Text(Int(store.readerTheme.paragraphSpacing).formatted())
                            .monospacedDigit()
                    }
                    Toggle("加粗正文", isOn: $store.readerTheme.isBold)
                    Button {
                        store.readerTheme.fontSize = ReaderTheme.classic.fontSize
                        store.readerTheme.lineSpacing = ReaderTheme.classic.lineSpacing
                        store.readerTheme.paragraphSpacing = ReaderTheme.classic.paragraphSpacing
                        store.readerTheme.effectiveCharacterSpacing = ReaderTheme.classic.effectiveCharacterSpacing
                        store.readerTheme.effectiveFirstLineIndent = ReaderTheme.classic.effectiveFirstLineIndent
                        store.readerTheme.fontDesign = ReaderTheme.classic.fontDesign
                        store.readerTheme.isBold = ReaderTheme.classic.isBold
                    } label: {
                        Label("恢复默认排版", systemImage: "arrow.counterclockwise")
                    }
                }

                Section("主题") {
                    HStack(spacing: 12) {
                        ForEach(themes, id: \.name) { theme in
                            Button {
                                store.readerTheme.name = theme.name
                                store.readerTheme.foregroundHex = theme.foreground
                                store.readerTheme.backgroundHex = theme.background
                            } label: {
                                VStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(hex: theme.background))
                                        .overlay {
                                            Text("Aa")
                                                .font(.headline)
                                                .foregroundStyle(Color(hex: theme.foreground))
                                        }
                                        .frame(width: 58, height: 44)
                                    Text(theme.name)
                                        .font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("阅读样式")
            .toolbar {
                Button("完成") {
                    store.save()
                    dismiss()
                }
            }
            #if os(macOS)
            .frame(width: 460, height: 430)
            #endif
        }
    }
}
