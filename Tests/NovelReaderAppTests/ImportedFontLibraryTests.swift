import XCTest
import CoreText
@testable import NovelReaderApp

final class ImportedFontLibraryTests: XCTestCase {
    func testRenamedFontSelectionSurvivesRegistrationResetAndLibraryReload() throws {
        // A synthetic font with two simple triangle glyphs, unrelated to its filename.
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "renamed-reader-font", withExtension: "ttf", subdirectory: "Fixtures"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("Fonts")
        let installedURL = directory.appendingPathComponent(fixture.lastPathComponent)
        defer {
            CTFontManagerUnregisterFontsForURL(installedURL as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: root)
        }

        let library = ImportedFontLibrary(directory: directory)
        let installed = try library.installFont(from: fixture)
        XCTAssertEqual(installed.id, "MetaReadTestFont-Regular")
        XCTAssertEqual(installed.displayName, "MetaRead Test Font Regular")
        XCTAssertEqual(resolvedName(installed.id), installed.id)

        var theme = ReaderTheme.classic
        theme.customFontName = installed.id
        let storage = JSONLibraryStorage(fileURL: root.appendingPathComponent("library.json"))
        try storage.save(LibrarySnapshot(books: [], sources: [], nasConnections: [], downloads: [], readerTheme: theme))

        // Simulate losing process-scoped registrations when the app exits.
        XCTAssertTrue(CTFontManagerUnregisterFontsForURL(installedURL as CFURL, .process, nil))
        XCTAssertNotEqual(resolvedName(installed.id), installed.id)
        let savedSelection = try XCTUnwrap(storage.load().readerTheme.customFontName)

        // Startup must restore the font without opening FontPickerView.
        let restartedLibrary = ImportedFontLibrary(directory: directory)
        try Data("invalid font".utf8).write(to: directory.appendingPathComponent("broken.ttf"))
        let restored = restartedLibrary.registerImportedFonts()
        XCTAssertEqual(restored.map(\.id), [savedSelection])
        XCTAssertEqual(resolvedName(savedSelection), savedSelection)
        // Opening the picker and re-importing must also tolerate prior registration.
        XCTAssertEqual(restartedLibrary.registerImportedFonts().map(\.id), [savedSelection])
        XCTAssertEqual(try restartedLibrary.installFont(from: installedURL).id, savedSelection)
    }

    func testInvalidImportDoesNotReplaceExistingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("Fonts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("font.ttf")
        let destination = directory.appendingPathComponent("font.ttf")
        let original = Data("existing file".utf8)
        try original.write(to: destination)
        try Data("invalid replacement".utf8).write(to: source)

        XCTAssertThrowsError(try ImportedFontLibrary(directory: directory).installFont(from: source))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testNoImportedFontsOnFirstLaunch() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(ImportedFontLibrary(directory: directory).registerImportedFonts().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func resolvedName(_ name: String) -> String {
        autoreleasepool {
            CTFontCopyPostScriptName(CTFontCreateWithName(name as CFString, 12, nil)) as String
        }
    }
}
