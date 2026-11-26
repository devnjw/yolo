import Foundation
import TrackingCore

private struct MCPServer {
    private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    let context: RecordingContext

    func respond(to line: String) -> [String: Any]? {
        let message: Any
        do {
            message = try JSONSerialization.jsonObject(with: Data(line.utf8), options: .fragmentsAllowed)
        } catch {
            return failure(id: NSNull(), code: -32700, message: "Parse error.")
        }
        guard let request = message as? [String: Any],
              request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return failure(id: NSNull(), code: -32600, message: "Invalid request.")
        }
        // Notifications, including notifications/initialized and cancellation, have no reply.
        guard let id = request["id"] else { return nil }
        guard id is String || id is Int else {
            return failure(id: NSNull(), code: -32600, message: "Invalid request ID.")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            guard let version = params["protocolVersion"] as? String else {
                return failure(id: id, code: -32602, message: "Missing protocolVersion.")
            }
            let versions = Self.protocolVersions
            result = [
                "protocolVersion": versions.contains(version) ? version : versions[0],
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "FocusTrace", "version": "1.1.0"]
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": FocusTraceTools.all.map(\.schema)]
        case "tools/call":
            guard let name = params["name"] as? String,
                  let tool = FocusTraceTools.all.first(where: { $0.name == name }) else {
                return failure(id: id, code: -32602, message: "Unknown tool.")
            }
            result = call(tool, arguments: params["arguments"] ?? [String: Any]())
        default:
            return failure(id: id, code: -32601, message: "Method not found.")
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func call(_ tool: MCPTool, arguments: Any) -> [String: Any] {
        guard let arguments = arguments as? [String: Any],
              arguments.keys.allSatisfy({ tool.properties[$0] != nil }),
              tool.required.allSatisfy({ arguments[$0] != nil }) else {
            return toolResult("Check the required and supported arguments in the tool schema.", isError: true)
        }
        do {
            let response = try tool.run(JSONSerialization.data(withJSONObject: arguments), context)
            return toolResult(String(decoding: response, as: UTF8.self))
        } catch is DecodingError {
            return toolResult("Check the argument types and values against the tool schema.", isError: true)
        } catch let error as QueryError {
            return toolResult(error.localizedDescription, isError: true)
        } catch {
            return toolResult("Could not read the FocusTrace database. Check that FocusTrace has initialized it and try again.", isError: true)
        }
    }

    private func toolResult(_ message: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": isError]
    }

    private func failure(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
private let context: RecordingContext
switch arguments.count {
case 0:
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    context = RecordingContext(databaseURL: directory.appendingPathComponent("FocusTrace/recording.sqlite3"),
                               backups: RecordingBackups(directory: directory.appendingPathComponent("FocusTrace Backups")))
case 2 where arguments[0] == "--database":
    context = RecordingContext(databaseURL: URL(fileURLWithPath: arguments[1]), backups: nil)
default:
    FileHandle.standardError.write(Data("Usage: focustrace-mcp [--database PATH]\n".utf8))
    exit(2)
}

private let server = MCPServer(context: context)
while let line = readLine() {
    if let response = server.respond(to: line) {
        let data = try JSONSerialization.data(withJSONObject: response)
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}
