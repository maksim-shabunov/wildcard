import AppKit
import Foundation
import WildcardKit

/// The command-line face of Wildcard. Same rules as the MCP server: reads work
/// anywhere, writes become proposals that a person approves in the window.
struct CLI {

    let args: Args
    private var out: (String) -> Void = { print($0) }

    init(args: Args) { self.args = args }

    // MARK: - Dispatch

    func run() -> Int32 {
        switch args.command {
        case "help", "--help", "-h", "": usage(); return 0
        case "version", "--version": print("wildcard \(Version.string)"); return 0
        case "resolve": return resolve()
        case "status": return status()
        case "list": return list()
        case "apps": return apps()
        case "search": return search()
        case "set": return set()
        case "reset": return reset()
        case "history": return history()
        case "rollback": return rollback()
        case "snapshots": return snapshots()
        case "restore": return restore()
        case "proposals": return proposals()
        case "install": return install()
        default:
            fail("Unknown command “\(args.command)”. Try `wildcard help`.")
            return 2
        }
    }

    // MARK: - Read commands

    /// Answer what actually opens a target, in a process that has never asked
    /// before. The app uses this to verify a change, because `NSWorkspace`
    /// caches handler lookups for the life of a process.
    private func resolve() -> Int32 {
        var result: [String: String] = [:]
        for target in Service.parseTargets(args.rest) {
            guard let url = SystemState.systemHandler(for: target),
                  let id = Bundle(url: url)?.bundleIdentifier else { continue }
            result[target.key] = id.lowercased()
        }
        print(MCPServer.json(result))
        return 0
    }

    private func status() -> Int32 {
        let s = Service()
        let summary = s.summary()
        if args.json { print(MCPServer.json(summary)); return 0 }

        let total = summary["total_types"] as? Int ?? 0
        print("")
        print("  \(total) file and link types known")
        print("  \(summary["managed_by_rules"] as? Int ?? 0) managed by a rule")
        if let d = summary["drifted"] as? Int, d > 0 {
            print("  \(d) changed by something else — `wildcard list --drifted`")
        }
        if let n = summary["rule_not_applied_yet"] as? Int, n > 0 {
            print("  \(n) covered by a rule that has not been applied — `wildcard list --not-applied`")
        }
        print("  \(summary["nothing_opens_them"] as? Int ?? 0) nothing opens them at all")
        if let p = summary["pending_proposals"] as? Int, p > 0 {
            print("  \(p) waiting for your approval in Wildcard")
        }
        print("")
        return 0
    }

    private func list() -> Int32 {
        let s = Service()
        let filter: Service.Filter =
            args.flag("drifted") ? .drifted :
            args.flag("not-applied") ? .notApplied :
            args.flag("uncovered") ? .uncovered :
            args.flag("unhandled") ? .unhandled :
            args.flag("managed") ? .managed : .all

        let category = args.value("category")
        let rows = s.associations(category: category, targets: nil, filter: filter)

        if args.json { print(MCPServer.json(rows)); return 0 }
        if rows.isEmpty { print("Nothing matches."); return 0 }

        let width = rows.compactMap { ($0["display"] as? String)?.count }.max() ?? 10
        for r in rows {
            let display = (r["display"] as? String ?? "").padding(toLength: max(width, 8), withPad: " ", startingAt: 0)
            let app = r["opens_with"] as? String ?? "— nothing"
            let name = r["name"] as? String ?? ""
            let mark: String
            switch r["coverage"] as? String {
            case "drifted": mark = " (changed)"
            case "not_applied": mark = " (rule not applied)"
            default: mark = ""
            }
            print("  \(display)  \(app)\(mark)   \(name)")
        }
        print("\n  \(rows.count) shown")
        return 0
    }

    private func apps() -> Int32 {
        let s = Service()
        let list = s.applications()
        if args.json { print(MCPServer.json(list)); return 0 }
        for a in list {
            print("  \(a["name"] as? String ?? "")  —  \(a["bundle_id"] as? String ?? "")")
        }
        return 0
    }

    private func search() -> Int32 {
        let s = Service()
        let query = args.rest.joined(separator: " ")
        guard !query.isEmpty else { fail("What should I search for?"); return 2 }
        let hits = s.searchTypes(query, limit: args.value("limit").flatMap(Int.init) ?? 40)
        if args.json { print(MCPServer.json(hits)); return 0 }
        for h in hits {
            print("  \(h["display"] as? String ?? "")  \(h["name"] as? String ?? "")  — \(h["category_name"] as? String ?? "")")
        }
        return 0
    }

    private func history() -> Int32 {
        let s = Service()
        let entries = s.history(limit: args.value("limit").flatMap(Int.init) ?? 25)
        if args.json { print(MCPServer.json(entries)); return 0 }
        if entries.isEmpty { print("Nothing has been changed yet."); return 0 }
        for e in entries {
            let back = (e["rolled_back"] as? Bool ?? false) ? "  [rolled back]" : ""
            print("  \(e["id"] as? String ?? "")  \(e["title"] as? String ?? "")  — \(e["changed"] as? Int ?? 0) changed\(back)")
        }
        return 0
    }

