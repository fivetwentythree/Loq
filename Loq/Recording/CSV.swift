import Foundation

enum CSV {
    /// Quote CSV metacharacters and keep user labels from becoming spreadsheet formulas.
    static func cell(_ value: String) -> String {
        let first = value.first(where: { !$0.isWhitespace })
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + value : value
        if safe.contains(where: { ",\"\r\n".contains($0) }) {
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return safe
    }
}
