import Foundation

extension InitStep {
    /// Human-readable Chinese label for this step. Shared between
    /// `InitProgressView` (S13) and `WorkspaceNotificationCenter`/Live
    /// Activity (S14) so every surface uses identical wording for a given
    /// step — previously duplicated as a private helper inside
    /// `InitProgressView`'s row view; pulled out here now that a second
    /// consumer needs it.
    public var displayName: String {
        switch self {
        case .fetchDailyBars: return "拉取日线"
        case .overlayRealtime: return "叠加实时行情"
        case .computeIndicators: return "计算技术指标"
        case .computeRuleScore: return "计算规则评分"
        case .buildPack: return "打包上下文"
        }
    }
}
