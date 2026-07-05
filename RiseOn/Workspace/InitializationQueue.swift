import Foundation

/// Placeholder for the `actor`-based initialization queue: serial scheduling with a
/// concurrency cap (2-3), per-task retry/backoff, and crash-resume support.
///
/// Implemented in task.md S4.1-S4.3. Left empty for now so the `Workspace/` group
/// compiles as part of the S1 scaffolding step.
public enum InitializationQueue {}
