import Foundation
import WildcardKit

/// A Model Context Protocol server over stdio, written without dependencies.
///
/// The shape of it matters more than the code: every read tool works, and the
/// only tool that touches the system is `propose_changes`, which queues a
/// proposal and returns. An agent can compose any change it likes; a person
/// still has to approve it in the window. There is no auto-approve setting to
/// find, and no argument that turns one on.
final class MCPServer {

    private let service: Service
    private let protocolVersion = "2025-06-18"
    private var clientName = "an agent"

    init(service: Service) {
        self.service = service
    }

    // MARK: - Run loop

    func run() {
        // Line-delimited JSON-RPC on stdin. Reading by line keeps this simple and
        // matches what every current MCP client sends.
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(error: -32700, message: "Could not parse that as JSON.", id: nil)
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: [String: Any]) {
        let id = message["id"]
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications carry no id and expect no reply.
        if id == nil {
            if method == "notifications/initialized" { return }
            return
        }

        do {
            let result = try dispatch(method: method, params: params)
            send(result: result, id: id)
        } catch let e as Service.ServiceError {
            send(error: -32000, message: e.errorDescription ?? "Something went wrong.", id: id)
        } catch {
            send(error: -32603, message: String(describing: error), id: id)
        }
    }

    private func dispatch(method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any],
               let name = info["name"] as? String { clientName = name }
            return [
                "protocolVersion": protocolVersion,
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["listChanged": false, "subscribe": false],
                    "prompts": ["listChanged": false],
                ],
                "serverInfo": ["name": "wildcard", "version": Version.string],
                "instructions": Self.instructions,
            ]

        case "ping":
            return [:]

        case "tools/list":
            return ["tools": Tools.all]

        case "tools/call":
            // Checked here rather than at launch, and read fresh from disk each
            // time: the switch in Settings has to mean something the moment it is
            // flicked, not the next time the client restarts this process.
            guard service.agentAccessEnabled else { throw Service.ServiceError.agentAccessDisabled }
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return try call(tool: name, args: args)

        case "resources/list":
            return ["resources": [
                [
                    "uri": "wildcard://catalog",
                    "name": "File type catalog",
                    "description": "Every category Wildcard knows, with each file type and its plain-English name.",
                    "mimeType": "application/json",
                ],
                [
                    "uri": "wildcard://associations",
                    "name": "Current associations",
                    "description": "What currently opens every known file type and link type on this Mac.",
                    "mimeType": "application/json",
                ],
            ]]

        case "resources/read":
            guard service.agentAccessEnabled else { throw Service.ServiceError.agentAccessDisabled }
            let uri = params["uri"] as? String ?? ""
            let payload: Any
            switch uri {
            case "wildcard://catalog": payload = service.categories()
            case "wildcard://associations": payload = service.associations(category: nil, targets: nil, filter: .all)
            default: throw Service.ServiceError.noSuchCategory(uri)
            }
            return ["contents": [[
                "uri": uri,
                "mimeType": "application/json",
                "text": Self.json(payload),
            ]]]

        case "prompts/list":
            return ["prompts": [[
                "name": "set_default_apps",
                "description": "How to turn a plain-language request into a Wildcard proposal.",
                "arguments": [[
                    "name": "request",
                    "description": "What the person asked for, in their own words.",
                    "required": true,
                ]],
            ]]]

        case "prompts/get":
            let args = params["arguments"] as? [String: Any] ?? [:]
            let request = args["request"] as? String ?? ""
            return [
                "description": "Resolve a request into concrete file types and propose the change.",
                "messages": [[
                    "role": "user",
                    "content": ["type": "text", "text": Self.promptBody(request)],
                ]],
            ]

        default:
            throw NSError(domain: "wildcard", code: -32601,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown method \(method)."])
        }
    }

    // MARK: - Tools

    private func call(tool: String, args: [String: Any]) throws -> Any {
        switch tool {

        case "list_categories":
            return text(service.categories())

        case "get_category":
            let id = args["category"] as? String ?? ""
            guard let c = service.category(id: id) else { throw Service.ServiceError.noSuchCategory(id) }
            return text(c)

        case "search_file_types":
            let q = args["query"] as? String ?? ""
            let limit = args["limit"] as? Int ?? 60
            return text(service.searchTypes(q, limit: limit))

        case "get_associations":
            let filter = Service.Filter(rawValue: args["filter"] as? String ?? "all") ?? .all
            let category = args["category"] as? String
            let targets = (args["types"] as? [String]).map(Service.parseTargets)
            return text(service.associations(category: category, targets: targets, filter: filter))

        case "list_applications":
            return text(service.applications())

        case "get_status":
            return text(service.summary())

        case "list_rules":
            return text(service.rules())

        case "create_rule":
            let rule = try service.createRule(ruleRequest(args))
            return text([
                "rule": service.describe(rule),
                "note": "Saved. No file association changed — a rule says what should happen, and "
                    + "Wildcard does not apply one without being asked.",
                "next_step": "To make this Mac match the rule now, call propose_changes with the same "
                    + "scope and app. That still needs approval in Wildcard.",
            ])

        case "update_rule":
            let id = args["rule_id"] as? String ?? ""
            let rule = try service.updateRule(id: id, ruleRequest(args))
            return text([
                "rule": service.describe(rule),
                "note": "Updated. No file association changed.",
            ])

        case "delete_rule":
            let id = args["rule_id"] as? String ?? ""
            let deleted = try service.deleteRule(id: id)
            return text([
                "deleted": service.describe(deleted),
                "note": "Deleted. Nothing about how those types open has changed — they are simply "
                    + "no longer covered by a rule. Pass this back to create_rule to restore it.",
            ])

        case "propose_changes":
            let proposal = try buildProposal(args)
            return text([
                "proposal": service.describe(proposal),
                "next_step": "Nothing has changed yet. \(clientName) cannot approve this — "
                    + "Wildcard has been brought forward so it can be reviewed and approved there. "
                    + "Use await_proposal to wait for the decision, or get_proposal to check later.",
            ])

        case "get_proposal":
            let id = args["proposal_id"] as? String ?? ""
            guard let p = service.queue.get(id) else { throw Service.ServiceError.noSuchProposal(id) }
            // Same shape as propose_changes deliberately. An agent that read
            // `proposal.status` when it asked should not have to read `status`
            // when it checks back.
            return text(["proposal": service.describe(p), "outcome": outcome(p)])

        case "await_proposal":
            let id = args["proposal_id"] as? String ?? ""
            let timeout = min(args["timeout_seconds"] as? Double ?? 120, 600)
            guard let p = service.queue.waitForDecision(id, timeout: timeout) else {
                throw Service.ServiceError.noSuchProposal(id)
            }
            return text(["proposal": service.describe(p), "outcome": outcome(p)])

        case "list_history":
            return text(service.history(limit: args["limit"] as? Int ?? 25))

        case "rollback":
            let id = args["history_id"] as? String ?? ""
            let p = try service.proposeRollback(historyID: id)
            return text([
                "proposal": service.describe(p),
                "next_step": "Nothing has been rolled back yet — this needs approval in Wildcard.",
            ])

        case "list_snapshots":
            return text(service.snapshots())

        case "restore_snapshot":
            let id = args["snapshot_id"] as? String ?? ""
            let p = try service.proposeRestore(snapshotID: id)
            return text([
                "proposal": service.describe(p),
                "next_step": "Nothing has been restored yet — this needs approval in Wildcard.",
            ])

        default:
            throw NSError(domain: "wildcard", code: -32602,
                          userInfo: [NSLocalizedDescriptionKey: "Unknown tool \(tool)."])
        }
    }

    /// What actually happened, in a sentence meant to be repeated to a person.
    ///
    /// The failure this guards against is an agent glancing at a status field
    /// and announcing "done" for a proposal that was refused, or one still
    /// sitting unanswered. Only `applied` gets a sentence that says anything
    /// changed, and a partial application says so rather than rounding up.
    private func outcome(_ p: Proposal) -> String {
        switch p.status {
        case .awaitingApproval:
            return "Still waiting for a person to approve this in Wildcard. Nothing has changed. "
                + "Do not report this as done."
        case .approved:
            return "Approved and being applied now. Check again for the per-type results."
        case .applied:
            let failed = p.results.filter(\.outcome.isFailure).count
            let changed = p.results.filter { $0.outcome == .applied }.count
            if failed > 0 {
                return "Partly applied: \(changed) changed, \(failed) failed. Report the failures — "
                    + "the per-type results say why each one did not take."
            }
            return "Applied: \(changed) file \(changed == 1 ? "type" : "types") changed. "
                + "This can be undone from History in Wildcard, or with the rollback tool."
        case .rejected:
            return "Refused in Wildcard. Nothing was changed. Do not try to apply it another way."
        case .expired:
            return "Expired before anyone answered it, so nothing was changed. "
                + "Propose it again if it is still wanted."
        case .failed:
            return "Failed. Nothing, or only part, was changed — the per-type results say which."
        }
    }

    /// Read a rule out of the tool arguments.
    ///
    /// A missing scope means two different things and `Service` tells them apart:
    /// on create it is an error, on update it means "leave the scope alone", so
    /// "point rule X at Zed" cannot accidentally narrow what X covers.
    private func ruleRequest(_ args: [String: Any]) -> Service.RuleRequest {
        var scope: Rule.Scope?
        if let category = args["category"] as? String, !category.isEmpty {
            if let subgroup = args["subgroup"] as? String, !subgroup.isEmpty {
                scope = .subgroup(categoryID: category, subgroupID: subgroup)
            } else {
                scope = .category(id: category)
            }
        } else if let types = args["types"] as? [String], !types.isEmpty {
            scope = .explicit(targets: Array(Set(Service.parseTargets(types))).sorted())
        }

        return Service.RuleRequest(
            name: args["name"] as? String,
            scope: scope,
            appQuery: (args["app"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            priority: args["priority"] as? Int,
            isEnabled: args["enabled"] as? Bool,
            exclusions: (args["exclude"] as? [String]).map(Service.parseTargets))
    }

    private func buildProposal(_ args: [String: Any]) throws -> Proposal {
        var targets: [Target] = []
        if let category = args["category"] as? String {
            targets += try service.targets(forCategory: category)
        }
        if let list = args["types"] as? [String] {
            targets += Service.parseTargets(list)
        }
        targets = Array(Set(targets)).sorted()

        if let excluded = args["exclude"] as? [String] {
            let drop = Set(Service.parseTargets(excluded))
            targets.removeAll { drop.contains($0) }
        }

        let app = args["app"] as? String
        let title = (args["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultTitle(targets: targets, app: app, category: args["category"] as? String)

        return try service.propose(.init(
            title: title,
            targets: targets,
            appQuery: app,
            source: .mcp(client: clientName),
            note: args["reason"] as? String))
    }

    private func defaultTitle(targets: [Target], app: String?, category: String?) -> String {
        let destination = app ?? "the macOS default"
        if let category, let name = service.engine.catalog.category(id: category)?.name {
            return "\(name) → \(destination)"
        }
        return "\(targets.count) \(targets.count == 1 ? "type" : "types") → \(destination)"
    }

    // MARK: - Replies

    /// MCP tool results are text content; JSON in a text block is what clients expect.
    private func text(_ payload: Any) -> [String: Any] {
        ["content": [["type": "text", "text": Self.json(payload)]], "isError": false]
    }

    private func send(result: Any, id: Any?) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func send(error code: Int, message: String, id: Any?) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(),
               "error": ["code": code, "message": message]])
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    static func json(_ payload: Any) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8)
        else { return "[]" }
        return s
    }

    // MARK: - Guidance for the agent

    static let instructions = """
    Wildcard manages which application opens which kind of file, and which app \
    opens which kind of link, on this Mac.

    Work in categories, not one extension at a time. To answer a request like \
    "send everything code-related to Cursor but keep markdown in Obsidian":

      1. list_categories to see what exists, or search_file_types to find \
    specific ones.
      2. get_associations to see what currently opens them.
      3. propose_changes with a category (or an explicit list of types).

    propose_changes does not change anything. It queues a proposal and brings \
    Wildcard forward so a person can review the exact diff and approve it. There \
    is no way for you to approve it. Use await_proposal to find out what they \
    decided.

    Everything applied this way appears in Wildcard's history and can be rolled \
    back with the rollback tool, which is itself a proposal.
    """

    static func promptBody(_ request: String) -> String {
        """
        Here is what I want: \(request)

        Use the Wildcard tools to do it:
        - Resolve my request into concrete file types using list_categories and \
        search_file_types. Do not guess extensions — the catalog already knows the \
        obscure ones.
        - Check get_associations first so you can tell me what is already correct.
        - Call propose_changes once per distinct destination app.
        - Tell me the proposal id and what it will change. I will approve it in \
        Wildcard myself.
        """
    }
}

enum Version {
    static let string = WildcardVersion.current
}
