import Foundation

/// A parsed RubyGems version string (`"1.2.3"`, `"0.5"`), ordered
/// segment-wise the way `Gem::Version` compares versions: dot-separated
/// segments compared left to right, a missing trailing segment treated as
/// `0` (`1.0 == 1.0.0`).
///
/// Deliberately narrower than `Gem::Version`: nothing here understands
/// prerelease ordering. V1 never selects a prerelease: ``RubyGemsAPI``'s
/// callers filter `prerelease: true` entries out before a version string
/// ever reaches this type, so there's no need to
/// order one correctly relative to a release.
///
/// Opted out of the app target's MainActor-by-default isolation, matching
/// ``RunInput``: a pure value type with no actor-coupled state, usable from
/// any context including the nonisolated test target.
struct GemVersion: Comparable, Sendable, CustomStringConvertible {
    /// One dot-separated component. Parsed as an integer where possible;
    /// left as text otherwise, since RubyGems allows segments like `"rc1"`.
    nonisolated enum Segment: Comparable, Sendable {
        case number(Int)
        case text(String)

        nonisolated static func < (lhs: Segment, rhs: Segment) -> Bool {
            switch (lhs, rhs) {
            case (.number(let l), .number(let r)): return l < r
            case (.text(let l), .text(let r)): return l < r
            // A numeric segment sorts below a text one at the same position:
            // matches Gem::Version, and only ever matters for the prerelease
            // suffixes this type doesn't otherwise try to order.
            case (.number, .text): return true
            case (.text, .number): return false
            }
        }
    }

    /// The original string, unmodified: what gets sent back to the
    /// RubyGems API and written into ``InstalledGem`` directory names.
    nonisolated let raw: String

    /// `raw` split on `.` and parsed segment by segment.
    nonisolated let segments: [Segment]

    nonisolated init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Each dot-separated part must be non-empty and alphanumeric,
        // rejects garbage like "not a version" or "1..2" outright, rather
        // than silently accepting it as a one-segment "version".
        var parsedSegments: [Segment] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                return nil
            }
            parsedSegments.append(Int(part).map(Segment.number) ?? .text(String(part)))
        }

        // Like Gem::Version, a version starts with a number: "latest" or
        // "rc1" alone isn't a version, even though "1.0.rc1" is.
        guard case .number = parsedSegments.first else { return nil }

        self.raw = trimmed
        self.segments = parsedSegments
    }

    /// Builds a version from already-parsed segments, bypassing string
    /// parsing. Used internally by ``GemRequirement`` to compute a `~>`
    /// clause's upper bound, which is a synthesized version rather than one
    /// that came from a string.
    nonisolated fileprivate init(raw: String, segments: [Segment]) {
        self.raw = raw
        self.segments = segments
    }

    nonisolated var description: String { raw }

    /// Compares segment-by-segment, padding the shorter side with
    /// `.number(0)` so `1.0` and `1.0.0` compare as equal.
    nonisolated static func < (lhs: GemVersion, rhs: GemVersion) -> Bool {
        let count = max(lhs.segments.count, rhs.segments.count)
        for i in 0..<count {
            let l = segment(lhs, at: i)
            let r = segment(rhs, at: i)
            if l != r { return l < r }
        }
        return false
    }

    nonisolated static func == (lhs: GemVersion, rhs: GemVersion) -> Bool {
        let count = max(lhs.segments.count, rhs.segments.count)
        for i in 0..<count {
            if segment(lhs, at: i) != segment(rhs, at: i) { return false }
        }
        return true
    }

    nonisolated private static func segment(_ version: GemVersion, at index: Int) -> Segment {
        index < version.segments.count ? version.segments[index] : .number(0)
    }
}

/// A RubyGems version constraint: either a single clause (`">= 1.0.0"`,
/// `"~> 0.5"`) or a comma-separated list of them (`">= 1.0, < 2.0"`),
/// matching `Gem::Requirement`'s syntax.
///
/// Opted out of MainActor-by-default isolation, matching ``GemVersion``.
struct GemRequirement: Sendable, CustomStringConvertible {
    nonisolated enum Operator: String, Sendable {
        case greaterThanOrEqual = ">="
        case lessThanOrEqual = "<="
        case notEqual = "!="
        case pessimistic = "~>"
        case greaterThan = ">"
        case lessThan = "<"
        case equal = "="

        /// Every recognized prefix, checked in this order so `">="` matches
        /// before the shorter `">"` does.
        nonisolated static let byLongestPrefixFirst: [Operator] = [
            .greaterThanOrEqual, .lessThanOrEqual, .notEqual, .pessimistic,
            .greaterThan, .lessThan, .equal,
        ]
    }

