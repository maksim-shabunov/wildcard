import Foundation

/// The MCP tool declarations.
///
/// Descriptions are written for an agent that has never seen this app: they say
/// what the tool does, and — for the write path — say plainly that it does not
/// apply anything. An agent that reads these should never tell someone their
/// file associations have been changed when they have only been proposed.
enum Tools {

    static let all: [[String: Any]] = [
        tool(
            "list_categories",
            "List every category of file type and link type Wildcard knows about, with how many types each holds and which app currently opens most of them. Start here.",
            properties: [:],
            required: []),

        tool(
            "get_category",
            "List every file type in one category, with the app that currently opens it and whether that was chosen deliberately.",
            properties: [
                "category": ["type": "string", "description": "Category id, for example \"code\" or \"images\"."],
            ],
            required: ["category"]),

        tool(
            "search_file_types",
            "Find file types by extension or by name, for example \"kotlin\", \"raw\", \"zst\". Use this instead of guessing which extensions belong to a language or format.",
            properties: [
                "query": ["type": "string", "description": "Extension prefix or words from the type's name."],
                "limit": ["type": "integer", "description": "Maximum results. Defaults to 60."],
            ],
            required: ["query"]),

        tool(
            "get_associations",
            "Show what currently opens file types and link types, and whether a rule covers them.",
            properties: [
                "category": ["type": "string", "description": "Limit to one category id."],
                "types": ["type": "array", "items": ["type": "string"],
                          "description": "Limit to specific types. Accepts \"kt\", \".kt\", \"ext:kt\" or \"scheme:http\"."],
                "filter": ["type": "string",
                           "enum": ["all", "managed", "uncovered", "drifted", "not_applied", "unhandled"],
                           "description": "\"drifted\" means something deliberately set a handler against a rule. "
                               + "\"not_applied\" means a rule covers it but has never been applied, so macOS is still choosing. "
                               + "\"unhandled\" means nothing opens it at all."],
            ],
            required: []),

        tool(
            "list_applications",
            "List the applications installed on this Mac, with their bundle identifiers, for use as the target of a change.",
            properties: [:],
            required: []),

        tool(
            "get_status",
            "A one-glance count of how many types are managed, drifting, uncovered or unhandled.",
            properties: [:],
            required: []),

        tool(
            "list_rules",
            "List the standing rules the person has set up — which categories should open with which app.",
            properties: [:],
            required: []),

        tool(
            "create_rule",
            """
            Save a standing rule: this category, or this list of types, should open with this app. \
            A rule records intent — it changes no file associations by itself, and Wildcard will \
            not apply it behind anyone's back. Its effect is that these types are shown as covered, \
            and that Wildcard notices later if something else changes them. To make the system \
            match the rule now, follow this with propose_changes.
            """,
            properties: [
                "app": ["type": "string", "description": "Application name, bundle id, or path."],
                "category": ["type": "string", "description": "Cover every type in this category."],
                "subgroup": ["type": "string",
                             "description": "With `category`, cover only this subgroup of it, for example \"code.shell\"."],
                "types": ["type": "array", "items": ["type": "string"],
                          "description": "Cover exactly these types instead of a category."],
                "exclude": ["type": "array", "items": ["type": "string"],
                            "description": "Types inside the scope that the rule should leave alone."],
                "name": ["type": "string", "description": "What to call it in the Rules list. One is written for you if omitted."],
                "priority": ["type": "integer", "description": "Higher wins where two rules claim the same type. Defaults to 0."],
                "enabled": ["type": "boolean", "description": "Defaults to true."],
            ],
            required: ["app"]),

        tool(
            "update_rule",
            "Change an existing rule — its app, scope, name, priority, exclusions or whether it is on. Only the fields given are changed. Like create_rule, this alters no file associations on its own.",
            properties: [
                "rule_id": ["type": "string", "description": "The id from list_rules."],
                "app": ["type": "string", "description": "Point the rule at a different application."],
                "category": ["type": "string", "description": "Replace the scope with this category."],
                "subgroup": ["type": "string", "description": "With `category`, scope to that subgroup."],
                "types": ["type": "array", "items": ["type": "string"],
                          "description": "Replace the scope with exactly these types."],
                "exclude": ["type": "array", "items": ["type": "string"],
                            "description": "Replace the rule's exclusions. Pass an empty array to clear them."],
                "name": ["type": "string"],
                "priority": ["type": "integer"],
                "enabled": ["type": "boolean", "description": "Switch the rule off without deleting it."],
            ],
            required: ["rule_id"]),

        tool(
            "delete_rule",
            "Delete a rule. Nothing about how files currently open changes — the types it covered simply stop being watched, and show as uncovered. The deleted rule is returned in full so it can be recreated if this was a mistake.",
            properties: [
                "rule_id": ["type": "string", "description": "The id from list_rules."],
            ],
            required: ["rule_id"]),

        tool(
            "propose_changes",
            """
            Propose that a set of file types or link types open with a given application. \
            THIS DOES NOT CHANGE ANYTHING. It creates a proposal, brings Wildcard to the front, \
            and waits for a person to approve it there. You cannot approve it. Report it as \
            proposed, never as done, until await_proposal or get_proposal says "applied".
            """,
            properties: [
                "app": ["type": "string",
                        "description": "Application name, bundle id, or path. Omit to hand these types back to whatever macOS would pick."],
                "category": ["type": "string", "description": "Propose for every type in this category."],
                "types": ["type": "array", "items": ["type": "string"],
                          "description": "Propose for these specific types. Combined with `category` if both are given."],
                "exclude": ["type": "array", "items": ["type": "string"],
                            "description": "Types to leave alone, for example keeping markdown out of a code-wide change."],
                "title": ["type": "string", "description": "Short description shown in the approval sheet and in history."],
                "reason": ["type": "string", "description": "Why this was asked for. Shown to the person deciding."],
            ],
            required: []),

        tool(
            "get_proposal",
            """
            Check a proposal's status and its full diff. Status is one of awaiting_approval, \
            applied, rejected, expired or failed. Read the `outcome` field before telling anyone \
            what happened — only "applied" means anything actually changed.
            """,
            properties: [
                "proposal_id": ["type": "string", "description": "The id returned by propose_changes."],
            ],
            required: ["proposal_id"]),

        tool(
            "await_proposal",
            """
            Wait until a person approves or rejects a proposal, then return the outcome including \
            per-type results. Returning does not mean it was approved — it may have been refused \
            or timed out. Read `outcome`, and report a refusal as a refusal.
            """,
            properties: [
                "proposal_id": ["type": "string", "description": "The id returned by propose_changes."],
                "timeout_seconds": ["type": "number", "description": "How long to wait. Defaults to 120, maximum 600."],
            ],
            required: ["proposal_id"]),

        tool(
            "list_history",
            "List changes that have been applied, newest first, with what each one changed and whether it can still be rolled back. Use this to answer \"what changed?\" — it is a read and queues nothing.",
            properties: [
                "limit": ["type": "integer", "description": "How many entries. Defaults to 25."],
            ],
            required: []),

        tool(
            "rollback",
            "Propose undoing a previous change, restoring exactly what each type opened with before. Like every write, this needs approval in Wildcard.",
            properties: [
                "history_id": ["type": "string", "description": "The id from list_history."],
            ],
            required: ["history_id"]),

        tool(
            "list_snapshots",
            "List saved snapshots of every file association, taken automatically before each change and manually on request.",
            properties: [:],
            required: []),

        tool(
            "restore_snapshot",
            "Propose returning every file type to how it was in a snapshot. Needs approval in Wildcard.",
            properties: [
                "snapshot_id": ["type": "string", "description": "The id from list_snapshots."],
            ],
            required: ["snapshot_id"]),
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}
