import Foundation

/// Typed access to one `tools/call` argument object.
///
/// Every failure here is `invalidParams` rather than a tool error, because
/// the caller sent something the schema already ruled out — an agent fixes
/// that by re-reading the schema, not by reasoning about the answer.
///
/// Hosts add their own domain accessors as an extension; `toolName` and
/// `present(_:)` are public exactly so those extensions can produce the same
/// error wording as the built-in ones.
public struct MCPArguments {
    public let toolName: String
    public let fields: [String: MCPJSON]

    /// - Throws: `invalidParams` when `raw` is not an object, or when it
    ///   carries a key the tool's schema does not declare. Rejecting unknown
    ///   keys is deliberate: a misspelled filter that is silently ignored
    ///   answers a question nobody asked.
    public init(tool: MCPTool, raw: MCPJSON?) throws {
        self.toolName = tool.name
        switch raw {
        case .none, .some(.null):
            self.fields = [:]
        case let .some(value):
            guard let object = value.objectValue else {
                throw MCPRPCError.invalidParams("'arguments' for \(tool.name) must be an object.")
            }
            self.fields = object
        }
        let allowed = Set(tool.inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? [])
        let unknown = fields.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw MCPRPCError.invalidParams(
                "\(tool.name) does not accept \(unknown.map { "'\($0)'" }.joined(separator: ", "))."
                    + " Accepted: \(allowed.sorted().map { "'\($0)'" }.joined(separator: ", "))."
            )
        }
    }

    /// The value under `key`, treating an explicit `null` as absent.
    public func present(_ key: String) -> MCPJSON? {
        guard let value = fields[key], !value.isNull else { return nil }
        return value
    }

    public func optionalString(_ key: String) throws -> String? {
        guard let value = present(key) else { return nil }
        guard let string = value.stringValue else {
            throw MCPRPCError.invalidParams("\(toolName): '\(key)' must be a string.")
        }
        return string
    }

    public func requiredString(_ key: String) throws -> String {
        guard let value = try optionalString(key) else {
            throw MCPRPCError.invalidParams("\(toolName): '\(key)' is required.")
        }
        return value
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        guard let value = present(key) else { return nil }
        guard let flag = value.boolValue else {
            throw MCPRPCError.invalidParams("\(toolName): '\(key)' must be true or false.")
        }
        return flag
    }

    public func optionalInt(_ key: String, minimum: Int, maximum: Int) throws -> Int? {
        guard let value = present(key) else { return nil }
        guard let number = value.intValue else {
            throw MCPRPCError.invalidParams("\(toolName): '\(key)' must be a whole number.")
        }
        guard number >= minimum, number <= maximum else {
            throw MCPRPCError.invalidParams(
                "\(toolName): '\(key)' must be between \(minimum) and \(maximum); got \(number)."
            )
        }
        return number
    }

    public func optionalDate(_ key: String) throws -> Date? {
        guard let raw = try optionalString(key) else { return nil }
        guard let date = MCPDateParsing.parse(raw) else {
            throw MCPRPCError.invalidParams(
                "\(toolName): '\(key)' must be an ISO-8601 instant "
                    + "(2026-08-01 or 2026-08-01T09:30:00Z); got '\(raw)'."
            )
        }
        return date
    }

    public func requiredEnum<T: RawRepresentable & CaseIterable>(
        _ key: String,
        _ type: T.Type
    ) throws -> T where T.RawValue == String {
        guard let value = try optionalEnum(key, type) else {
            throw MCPRPCError.invalidParams("\(toolName): '\(key)' is required.")
        }
        return value
    }

    public func optionalEnum<T: RawRepresentable & CaseIterable>(
        _ key: String,
        _ type: T.Type
    ) throws -> T? where T.RawValue == String {
        guard let raw = try optionalString(key) else { return nil }
        guard let value = T(rawValue: raw) else {
            throw MCPRPCError.invalidParams(
                "\(toolName): '\(key)' must be one of "
                    + "\(T.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")); got '\(raw)'."
            )
        }
        return value
    }

    /// A list filter. An explicitly empty list stays empty rather than
    /// collapsing to `nil`: a store reads that as "nothing matches", and
    /// silently widening it to "everything" would answer a question nobody
    /// asked.
    public func optionalEnumList<T: RawRepresentable & CaseIterable>(
        _ key: String,
        _ type: T.Type
    ) throws -> [T]? where T.RawValue == String {
        guard let value = present(key) else { return nil }
        guard let raws = value.stringListValue else {
            throw MCPRPCError.invalidParams("\(toolName): '\(key)' must be an array of strings.")
        }
        var out: [T] = []
        for raw in raws {
            guard let parsed = T(rawValue: raw) else {
                throw MCPRPCError.invalidParams(
                    "\(toolName): '\(key)' contains '\(raw)', which is not one of "
                        + "\(T.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", "))."
                )
            }
            out.append(parsed)
        }
        return out
    }

    public func optionalStringList(_ key: String) throws -> [String]? {
        guard let value = present(key) else { return nil }
        guard let raws = value.stringListValue else {
            throw MCPRPCError.invalidParams("\(toolName): '\(key)' must be an array of strings.")
        }
        return raws
    }
}

/// ISO-8601 in the two spellings clients actually send, plus a bare date.
public enum MCPDateParsing {
    private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetDateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// A bare `YYYY-MM-DD` means midnight *local*: an agent asking for
    /// "since 2026-08-01" means the user's own first of August, not UTC's.
    private static let calendarDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = withFractionalSeconds.date(from: trimmed) { return date }
        if let date = internetDateTime.date(from: trimmed) { return date }
        return calendarDay.date(from: trimmed)
    }
}
