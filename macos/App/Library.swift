import AVFoundation
import Foundation

struct VideoItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var size: Int64
    var created: Date
    /// The file lives in the app's library folder (added copies and camera recordings) and is
    /// deleted with the item. Items migrated from the first version only reference a file.
    var owned: Bool

    var url: URL { URL(fileURLWithPath: path) }
}

/// Video library: ~/Library/Application Support/Virtual Camera/{library.json, Videos/}
enum Library {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Virtual Camera", isDirectory: true)
    }()
    static let videosFolder = root.appendingPathComponent("Videos", isDirectory: true)
    private static let indexURL = root.appendingPathComponent("library.json")

    static func load() -> [VideoItem] {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([VideoItem].self, from: data) else { return [] }
        return items.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func save(_ items: [VideoItem]) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    static func makeItem(url: URL, name: String, owned: Bool) -> VideoItem {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return VideoItem(id: UUID().uuidString, name: name, path: url.path,
                         size: size, created: Date(), owned: owned)
    }

    /// A free file URL in the library folder for `name` (no extension) + `ext`.
    static func newFileURL(name: String, ext: String) -> URL {
        try? FileManager.default.createDirectory(at: videosFolder, withIntermediateDirectories: true)
        return uniqueURL(in: videosFolder, name: name, ext: ext)
    }

    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        let clean = sanitize(name)
        var url = folder.appendingPathComponent(clean).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(clean) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Video" : cleaned
    }

    /// Copies a user-picked file into the library. Throws a user-facing error for formats
    /// macOS can't play (e.g. WebM).
    static func importFile(_ source: URL) async throws -> VideoItem {
        let asset = AVURLAsset(url: source)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        guard playable && hasVideo else {
            throw LibraryError(message: source.pathExtension.lowercased() == "webm"
                ? String(localized: "WebM videos aren't supported on macOS. Use an MP4 or MOV file.")
                : String(localized: "This video can't be played. Use an MP4 or MOV file."))
        }
        let name = source.deletingPathExtension().lastPathComponent
        let dest = newFileURL(name: name, ext: source.pathExtension.isEmpty ? "mp4" : source.pathExtension)
        try await Task.detached { try FileManager.default.copyItem(at: source, to: dest) }.value
        return makeItem(url: dest, name: name, owned: true)
    }

    /// Paths saved by the first version of the app (UserDefaults "videos"), referenced in place.
    static func migrateLegacy(_ defaults: UserDefaults) -> [VideoItem] {
        guard let paths = defaults.stringArray(forKey: "videos") else { return [] }
        defaults.removeObject(forKey: "videos")
        return paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && $0.pathExtension.lowercased() != "webm" }
            .map { makeItem(url: $0, name: $0.deletingPathExtension().lastPathComponent, owned: false) }
    }
}

struct LibraryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