    private func snapshots() -> Int32 {
        let s = Service()
        let list = s.snapshots()
        if args.json { print(MCPServer.json(list)); return 0 }
        for e in list {
            print("  \(e["id"] as? String ?? "")  \(e["name"] as? String ?? "")  — \(e["binding_count"] as? Int ?? 0) bindings")
        }
        return 0
    }

    private func proposals() -> Int32 {
        let s = Service()
        let list = s.queue.awaitingApproval().map(s.describe)
        // A file that cannot be read is not the same as an empty queue, and
        // reporting it as one is how a request quietly disappears.
        let unreadable = s.queue.unreadableFiles()
        if args.json {
            print(MCPServer.json(["waiting": list, "unreadable": unreadable]))
            return 0
        }
        if list.isEmpty && unreadable.isEmpty { print("Nothing waiting for approval."); return 0 }
        for p in list {
            print("  \(p["id"] as? String ?? "")  \(p["title"] as? String ?? "")  — \(p["summary"] as? String ?? "")")
        }
        for name in unreadable {
            print("  \(name)  could not be read — nothing from it will be applied")
        }
        return 0
    }

    // MARK: - Write commands (all of which only propose)

    private func set() -> Int32 {
        guard let app = args.value("app") else {
            fail("Which app? Use --app \"Cursor\".")
            return 2
        }
        return propose(app: app)
    }

    private func reset() -> Int32 { propose(app: nil) }

    private func propose(app: String?) -> Int32 {
        let s = Service()
        var targets: [Target] = []

        do {
            if let category = args.value("category") {
                targets += try s.targets(forCategory: category)
            }
            if let types = args.value("types") {
                targets += Service.parseTargets(types.split(separator: ",").map(String.init))
            }
            if let schemes = args.value("schemes") {
                targets += schemes.split(separator: ",").map { Target.urlScheme(String($0).lowercased()) }
            }
            targets += Service.parseTargets(args.rest)

            if let exclude = args.value("exclude") {
                let drop = Set(Service.parseTargets(exclude.split(separator: ",").map(String.init)))
                targets.removeAll { drop.contains($0) }
            }
            targets = Array(Set(targets)).sorted()

            guard !targets.isEmpty else {
                fail("Nothing selected. Use --category code, --types kt,rs or list them directly.")
                return 2
            }

            let title = args.value("title")
                ?? "\(args.value("category").map { s.engine.catalog.category(id: $0)?.name ?? $0 } ?? "\(targets.count) types") → \(app ?? "the macOS default")"

            // --print-only shows the diff without asking for anything.
            if args.flag("print-only") {
                let preview = s.engine.makeProposal(
                    title: title, targets: targets,
                    to: app.flatMap { s.engine.inventory.resolve($0) },
                    source: .cli)
                printDiff(preview, service: s, submitted: false)
                return 0
            }

            let proposal = try s.propose(.init(
                title: title, targets: targets, appQuery: app,
                source: .cli, note: args.value("reason")))

            printDiff(proposal, service: s)
            print("\n  Waiting for you to approve this in Wildcard…")

            guard let decided = s.queue.waitForDecision(proposal.id, timeout: 300) else {
                fail("The proposal disappeared before it was decided.")
                return 1
            }
            return report(decided)

        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return 1
        }
    }

    private func rollback() -> Int32 {
        guard let id = args.rest.first else { fail("Which change? `wildcard history` lists them."); return 2 }
        let s = Service()
        do {
            if args.flag("print-only") {
                printDiff(try s.previewRollback(historyID: id), service: s, submitted: false)
                return 0
            }
            let p = try s.proposeRollback(historyID: id)
            printDiff(p, service: s)
            print("\n  Waiting for you to approve this in Wildcard…")
            guard let decided = s.queue.waitForDecision(p.id, timeout: 300) else { return 1 }
            return report(decided)
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return 1
        }
    }

