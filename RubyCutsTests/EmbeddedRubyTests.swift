import Testing

/// Shared serialized parent for every suite that drives the one
/// non-thread-safe embedded CRuby VM through `RubyRuntime.shared`:
/// `RubyRuntimeTests`, `NativeBridgeTests`, `GemArchiveTests` (each nested
/// here via an `extension EmbeddedRubyTests { ... }` in its own file, not
/// declared inline).
///
/// Before `RubyRuntime` got its own dedicated thread (Phase 8 Wave B), every
/// test body ran fully synchronously on the main actor, so the three
/// `@Suite(.serialized)` suites could never interleave with each other even
/// though `.serialized` only orders tests *within* one suite. There was
/// simply no `await` anywhere for a scheduler to interleave at. Adding
/// `await` to every VM call broke that accidental guarantee: two suites
/// could now wedge evals into each other's multi-eval sequences (e.g.
/// `RubyRuntimeTests`'s ENV save/restore round-trip). Nesting all three
/// under this `.serialized` parent restores it: `.serialized` is
/// inherited by nested suites.
@Suite(.serialized)
struct EmbeddedRubyTests {}
