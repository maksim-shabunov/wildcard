import Foundation
import WildcardKit

/// Installing Wildcard's MCP server into the agents already on this Mac.
///
/// Each of these edits a file that belongs to another application, so nothing
/// here runs without being asked for, every write is preceded by a `.wildcard-backup`
/// copy, and existing entries are merged rather than replaced.
enum Integrations {

    struct Client: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
        let path: URL
        let format: Format

        enum Format { case json, toml }

        var isInstalled: Bool { FileManager.default.fileExists(atPath: path.path) }
    }

    static var helperPath: String {
        HelperLocator.url()?.path ?? "(build Wildcard.app to get a path)"
    }

    static var all: [Client] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            Client(id: "claude-code",
                   name: "Claude Code",
                   detail: "Command-line agent. Adds a user-wide server.",
                   path: home.appendingPathComponent(".claude.json"),
                   format: .json),
            Client(id: "claude-desktop",
                   name: "Claude Desktop",
                   detail: "The desktop app's MCP configuration.",
                   path: home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
                   format: .json),
            Client(id: "codex",
                   name: "Codex",
                   detail: "Adds an [mcp_servers.wildcard] block.",
                   path: home.appendingPathComponent(".codex/config.toml"),
                   format: .toml),
        ]
    }

    /// The block to paste anywhere else. Shown in Settings so nothing depends on
    /// Wildcard being able to write to somebody else's file.
    static var snippet: String {
        """
        {
          "mcpServers": {
            "wildcard": {
              "command": "\(helperPath)",
              "args": ["mcp"]
            }
          }
        }
        """
    }

    static var commandLineSnippet: String {
        "claude mcp add wildcard -- \(helperPath) mcp"
    }

    enum InstallError: LocalizedError {
        case noHelper
        case unreadable(String)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .noHelper:
                return "Could not find the wildcard helper. Build Wildcard.app so the helper sits inside it."
            case .unreadable(let p): return "Could not read \(p)."
            case .unwritable(let p): return "Could not write to \(p)."
            }
        }
    }

    /// Returns a sentence describing what happened, for the notice bar.
    @discardableResult
    static func install(into client: Client) throws -> String {
        guard let helper = HelperLocator.url() else { throw InstallError.noHelper }
        backup(client.path)

        switch client.format {
        case .json: try installJSON(client: client, helper: helper.path)
        case .toml: try installTOML(client: client, helper: helper.path)
        }
        return "Added Wildcard to \(client.name). Restart it to pick the server up."
    }

    static func isInstalled(in client: Client) -> Bool {
        guard let data = try? Data(contentsOf: client.path),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("\"wildcard\"") || text.contains("[mcp_servers.wildcard]")
    }

    // MARK: - Formats

    private static func installJSON(client: Client, helper: String) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: client.path.path) {
            guard let data = try? Data(contentsOf: client.path) else {
                throw InstallError.unreadable(client.path.path)
            }
            // An empty file is fine; malformed JSON is not — refuse rather than
            // overwrite something that might be a working configuration.
            if !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw InstallError.unreadable(client.path.path)
                }
                root = parsed
            }
        }

        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["wildcard"] = ["command": helper, "args": ["mcp"]]
        root["mcpServers"] = servers

        try FileManager.default.createDirectory(
            at: client.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let out = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw InstallError.unwritable(client.path.path)
        }
        try out.write(to: client.path, options: .atomic)
    }

    private static func installTOML(client: Client, helper: String) throws {
        var text = (try? String(contentsOf: client.path, encoding: .utf8)) ?? ""

        let block = """
        [mcp_servers.wildcard]
        command = "\(helper)"
        args = ["mcp"]
        """

        if let range = text.range(of: "[mcp_servers.wildcard]") {
            // Replace the existing block up to the next table header.
            let after = text[range.upperBound...]
            let end = after.range(of: "\n[")?.lowerBound ?? text.endIndex
            text.replaceSubrange(range.lowerBound..<end, with: block)
        } else {
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += (text.isEmpty ? "" : "\n") + block + "\n"
        }

        try FileManager.default.createDirectory(
            at: client.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: client.path, atomically: true, encoding: .utf8)
    }

    private static func backup(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("wildcard-backup")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    // MARK: - Command line convenience

    static var symlinkPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/wildcard")
    }

    static var symlinkExists: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath.path)) != nil
    }

    @discardableResult
    static func installSymlink() throws -> String {
        guard let helper = HelperLocator.url() else { throw InstallError.noHelper }
        let fm = FileManager.default
        try fm.createDirectory(at: symlinkPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: symlinkPath)
        try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: helper)
        return "Linked \(symlinkPath.path). Add ~/.local/bin to your PATH if it is not there already."
    }
}