    private func restore() -> Int32 {
        guard let id = args.rest.first else { fail("Which snapshot? `wildcard snapshots` lists them."); return 2 }
        let s = Service()
        do {
            if args.flag("print-only") {
                printDiff(try s.previewRestore(snapshotID: id), service: s, submitted: false)
                return 0
            }
            let p = try s.proposeRestore(snapshotID: id)
            printDiff(p, service: s)
            print("\n  Waiting for you to approve this in Wildcard…")
            guard let decided = s.queue.waitForDecision(p.id, timeout: 300) else { return 1 }
            return report(decided)
        } catch {
            fail((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            return 1
        }
    }

    // MARK: - Output

    /// - Parameter submitted: false for `--print-only`, which composes the diff
    ///   and throws it away. The distinction only shows up in `--json`: a
    ///   proposal object carries `awaiting_approval` and an id from the moment it
    ///   is made, so printing one verbatim tells whatever is reading that a
    ///   request is sitting in Wildcard waiting for a person, when nothing was
    ///   queued and that id will never be found again.
    private func printDiff(_ p: Proposal, service: Service, submitted: Bool = true) {
        if args.json {
            var d = service.describe(p)
            if !submitted {
                d["status"] = "not_submitted"
                d["next_step"] = "This is a preview. Nothing was queued and no one has been asked to approve anything. Run the same command without --print-only to propose it."
                d.removeValue(forKey: "id")
                d.removeValue(forKey: "expires_at")
            }
            print(MCPServer.json(d))
            return
        }
        print("")
        print("  \(p.title)")
        print("  \(p.summaryLine)")
        if !p.warnings.isEmpty {
            print("")
            for w in p.warnings { print("  ! \(w.message)") }
        }
        let changing = p.effectiveItems
        if !changing.isEmpty {
            print("")
            let width = changing.map(\.target.display.count).max() ?? 8
            for item in changing.prefix(40) {
                let d = item.target.display.padding(toLength: width, withPad: " ", startingAt: 0)
                // Without the marker, pinning something macOS already happened to
                // open with that app reads as "TextEdit → TextEdit" — as if the
                // line were a mistake, rather than the point of the change.
                var from = item.fromApp?.name ?? "nothing"
                if item.fromApp != nil, item.fromOrigin == .implicit { from += " (inherited)" }
                var to = item.toApp?.name ?? "the macOS default"
                if item.toApp == nil, let back = item.expectedFallback { to += " (back to \(back.name))" }
                print("    \(d)  \(from) → \(to)")
            }
            if changing.count > 40 { print("    … and \(changing.count - 40) more") }
        }
    }

    private func report(_ p: Proposal) -> Int32 {
        switch p.status {
        case .applied:
            let failed = p.results.filter(\.outcome.isFailure)
            let applied = p.results.filter { $0.outcome == .applied }.count
            print("\n  Applied. \(applied) changed.")
            if !failed.isEmpty {
                print("  \(failed.count) did not take:")
                for f in failed {
                    if case .failed(let why) = f.outcome { print("    \(f.target.display)  \(why)") }
                }
                return 1
            }
            return 0
        case .rejected:
            print("\n  Rejected. Nothing changed.")
            return 1
        case .expired:
            print("\n  Expired without a decision. Nothing changed.")
            return 1
        case .failed:
            print("\n  Failed. Check Wildcard's history.")
            return 1
        default:
            print("\n  Still waiting. Approve it in Wildcard, or check `wildcard proposals`.")
            return 1
        }
    }

    // MARK: - Integration install

    private func install() -> Int32 {
        guard let helper = HelperLocator.url() ?? Bundle.main.executableURL else {
            fail("Could not work out where this binary lives.")
            return 1
        }
        let config: [String: Any] = ["mcpServers": ["wildcard": ["command": helper.path, "args": ["mcp"]]]]
        print("")
        print("  Add this to your MCP client's configuration:")
        print("")
        print(MCPServer.json(config))
        print("")
        print("  For Claude Code:  claude mcp add wildcard -- \(helper.path) mcp")
        print("")
        return 0
    }

    // MARK: - Help

    private func usage() {
        print("""

          wildcard — set which app opens which kind of file

          Looking around
            status                       counts: managed, drifting, unhandled
            list [--category code]       what opens what
                 [--drifted] [--not-applied] [--uncovered] [--unhandled] [--managed]
            search kotlin                find file types by name or extension
            apps                         installed applications and bundle ids
            history / snapshots          what has changed, and saved states
            proposals                    changes waiting for your approval

          Changing things
            set --app Cursor --category code
            set --app Zed --types kt,rs,toml
            set --app Safari --schemes http,https
            reset --category images      hand these back to macOS
            rollback <history-id>
            restore <snapshot-id>

            Every one of these shows the diff, then waits for you to approve it in
            the Wildcard window. Nothing is changed without that. Add --print-only
            to see the diff and stop there.

          Options
            --exclude md,mdx             leave these out
            --title "..."                what to call it in history
            --json                       machine-readable output

          For agents
            mcp                          run the MCP server on stdin/stdout
            install                      print the configuration to paste in

        """)
    }

    private func fail(_ message: String) {
        FileHandle.standardError.write(Data("wildcard: \(message)\n".utf8))
    }
}

/// A small argument parser. Not worth a dependency.
struct Args {
    let command: String
    let rest: [String]
    private let flags: Set<String>
    private let values: [String: String]

    var json: Bool { flags.contains("json") }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { values[name] }

    init(_ argv: [String]) {
        var argv = argv
        command = argv.isEmpty ? "" : argv.removeFirst()

        var rest: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]

        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    values[String(body[body.startIndex..<eq])] = String(body[body.index(after: eq)...])
                } else if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    // Boolean-only flags must not swallow the next word.
                    if Self.booleanFlags.contains(body) { flags.insert(body) }
                    else { values[body] = argv[i + 1]; i += 1 }
                } else {
                    flags.insert(body)
                }
            } else {
                rest.append(a)
            }
            i += 1
        }

        self.rest = rest
        self.flags = flags
        self.values = values
    }

    private static let booleanFlags: Set<String> = [
        "json", "drifted", "not-applied", "uncovered", "unhandled", "managed", "print-only", "help",
    ]
}
