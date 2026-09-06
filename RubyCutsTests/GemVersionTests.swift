import Foundation
import Testing

@testable import RubyCuts

// Pure value types, no I/O, no `.serialized` needed, unlike the VM-driving
// suites. Runs concurrently with everything else.
struct GemVersionTests {

    // MARK: - GemVersion ordering

    @Test func parsesDottedSegments() throws {
        let version = try #require(GemVersion("1.2.3"))
        #expect(version.raw == "1.2.3")
        #expect(version.description == "1.2.3")
    }

    @Test func rejectsEmptyString() {
        #expect(GemVersion("") == nil)
        #expect(GemVersion("   ") == nil)
    }

    @Test func ordersSegmentWise() throws {
        let older = try #require(GemVersion("1.9.0"))
        let newer = try #require(GemVersion("1.10.0"))
        // A naive string compare would put "1.9.0" after "1.10.0"; segment-wise
        // integer comparison must not make that mistake.
        #expect(older < newer)
    }

    @Test func missingTrailingSegmentIsTreatedAsZero() throws {
        let short = try #require(GemVersion("1.0"))
        let long = try #require(GemVersion("1.0.0"))
        #expect(short == long)
        #expect(!(short < long))
        #expect(!(long < short))
    }

    @Test func differingLengthsCompareCorrectlyWhenNotEqual() throws {
        let short = try #require(GemVersion("1.2"))
        let long = try #require(GemVersion("1.2.1"))
        #expect(short < long)
    }

    // MARK: - GemRequirement: single clauses

    @Test func greaterThanOrEqualIsSatisfiedByEqualAndGreater() throws {
        let requirement = try #require(GemRequirement(">= 1.0.0"))
        #expect(requirement.satisfied(by: try #require(GemVersion("1.0.0"))))
        #expect(requirement.satisfied(by: try #require(GemVersion("2.0.0"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("0.9.0"))))
    }

    @Test func lessThanExcludesTheBoundary() throws {
        let requirement = try #require(GemRequirement("< 2.0"))
        #expect(requirement.satisfied(by: try #require(GemVersion("1.9.9"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("2.0"))))
    }

    @Test func bareVersionMeansImplicitEquals() throws {
        let requirement = try #require(GemRequirement("1.2.3"))
        #expect(requirement.satisfied(by: try #require(GemVersion("1.2.3"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("1.2.4"))))
    }

    @Test func notEqualExcludesExactlyThatVersion() throws {
        let requirement = try #require(GemRequirement("!= 1.2.3"))
        #expect(!requirement.satisfied(by: try #require(GemVersion("1.2.3"))))
        #expect(requirement.satisfied(by: try #require(GemVersion("1.2.4"))))
    }

    // MARK: - GemRequirement: pessimistic (~>)

    @Test func pessimisticThreeSegmentAllowsPatchButNotMinorBump() throws {
        // ~> 2.2.3 allows >= 2.2.3, < 2.3.0.
        let requirement = try #require(GemRequirement("~> 2.2.3"))
        #expect(requirement.satisfied(by: try #require(GemVersion("2.2.3"))))
        #expect(requirement.satisfied(by: try #require(GemVersion("2.2.9"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("2.3.0"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("2.2.2"))))
    }

    @Test func pessimisticTwoSegmentAllowsMinorButNotMajorBump() throws {
        // ~> 2.2 allows >= 2.2, < 3.0.
        let requirement = try #require(GemRequirement("~> 2.2"))
        #expect(requirement.satisfied(by: try #require(GemVersion("2.9"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("3.0"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("2.1"))))
    }

    // MARK: - GemRequirement: comma-separated lists

    @Test func commaSeparatedListRequiresEveryClause() throws {
        let requirement = try #require(GemRequirement(">= 1.0, < 2.0"))
        #expect(requirement.satisfied(by: try #require(GemVersion("1.5.0"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("0.9.0"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("2.0.0"))))
    }

    @Test func requirementDescriptionPreservesTheOriginalString() throws {
        let requirement = try #require(GemRequirement(">= 1.0, < 2.0"))
        #expect(requirement.description == ">= 1.0, < 2.0")
    }

    @Test func unparsableRequirementReturnsNil() {
        #expect(GemRequirement("not a version") == nil)
    }
}
