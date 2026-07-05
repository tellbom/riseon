import SwiftUI

/// Placeholder for the step-by-step initialization progress screen (plan.md §4.4 /
/// task.md S13.1): shows steps A-F (daily bars → indicators → score → pack),
/// with per-step retry on failure.
///
/// Implemented once `InitializationQueue` (S4) exists to report progress against.
/// Left as an empty view for now so the `UI/` group compiles as part of the S1
/// scaffolding step.
struct InitProgressView: View {
    var body: some View {
        Text("初始化进度页 — 待 S4/S13 完成后实现")
            .foregroundStyle(.secondary)
    }
}

#Preview {
    InitProgressView()
}
