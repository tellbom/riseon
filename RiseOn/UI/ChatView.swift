import SwiftUI

/// Placeholder for the per-stock chat screen (plan.md §4.3): question input bound
/// to this stock's `ContextPack`+history only, with a persistent header showing
/// snapshot time/quality/missing blocks so the user never mistakes it for a
/// live-news feed.
///
/// Implemented once `PromptBuilder`/`LLMService` (S9-S10) and `ChatSession` (S11)
/// exist. Left as an empty view for now so the `UI/` group compiles as part of
/// the S1 scaffolding step.
struct ChatView: View {
    var body: some View {
        Text("问答页 — 待 S9/S10/S11 完成后实现")
            .foregroundStyle(.secondary)
    }
}

#Preview {
    ChatView()
}
