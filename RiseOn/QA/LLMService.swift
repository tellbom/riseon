import Foundation

/// Placeholder for `func generate(system: String, user: String) async throws -> String`,
/// backed by a direct cloud API call (user-supplied key, stored in Keychain).
/// Mirrors the minimal shape of `src/llm/generation_backend.py::GenerationBackend`.
///
/// Implemented in task.md S10.1-S10.2. This is one of only two places network I/O
/// is allowed (the other being `QuoteProvider`). Left empty for now so the `QA/`
/// group compiles as part of the S1 scaffolding step.
public enum LLMService {}
