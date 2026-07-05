import SwiftUI

/// Placeholder for the StockWorkspace detail screen (plan.md §4.2): quote card +
/// data-quality bar, rule-score card (signal_score/BuySignal/buy-sell levels/
/// trend-volume-MACD-RSI breakdown), and the chat entry point.
///
/// Implemented once `StockWorkspace` (S2-S4), `RuleScoreEngine` (S7), and
/// `ContextPack` (S8) exist. Left as an empty view for now so the `UI/` group
/// compiles as part of the S1 scaffolding step.
struct WorkspaceDetailView: View {
    var body: some View {
        Text("Workspace 详情页 — 待 S7/S8 完成后实现")
            .foregroundStyle(.secondary)
    }
}

#Preview {
    WorkspaceDetailView()
}
