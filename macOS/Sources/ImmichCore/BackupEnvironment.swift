import Foundation

public enum DotEnvError: LocalizedError, Equatable {
    case malformedLine(line: Int)
    case malformedQuotedValue(line: Int)

    public var errorDescription: String? {
        switch self {
        case let .malformedLine(line): return "Invalid .env entry on line \(line)."
        case let .malformedQuotedValue(line): return "Unclosed quoted value on line \(line)."
        }
    }
}

/// A deliberately non-shell `.env` parser. It supports the ordinary dotenv
/// grammar used by Immich and does not expand `$variables`, command substitutions,
/// backticks, or any other executable syntax.
public enum DotEnvParser {
    public static func parse(contents: String) throws -> [String: String] {
        var values: [String: String] = [:]
        // Keep blank records so a diagnostic line number remains the physical
        // line number in `.env`, rather than the count of nonblank entries.
        for (offset, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let candidate = line.hasPrefix("export ")
                ? String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
                : String(line)
            guard let equal = candidate.firstIndex(of: "=") else {
                throw DotEnvError.malformedLine(line: lineNumber)
            }
            let key = String(candidate[..<equal]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty,
                  key.unicodeScalars.allSatisfy({ $0 == "_" || CharacterSet.alphanumerics.contains($0) })
            else { throw DotEnvError.malformedLine(line: lineNumber) }
            let rawValue = String(candidate[candidate.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            values[key] = try parseValue(rawValue, line: lineNumber)
        }
        return values
    }

    public static func parse(url: URL) throws -> [String: String] {
        try parse(contents: String(contentsOf: url, encoding: .utf8))
    }

    private static func parseValue(_ rawValue: String, line: Int) throws -> String {
        guard let first = rawValue.first, first == "\"" || first == "'" else {
            return rawValue
        }
        guard rawValue.count >= 2, rawValue.last == first else {
            throw DotEnvError.malformedQuotedValue(line: line)
        }
        let body = String(rawValue.dropFirst().dropLast())
        if first == "'" { return body }
        var value = ""
        var escaped = false
        for character in body {
            if escaped {
                switch character {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "\\", "\"": value.append(character)
                default: value.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                value.append(character)
            }
        }
        if escaped { value.append("\\") }
        return value
    }
}
