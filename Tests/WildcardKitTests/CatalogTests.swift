import Foundation
import Testing
@testable import WildcardKit

/// The catalog is the promise that nobody has to type an extension list by hand,
/// so these check the properties the interface relies on rather than exact
/// contents — which are expected to grow.
@Suite("Catalog")
struct CatalogTests {

    let catalog = TypeCatalog()

    @Test("loads")
    func loads() {
        #expect(TypeCatalog.catalogURL() != nil, "catalog.json was not found")
        #expect(catalog.categories.count >= 20)
        #expect(catalog.fileCategories.isEmpty == false)
        #expect(catalog.schemeCategories.isEmpty == false)
    }

    @Test("ids are unique")
    func uniqueIDs() {
        var seen = Set<String>()
        for c in catalog.categories {
            #expect(seen.insert(c.id).inserted, "duplicate category id \(c.id)")
            var groups = Set<String>()
            for g in c.subgroups {
                #expect(groups.insert(g.id).inserted, "duplicate subgroup \(c.id)/\(g.id)")
            }
        }
    }

    /// An extension in two categories would make "assign this category" ambiguous
    /// and the two assignments would silently fight each other.
    @Test("no extension appears in two categories")
    func noDuplicateExtensions() {
        var owner: [String: String] = [:]
        var clashes: [String] = []
        for c in catalog.categories {
            for t in c.types {
                if let first = owner[t.ext], first != c.id {
                    clashes.append("\(t.ext): \(first) and \(c.id)")
                } else {
                    owner[t.ext] = c.id
                }
            }
        }
        #expect(clashes.isEmpty, "\(clashes.count) shared: \(clashes.prefix(10).joined(separator: ", "))")
    }

    /// Nothing in the interface should ever read as a bare extension: every row
    /// says "Kotlin source", never "kt". Plenty of correct names begin lower-case
    /// ("sed script", "iOS app package", "reStructuredText"), so the check is that
    /// the name exists, is tidy, and is not just the extension shouted back.
    @Test("every type has a real display name")
    func displayNames() {
        var bad: [String] = []
        for c in catalog.categories {
            for t in c.types {
                let n = t.name
                // "AppleScript" and "Dockerfile" are real names that happen to
                // spell their extension; "applescript" and "KT" are not names.
                if n.count < 2 || n != n.trimmingCharacters(in: .whitespaces)
                    || n == t.ext || n == t.ext.uppercased() {
                    bad.append("\(t.ext) -> “\(n)”")
                }
            }
        }
        #expect(bad.isEmpty, "\(bad.count) weak names: \(bad.prefix(10).joined(separator: ", "))")
    }

    @Test("entries are normalised")
    func normalised() {
        for c in catalog.categories {
            for t in c.types {
                #expect(t.ext == Target.normalizedExtension(t.ext), "\(t.ext) is not normalised")
                #expect(t.ext.contains(" ") == false, "\(t.ext) contains a space")
                if c.kind == .scheme {
                    #expect(t.ext.contains(":") == false, "scheme \(t.ext) should not carry a colon")
                }
            }
        }
    }

    /// Leading-dot names (.gitignore, .zshrc) have no extension as far as Cocoa is
    /// concerned and cannot be bound, so they must not be offered.
    @Test("nothing unbindable is listed")
    func bindable() {
        for c in catalog.fileCategories {
            for t in c.types {
                #expect(t.ext.isEmpty == false)
                #expect(t.ext.hasPrefix(".") == false, "\(t.ext) would be a dotfile, not an extension")
            }
        }
    }

    @Test("lookup works both ways")
    func lookup() {
        #expect(catalog.category(forExtension: "kt") != nil)
        #expect(catalog.category(forExtension: ".KT")?.id == catalog.category(forExtension: "kt")?.id)
        #expect(catalog.label(for: .fileType(ext: "kt")).isEmpty == false)
        // Unknown types still read as a sentence rather than an identifier.
        #expect(catalog.label(for: .fileType(ext: "qqzz")) == "QQZZ file")
        #expect(catalog.search("kotlin").isEmpty == false)
    }

    /// How much of what is actually installed here the catalog can speak for.
    ///
    /// It will never reach 100%, and should not: most of the tail is one app's
    /// private format (`.afbrushes`, `.imazing`, `.animoji`) or a numbered volume
    /// of a split archive. Those already have exactly one owner and nobody wants
    /// to reassign them by category. What the floor protects is the opposite
    /// case — the generic formats a person does think in groups about.
    ///
    /// A report by default, an assertion only when asked. The number describes
    /// the machine as much as the catalog, and the machine that matters is one
    /// with a normal set of applications on it. A CI runner has Xcode and little
    /// else, so a floor enforced there would measure the runner image and fail
    /// the day GitHub changes it — a red build that says nothing about this
    /// commit is worse than no check. Set `WILDCARD_COVERAGE_FLOOR=45` on a real
    /// Mac to hold the catalog to it.
    @Test("coverage of the types installed on this machine")
    func coverage() {
        let inventory = AppInventory()
        _ = inventory.scan()
        let declared = inventory.allDeclaredExtensions
        guard !declared.isEmpty else { return }

        let known = Set(catalog.categories.flatMap { $0.types.map(\.ext) })
        let missing = declared.subtracting(known)
        let covered = declared.count - missing.count
        let percent = Double(covered) / Double(declared.count) * 100

        print(String(format: "catalog covers %d of %d installed extensions (%.1f%%)",
                     covered, declared.count, percent))
        print("uncovered sample: " + missing.sorted().prefix(40).joined(separator: " "))

        guard let floor = ProcessInfo.processInfo.environment["WILDCARD_COVERAGE_FLOOR"]
            .flatMap(Double.init) else { return }
        #expect(percent > floor, "catalog covers only \(Int(percent))% of what is installed")
    }
}
