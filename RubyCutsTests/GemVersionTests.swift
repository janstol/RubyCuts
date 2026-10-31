import Foundation
@testable import RubyCuts
import Testing

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

    @Test func aVersionMustStartWithANumber() throws {
        #expect(GemVersion("latest") == nil)
        #expect(GemVersion("rc1.0") == nil)
        #expect(GemRequirement("latest") == nil)
        #expect(try #require(GemVersion("1.0.rc1")).segments.count == 3)
    }

    @Test func aDoubledOperatorIsRejected() {
        #expect(GemRequirement("~>> 1.0") == nil)
    }

    // MARK: - GemRequirement: pessimistic bounds at Int's limit
    //
    // `~>` increments a segment to build its upper bound. At Int.max that
    // increment used to trap at comparison time; now the requirement is
    // rejected at parse time instead, and Int.max - 1 still works.

    @Test(arguments: [
        "~> \(Int.max)",  // single segment: the only segment is incremented
        "~> \(Int.max).0",  // multi segment: the second-to-last is incremented
        "~> 1.\(Int.max).5",
    ])
    func pessimisticWhoseBoundWouldOverflowIsRejected(requirement: String) {
        #expect(GemRequirement(requirement) == nil)
    }

    @Test func pessimisticJustBelowTheLimitStillWorks() throws {
        let single = try #require(GemRequirement("~> \(Int.max - 1)"))
        #expect(single.satisfied(by: try #require(GemVersion("\(Int.max - 1)"))))
        #expect(!single.satisfied(by: try #require(GemVersion("\(Int.max)"))))

        let multi = try #require(GemRequirement("~> \(Int.max - 1).0"))
        #expect(multi.satisfied(by: try #require(GemVersion("\(Int.max - 1).7"))))
        #expect(!multi.satisfied(by: try #require(GemVersion("\(Int.max).0"))))
    }

    @Test func aLargeLastSegmentDoesNotOverflowAMultiSegmentBound() throws {
        // Only the second-to-last segment is incremented, so Int.max in the
        // dropped last position is fine: ~> 1.Int.max allows >= 1.Int.max, < 2.
        let requirement = try #require(GemRequirement("~> 1.\(Int.max)"))
        #expect(requirement.satisfied(by: try #require(GemVersion("1.\(Int.max)"))))
        #expect(!requirement.satisfied(by: try #require(GemVersion("2.0"))))
    }

    @Test func pessimisticWithANonNumericSegmentToIncrementIsRejected() {
        #expect(GemRequirement("~> 1.rc.0") == nil)
    }
}
