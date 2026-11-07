#if os(macOS)
import AppKit
import Foundation

struct FITListing: Hashable {
    var activityPath: String?
    var fitCount = 0
    var totalBytes: Int64 = 0
    var newest: Date?
    var error: String?

    var summary: String {
        if let error { return error }
        guard let activityPath else { return "no GARMIN/Activity folder" }
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(fitCount) .fit in \(activityPath) (\(size))"
    }
}

struct GarminResult: Hashable {
    var volumePath: String
    var listing: FITListing
    var bookmarkCreate: ProbeStep
    var bookmarkResolve: ProbeStep?
    var resolvedListing: FITListing?
}

enum GarminProbe {
    static let bookmarkKey = "garminVolumeBookmark"

    static var hasSavedBookmark: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    @MainActor
    static func chooseVolume() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        panel.message = "Choose the Garmin Descent volume, or any folder that contains GARMIN/Activity."
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func probe(_ url: URL) -> GarminResult {
        let listing = listFIT(in: url)
        var result = GarminResult(volumePath: url.path, listing: listing, bookmarkCreate: .ok("bookmark create"))
        do {
            // Import only reads, and a read-only scope keeps the user-selected.read-only control comparable.
            let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
            let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            result.bookmarkCreate = .ok("bookmark create", "\(data.count) bytes, .withSecurityScope + read-only")
            let resolved = resolve(data)
            result.bookmarkResolve = resolved.step
            result.resolvedListing = resolved.listing
        } catch {
            result.bookmarkCreate = .failed("bookmark create", describe(error))
        }
        return result
    }

    static func resolveSaved() -> (step: ProbeStep, listing: FITListing?) {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return (.skipped("bookmark resolve", "no saved bookmark"), nil)
        }
        return resolve(data)
    }

    private static func resolve(_ data: Data) -> (step: ProbeStep, listing: FITListing?) {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let listing = listFIT(in: url)
            let detail = "\(url.path), stale \(stale), startAccessing \(accessing)"
            return (accessing ? .ok("bookmark resolve", detail) : .failed("bookmark resolve", detail), listing)
        } catch {
            return (.failed("bookmark resolve", describe(error)), nil)
        }
    }

    static func listFIT(in root: URL) -> FITListing {
        let fileManager = FileManager.default
        let candidates = ["GARMIN/Activity", "Garmin/Activity", "Activity", ""].map {
            $0.isEmpty ? root : root.appendingPathComponent($0, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        guard let activity = candidates.first(where: {
            fileManager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && ($0 != root || $0.lastPathComponent.caseInsensitiveCompare("Activity") == .orderedSame)
        }) else {
            return FITListing()
        }
        do {
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
            let files = try fileManager.contentsOfDirectory(at: activity, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                .filter { $0.pathExtension.caseInsensitiveCompare("fit") == .orderedSame }
            var listing = FITListing(activityPath: activity.path, fitCount: files.count)
            for file in files {
                let values = try? file.resourceValues(forKeys: Set(keys))
                listing.totalBytes += Int64(values?.fileSize ?? 0)
                if let date = values?.contentModificationDate, date > (listing.newest ?? .distantPast) {
                    listing.newest = date
                }
            }
            return listing
        } catch {
            return FITListing(activityPath: activity.path, error: describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }
}
#endif