    nonisolated struct Clause: Sendable {
        nonisolated let op: Operator
        nonisolated let version: GemVersion

        /// For a `~>` clause, its exclusive upper bound; `nil` for every
        /// other operator. Computed once at parse time so a `~>` whose bound
        /// can't be represented is rejected there, not discovered at
        /// comparison time.
        nonisolated private let upperBound: GemVersion?

        /// Fails only for a `~>` clause whose upper bound can't be computed:
        /// incrementing would overflow `Int`, or the segment to increment
        /// isn't a number.
        nonisolated init?(op: Operator, version: GemVersion) {
            self.op = op
            self.version = version
            if op == .pessimistic {
                guard let bound = Clause.pessimisticUpperBound(of: version) else { return nil }
                self.upperBound = bound
            } else {
                self.upperBound = nil
            }
        }

        nonisolated func satisfied(by candidate: GemVersion) -> Bool {
            switch op {
            case .greaterThanOrEqual: return candidate >= version
            case .lessThanOrEqual: return candidate <= version
            case .greaterThan: return candidate > version
            case .lessThan: return candidate < version
            case .equal: return candidate == version
            case .notEqual: return candidate != version
            case .pessimistic:
                guard let upperBound else { return false }
                return candidate >= version && candidate < upperBound
            }
        }

        /// `~> a.b.c` allows `>= a.b.c, < a.(b+1)`: drop the version's last
        /// segment entirely, then increment the segment now left at the end.
        /// `~> a` (a single segment) allows `>= a, < (a+1)`. Returns `nil`
        /// when the increment would overflow `Int` (`~> 9223372036854775807`)
        /// or the segment to increment isn't numeric.
        nonisolated private static func pessimisticUpperBound(of version: GemVersion) -> GemVersion?
        {
            var segments = version.segments
            guard let dropped = segments.popLast(), case .number(let droppedNumber) = dropped
            else { return nil }

            guard let remaining = segments.popLast() else {
                // A single-segment requirement ("~> 5"): the dropped segment
                // itself is the one to increment.
                guard let bumped = incremented(droppedNumber) else { return nil }
                return GemVersion(raw: "\(bumped)", segments: [.number(bumped)])
            }
            guard case .number(let last) = remaining, let bumped = incremented(last) else {
                return nil
            }
            segments.append(.number(bumped))

            let raw = segments.map { segment -> String in
                switch segment {
                case .number(let n): return "\(n)"
                case .text(let t): return t
                }
            }.joined(separator: ".")
            return GemVersion(raw: raw, segments: segments)
        }

        /// `number + 1`, or `nil` if that overflows `Int`.
        nonisolated private static func incremented(_ number: Int) -> Int? {
            let (sum, overflow) = number.addingReportingOverflow(1)
            return overflow ? nil : sum
        }
    }

    /// The original string, trimmed: what ``description`` returns, so an
    /// error message can name the exact constraint a caller passed.
    nonisolated let raw: String

    nonisolated let clauses: [Clause]

    nonisolated init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        var parsed: [Clause] = []
        for part in parts {
            guard let clause = Self.parseClause(part) else { return nil }
            parsed.append(clause)
        }
        self.raw = trimmed
        self.clauses = parsed
    }

    nonisolated var description: String { raw }

    /// Whether `version` satisfies every clause in this requirement.
    nonisolated func satisfied(by version: GemVersion) -> Bool {
        clauses.allSatisfy { $0.satisfied(by: version) }
    }

    nonisolated private static func parseClause(_ string: String) -> Clause? {
        for op in Operator.byLongestPrefixFirst where string.hasPrefix(op.rawValue) {
            let versionString = string.dropFirst(op.rawValue.count)
                .trimmingCharacters(in: .whitespaces)
            guard let version = GemVersion(versionString) else { return nil }
            return Clause(op: op, version: version)
        }
        // No operator prefix means an implicit "=", matching Gem::Requirement.
        guard let version = GemVersion(string) else { return nil }
        return Clause(op: .equal, version: version)
    }
}
