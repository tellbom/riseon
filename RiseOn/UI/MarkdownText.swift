import SwiftUI

/// Renders LLM output (Markdown per plan.md's prompt design) using the
/// native parser rather than plain `Text` — no third-party SPM dependency
/// needed given the iOS 26.1 deployment target. Falls back to plain text on
/// parse failure (e.g. an unclosed `**` mid-stream while tokens are still
/// arriving) so a transient malformed state never blanks the bubble.
struct MarkdownText: View {
    let content: String

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(content)
    }
}

#Preview {
    MarkdownText(content: "**支撑位**在 *1650* 附近，参考：\n- 支撑：1650\n- 阻力：1720")
        .padding()
}
