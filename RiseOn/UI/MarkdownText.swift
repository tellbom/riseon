import SwiftUI

/// Lightweight Markdown renderer tuned for chat output. It keeps the core
/// LLM pipeline untouched and only changes presentation: paragraphs, headings,
/// lists, quotes, and code blocks get native-looking spacing instead of being
/// compressed into one dense `Text`.
struct MarkdownText: View {
    let content: String
    var isAssistant: Bool = true

    private var blocks: [MarkdownBlock] {
        MarkdownBlock.parse(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 2 : 1)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(primaryText)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(secondaryText)
                        Text(inlineMarkdown(item))
                            .font(.body)
                            .lineSpacing(3)
                            .foregroundStyle(primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .numbers(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.body.monospacedDigit().weight(.medium))
                            .foregroundStyle(secondaryText)
                        Text(inlineMarkdown(item))
                            .font(.body)
                            .lineSpacing(3)
                            .foregroundStyle(primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(secondaryText.opacity(isAssistant ? 0.35 : 0.55))
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .font(.callout)
                    .lineSpacing(3)
                    .foregroundStyle(secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(codeText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(codeBackground, in: RoundedRectangle(cornerRadius: 8))

        case .table(let rows):
            tableView(rows)

        case .divider:
            Divider()
                .overlay(secondaryText.opacity(0.3))
                .padding(.vertical, 2)
        }
    }

    private var primaryText: Color {
        isAssistant ? .primary : .white
    }

    private var secondaryText: Color {
        isAssistant ? .secondary : Color.white.opacity(0.78)
    }

    private var codeText: Color {
        isAssistant ? .primary : .white
    }

    private var codeBackground: Color {
        isAssistant ? Color.primary.opacity(0.055) : Color.white.opacity(0.16)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline.weight(.semibold)
        case 3: return .subheadline.weight(.semibold)
        default: return .callout.weight(.semibold)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func tableView(_ rows: [[String]]) -> some View {
        let columnCount = rows.map(\.count).max() ?? 0
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            Text(inlineMarkdown(columnIndex < row.count ? row[columnIndex] : ""))
                                .font(rowIndex == 0 ? .caption.weight(.semibold) : .caption)
                                .lineSpacing(2)
                                .foregroundStyle(rowIndex == 0 ? primaryText : secondaryText)
                                .frame(minWidth: columnCount > 2 ? 86 : 120, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(tableCellBackground(rowIndex: rowIndex, columnIndex: columnIndex))
                                .overlay(alignment: .trailing) {
                                    if columnIndex < columnCount - 1 {
                                        Rectangle()
                                            .fill(secondaryText.opacity(0.12))
                                            .frame(width: 1)
                                    }
                                }
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Divider()
                            .overlay(secondaryText.opacity(0.12))
                    }
                }
            }
            .background(tableBackground, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func tableCellBackground(rowIndex: Int, columnIndex: Int) -> Color {
        if rowIndex == 0 {
            return isAssistant ? Color.primary.opacity(0.055) : Color.white.opacity(0.16)
        }
        return rowIndex.isMultiple(of: 2)
            ? Color.clear
            : (isAssistant ? Color.primary.opacity(0.025) : Color.white.opacity(0.08))
    }

    private var tableBackground: Color {
        isAssistant ? Color.primary.opacity(0.035) : Color.white.opacity(0.10)
    }
}

private enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbers([String])
    case quote(String)
    case code(String)
    case table([[String]])
    case divider

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var quote: [String] = []
        var code: [String] = []
        var tableRows: [[String]] = []
        var pendingTableHeader: [String]?
        var inCode = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        func flushBullets() {
            guard !bullets.isEmpty else { return }
            blocks.append(.bullets(bullets))
            bullets.removeAll()
        }

        func flushNumbers() {
            guard !numbers.isEmpty else { return }
            blocks.append(.numbers(numbers))
            numbers.removeAll()
        }

        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote.removeAll()
        }

        func flushTable() {
            guard !tableRows.isEmpty else {
                if let header = pendingTableHeader {
                    blocks.append(.paragraph(header.joined(separator: " | ")))
                    pendingTableHeader = nil
                }
                return
            }
            blocks.append(.table(tableRows))
            tableRows.removeAll()
            pendingTableHeader = nil
        }

        func flushListsAndQuote() {
            flushBullets()
            flushNumbers()
            flushQuote()
        }

        func flushAllText() {
            flushParagraph()
            flushListsAndQuote()
            flushTable()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(code.joined(separator: "\n")))
                    code.removeAll()
                    inCode = false
                } else {
                    flushAllText()
                    inCode = true
                }
                continue
            }

            if inCode {
                code.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushAllText()
                continue
            }

            if line == "---" || line == "***" {
                flushAllText()
                blocks.append(.divider)
                continue
            }

            if let tableCells = parseTableRow(line) {
                flushParagraph()
                flushListsAndQuote()
                if let header = pendingTableHeader, isTableSeparator(cells: tableCells) {
                    tableRows = [header]
                    pendingTableHeader = nil
                    continue
                }
                if !tableRows.isEmpty {
                    tableRows.append(tableCells)
                } else {
                    if let pending = pendingTableHeader {
                        blocks.append(.paragraph(pending.joined(separator: " | ")))
                    }
                    pendingTableHeader = tableCells
                }
                continue
            } else if pendingTableHeader != nil || !tableRows.isEmpty {
                flushTable()
            }

            if let heading = parseHeading(line) {
                flushAllText()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let item = parseBullet(line) {
                flushParagraph()
                flushNumbers()
                flushQuote()
                bullets.append(item)
                continue
            }

            if let item = parseNumbered(line) {
                flushParagraph()
                flushBullets()
                flushQuote()
                numbers.append(item)
                continue
            }

            if line.hasPrefix(">") {
                flushParagraph()
                flushBullets()
                flushNumbers()
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            flushListsAndQuote()
            paragraph.append(rawLine.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if inCode {
            blocks.append(.code(code.joined(separator: "\n")))
        }
        flushAllText()
        return blocks.isEmpty ? [.paragraph(markdown)] : blocks
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else {
            return nil
        }
        return (hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func parseTableRow(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let rawCells = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard rawCells.count >= 2 else { return nil }
        return rawCells
    }

    private static func isTableSeparator(cells: [String]) -> Bool {
        cells.allSatisfy { cell in
            let normalized = cell.replacingOccurrences(of: " ", with: "")
            guard normalized.count >= 3 else { return false }
            return normalized.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseBullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func parseNumbered(_ line: String) -> String? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let number = line[..<dotIndex]
        let rest = line[line.index(after: dotIndex)...]
        guard !number.isEmpty,
              number.allSatisfy(\.isNumber),
              rest.first == " " else {
            return nil
        }
        return String(rest.dropFirst())
    }
}

#Preview {
    MarkdownText(content: """
    ## 技术面结论

    **支撑位**在 *1650* 附近，注意：
    - 支撑：1650
    - 阻力：1720

    #### 结构化买卖点

    | 类型 | 价格 | 依据 |
    | --- | --- | --- |
    | ideal_buy | 24.24 ~ 24.50 | 对应 MA10 与盘中低点 |

    > 仅基于当前本地数据，不包含新闻。

    ```text
    signal_score = 72
    ```
    """)
    .padding()
}
