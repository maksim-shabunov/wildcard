import Foundation

/// Where a change came from. Recorded on every proposal and every history entry
/// so "what changed my `.md` handler?" always has an answer.
public enum ChangeSource: Hashable, Codable, Sendable {
    case gui
    case cli
    case mcp(client: String)
    case ruleEnforcement
    case autoAdopt
    case rollback

    public var label: String {
        switch self {
        case .gui: return "Wildcard"
        case .cli: return "Command line"
        case .mcp(let c): return c.isEmpty ? "An agent" : c
        case .ruleEnforcement: return "Rule restored"
        case .autoAdopt: return "Adopted automatically"
        case .rollback: return "Rollback"
        }
    }

    public var isExternal: Bool {
        switch self {
        case .cli, .mcp: return true
        default: return false
        }
    }
}

/// One line of a diff: this target, from this app, to that app.
public struct ChangeItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String { target.key }

    public var target: Target
    public var fromApp: AppRef?
    public var fromOrigin: BindingOrigin
    public var toApp: AppRef?          // nil means "hand it back to macOS"
    /// True when the system already resolves this target to `toApp`.
    public var isNoOp: Bool
    /// Other extensions that would move with this one because they share a
    /// content type and no narrower binding is available.
    public var collateral: [String]
    /// When `toApp` is nil, the app this is expected to fall back to.
    ///
    /// Undo removes a binding rather than pinning the previous app, which is
    /// the faithful thing to do but reads as "→ macOS default" — true, and no
    /// help to someone deciding. This carries what was recorded as opening it
    /// before, so the preview can name it.
    public var expectedFallback: AppRef?

    public init(
        target: Target,
        fromApp: AppRef?,
        fromOrigin: BindingOrigin,
        toApp: AppRef?,
        isNoOp: Bool,
        collateral: [String] = [],
        expectedFallback: AppRef? = nil
    ) {
        self.target = target
        self.fromApp = fromApp
        self.fromOrigin = fromOrigin
        self.toApp = toApp
        self.isNoOp = isNoOp
        self.collateral = collateral
        self.expectedFallback = expectedFallback
    }
}

public struct ProposalWarning: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case sharedType        // binding would drag unrelated formats along
        case systemPrompt      // macOS shows its own dialog (browser / mail)
        case appDoesNotDeclare // the chosen app never said it can open this
        case missingApp
    }
    public var id: String { kind.rawValue + ":" + message }
    public var kind: Kind
    public var message: String
    public var targets: [Target]

    public init(kind: Kind, message: String, targets: [Target] = []) {
        self.kind = kind
        self.message = message
        self.targets = targets
    }
}

public enum ProposalStatus: String, Codable, Sendable {
    case awaitingApproval = "awaiting_approval"
    case approved
    case applied
    case rejected
    case expired
    case failed
}

/// Nothing reaches LaunchServices except through one of these, and none of these
/// is applied without a person approving it in the window. That is the whole
/// safety story, and it is the same for the GUI, the CLI and an agent.
public struct Proposal: Identifiable, Codable, Sendable {
    public var id: String
    public var title: String
    public var source: ChangeSource
    public var items: [ChangeItem]
    public var warnings: [ProposalWarning]
    public var status: ProposalStatus
    public var createdAt: Date
    public var expiresAt: Date
    public var results: [ApplyResult]
    public var note: String?
    /// The history entry this proposal undoes, when it is an undo.
    ///
    /// Carried explicitly rather than recovered from the title. Two applies can
    /// easily share a title — "Code → Cursor" twice in a week is ordinary — and
    /// matching on text would mark the wrong one as rolled back, which quietly
    /// takes the still-undoable entry out of reach.
    public var rollbackOf: String?

    public static let lifetime: TimeInterval = 600   // ten minutes

    public init(
        id: String = Proposal.newID(),
        title: String,
        source: ChangeSource,
        items: [ChangeItem],
        warnings: [ProposalWarning] = [],
        status: ProposalStatus = .awaitingApproval,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        results: [ApplyResult] = [],
        note: String? = nil,
        rollbackOf: String? = nil
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.items = items
        self.warnings = warnings
        self.status = status
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Proposal.lifetime)
        self.results = results
        self.note = note
        self.rollbackOf = rollbackOf
    }

    public static func newID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// Items that would actually change something. The count the sheet leads with.
    public var effectiveItems: [ChangeItem] { items.filter { !$0.isNoOp } }
    public var alreadyCorrectCount: Int { items.count - effectiveItems.count }
    public var isExpired: Bool { status == .awaitingApproval && Date() > expiresAt }

    /// "142 code types → Cursor — 118 already correct, 24 will change"
    public var summaryLine: String {
        let changing = effectiveItems.count
        if changing == 0 { return "Nothing to change — all \(items.count) already open correctly." }
        if alreadyCorrectCount == 0 {
            return "\(changing) \(changing == 1 ? "type" : "types") will change."
        }
        return "\(alreadyCorrectCount) already correct, \(changing) will change."
    }
}

/// The outcome of one write, read back from the system rather than assumed.
public struct ApplyResult: Hashable, Codable, Sendable, Identifiable {
    public enum Outcome: Hashable, Codable, Sendable {
        case applied
        case unchanged
        case failed(reason: String)

        public var isFailure: Bool { if case .failed = self { return true }; return false }
    }

    public var id: String { target.key }
    public var target: Target
    public var outcome: Outcome

    public init(target: Target, outcome: Outcome) {
        self.target = target
        self.outcome = outcome
    }
}
