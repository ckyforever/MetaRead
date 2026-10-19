import Foundation
import CoreText

struct ImportedReaderFont: Identifiable {
    let id: String // PostScript name, independent of the filename.
    let displayName: String
}

struct ImportedFontLibrary {
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Fonts", isDirectory: true)) {
        self.directory = directory
    }

    /// Process-scoped registrations must be restored before the reader renders.
    @discardableResult
    func registerImportedFonts() -> [ImportedReaderFont] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var seenNames: Set<String> = []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
            .flatMap { (try? registerFont(at: $0)) ?? [] }
            .filter { seenNames.insert($0.id).inserted }
    }

    func installFont(from sourceURL: URL) throws -> ImportedReaderFont {
        // Validate before replacing an existing file with the same filename.
        _ = try fontOptions(at: sourceURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
        if sourceURL.standardizedFileURL != destination.standardizedFileURL {
            try Data(contentsOf: sourceURL).write(to: destination, options: .atomic)
        }
        return try registerFont(at: destination)[0]
    }

    private func registerFont(at url: URL) throws -> [ImportedReaderFont] {
        let fonts = try fontOptions(at: url)
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            guard let registrationError = error?.takeRetainedValue() else {
                throw FontError.registrationFailed
            }
            // Opening the picker after startup can register the same file again.
            guard CFErrorGetDomain(registrationError) == kCTFontManagerErrorDomain,
                  CFErrorGetCode(registrationError) == CTFontManagerError.alreadyRegistered.rawValue else {
                throw registrationError
            }
        }
        return fonts
    }

    private func fontOptions(at url: URL) throws -> [ImportedReaderFont] {
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        let fonts = descriptors.compactMap { descriptor -> ImportedReaderFont? in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  !name.isEmpty else { return nil }
            let displayName = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String
            return ImportedReaderFont(id: name, displayName: displayName ?? name)
        }
        guard !fonts.isEmpty else { throw FontError.invalidFile }
        return fonts
    }

    private enum FontError: LocalizedError {
        case invalidFile
        case registrationFailed

        var errorDescription: String? {
            switch self {
            case .invalidFile: "无法读取字体，请选择有效的 TTF / OTF 文件。"
            case .registrationFailed: "注册字体失败，请重新导入。"
            }
        }
    }
}
