import Foundation

struct FileRecord: Identifiable, Hashable {
    let id: Int64
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    let volume: String

    var url: URL { URL(fileURLWithPath: path) }
    var sizeText: String {
        if isDirectory { return "文件夹" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

enum ResultSort: String, CaseIterable, Identifiable {
    case name = "文件名"
    case kind = "文件类型"
    case size = "文件大小"
    case modified = "修改时间"

    var id: String { rawValue }
}

struct SearchQuery {
    var text = ""
    var extensionName: String?
    var pathPrefix: String?
    var kind: Kind?
    var minimumSize: Int64?
    var modifiedAfter: Date?

    enum Kind { case file, folder }
}

struct SearchQueryParser {
    func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()
        var terms: [String] = []
        for token in input.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let value = String(token)
            if let pair = value.splitOnce(separator: ":") {
                let key = pair.0.lowercased()
                let argument = String(pair.1)
                switch key {
                case "ext", "type": query.extensionName = argument.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                case "path": query.pathPrefix = NSString(string: argument).expandingTildeInPath
                case "kind": query.kind = argument.lowercased() == "folder" ? .folder : .file
                case "size":
                    if argument.hasPrefix(">"), let bytes = Self.parseBytes(String(argument.dropFirst())) { query.minimumSize = bytes }
                case "modified":
                    if let days = Int(argument.dropLast()), argument.last == "d" { query.modifiedAfter = Calendar.current.date(byAdding: .day, value: -days, to: Date()) }
                default: terms.append(value)
                }
            } else if value.hasPrefix("."), value.count > 1, !value.contains("/") {
                // A leading-dot query such as `.md` means file-extension search.
                query.extensionName = String(value.dropFirst()).lowercased()
            } else { terms.append(value) }
        }
        query.text = terms.joined(separator: " ")
        return query
    }

    private static func parseBytes(_ value: String) -> Int64? {
        let lower = value.lowercased()
        let units: [(String, Double)] = [("gb", 1_000_000_000), ("mb", 1_000_000), ("kb", 1_000), ("b", 1)]
        for (unit, multiplier) in units where lower.hasSuffix(unit) {
            return Int64((Double(lower.dropLast(unit.count)) ?? 0) * multiplier)
        }
        return Int64(lower)
    }
}

private extension String {
    func splitOnce(separator: Character) -> (Substring, Substring)? {
        guard let index = firstIndex(of: separator) else { return nil }
        return (prefix(upTo: index), suffix(from: index).dropFirst())
    }
}
