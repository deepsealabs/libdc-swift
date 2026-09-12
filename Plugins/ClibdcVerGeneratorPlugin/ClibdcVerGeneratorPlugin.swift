import PackagePlugin
import Foundation

@main
struct ClibdcVerGeneratorPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let libdcPath = context.package.directory.appending("libdivecomputer").string

        let content = try String(contentsOf: URL(filePath: libdcPath + "/configure.ac"), encoding: .utf8)
        let majorRE = #/\[dc_version_major\],\[(\d+)\]/#
        let minorRE = #/\[dc_version_minor\],\[(\d+)\]/#
        let microRE = #/\[dc_version_micro\],\[(\d+)\]/#
        let suffixRE = #/\[dc_version_suffix\],\[(\w+)\]/#
        let major = parseVer(cont: content, re: majorRE)
        let minor = parseVer(cont: content, re: minorRE)
        let micro = parseVer(cont: content, re: microRE)
        let suffix = parseVerOpt(cont: content, re: suffixRE)

        var version = "\(major).\(minor).\(micro)"
        if suffix != nil {
            version += "-\(suffix!)"
        }

        var headerTemplate = try String(contentsOf: URL(filePath: libdcPath + "/include/libdivecomputer/version.h.in"), encoding: .utf8)
        var regex = Regex(#/@DC_VERSION@/#)
        headerTemplate = headerTemplate.replacing(regex, with: version)
        regex = Regex(#/@DC_VERSION_MAJOR@/#)
        headerTemplate = headerTemplate.replacing(regex, with: major)
        regex = Regex(#/@DC_VERSION_MINOR@/#)
        headerTemplate = headerTemplate.replacing(regex, with: minor)
        regex = Regex(#/@DC_VERSION_MICRO@/#)
        headerTemplate = headerTemplate.replacing(regex, with: micro)
        try headerTemplate.write(to: URL(filePath: libdcPath + "/include/libdivecomputer/version.h"), atomically: true, encoding: .utf8)
    }

    func parseVer(cont: String, re: Regex<(Substring, Substring)>) -> String {
        if let match = cont.firstMatch(of: re) {
            return String(match.1)
        }
        fputs("Error: version not set in configure.ac\n", stderr)
        exit(EXIT_FAILURE)
    }

    func parseVerOpt(cont: String, re: Regex<(Substring, Substring)>) -> String? {
        if let match = cont.firstMatch(of: re) {
            return String(match.1)
        }
        return nil
    }
}
