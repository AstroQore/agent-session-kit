import Foundation

/// A tool that ran and could not answer. Surfaces as an `isError` result the
/// model can read and react to, not as a JSON-RPC error the client swallows.
public struct MCPToolFailure: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// One tool as `tools/list` renders it.
public struct MCPTool: Sendable, Equatable {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: MCPJSON

    public init(name: String, title: String, description: String, inputSchema: MCPJSON) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
    }

    public var json: MCPJSON {
        .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema
        ])
    }
}

/// One resource as `resources/list` renders it.
public struct MCPResource: Sendable, Equatable {
    public let uri: String
    public let name: String
    public let title: String
    public let description: String
    public let mimeType: String

    public init(uri: String, name: String, title: String, description: String, mimeType: String) {
        self.uri = uri
        self.name = name
        self.title = title
        self.description = description
        self.mimeType = mimeType
    }

    public var json: MCPJSON {
        .object([
            "uri": .string(uri),
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "mimeType": .string(mimeType)
        ])
    }
}
