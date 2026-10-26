import SwiftUI

/// Block-level Markdown for assistant replies: paragraphs, headings, lists,
/// quotes, tables and fenced code. Inline styling uses Foundation's Markdown parser.
struct MarkdownText: View {
    private let blocks: [Block]

    init(_ text: String) {
        blocks = Self.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    inline(text)
                case .heading(let level, let text):
                    inline(text)
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, 4)
                case .bullet(let marker, let text, let depth):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        inline(text)
                    }
                    .padding(.leading, CGFloat(depth) * 16)
                case .quote(let text):
                    inline(text)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(.tint).frame(width: 3) }
                case .code(let language, let code):
                    CodeBlock(code: code, language: language)
                case .table(let table):
                    TableBlock(table: table, cell: inline)
                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) { return Text(attributed) }
        return Text(text)
    }

    enum Block {
        case paragraph(String)
        case heading(Int, String)
        case bullet(String, String, Int)
        case quote(String)
        case code(String?, String)
        case table(Table)
        case rule
    }

    struct Table: Equatable {
        var header: [String]
        var alignments: [HorizontalAlignment]
        var rows: [[String]]

        static func == (lhs: Table, rhs: Table) -> Bool {
            lhs.header == rhs.header && lhs.rows == rhs.rows
        }
    }

    /// `| a | b |` → ["a", "b"]; escaped pipes stay in the cell.
    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The `|---|:--:|` row under a table header, or nil when the line is not one.
    static func alignments(_ line: String) -> [HorizontalAlignment]? {
        guard line.contains("-"), line.contains("|") else { return nil }
        var result: [HorizontalAlignment] = []
        for cell in cells(line) {
            guard cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            result.append(left && right ? .center : right ? .trailing : .leading)
        }
        return result.isEmpty ? nil : result
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var language: String?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph.removeAll()
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(language, lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                    let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            // A table is a `|` row followed by a `|---|` separator row.
            if line.contains("|"), index < lines.count, let alignments = alignments(lines[index]) {
                flush()
                let header = cells(line)
                index += 1
                var rows: [[String]] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !next.isEmpty, next.contains("|") else { break }
                    rows.append(cells(next))
                    index += 1
                }
                let width = max(header.count, rows.map(\.count).max() ?? 0)
                let pad = { (row: [String]) in row + Array(repeating: "", count: max(0, width - row.count)) }
                blocks.append(.table(Table(
                    header: pad(header),
                    alignments: alignments + Array(repeating: .leading, count: max(0, width - alignments.count)),
                    rows: rows.map(pad))))
                continue
            }
            if line.isEmpty {
                flush()
            } else if let heading = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flush()
                blocks.append(.heading(heading.1.count, String(heading.2)))
            } else if line == "---" || line == "***" {
                flush()
                blocks.append(.rule)
            } else if let item = raw.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.*)$/) {
                flush()
                let marker = item.2.first.map { "-*+".contains($0) } == true ? "•" : String(item.2)
                blocks.append(.bullet(marker, String(item.3), item.1.count / 2))
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(raw)
            }
        }
        if let code { blocks.append(.code(language, code.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

/// A Markdown table: a bold header row over hairline-separated rows, scrolling sideways when wide.
struct TableBlock: View {
    let table: MarkdownText.Table
    let cell: (String) -> Text

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, text in
                        cellView(text, column: column).font(.subheadline.weight(.semibold))
                    }
                }
                .background(.fill.tertiary)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
                            cellView(text, column: column).font(.subheadline)
                        }
                    }
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
            .clipShape(.rect(cornerRadius: 10))
        }
        // As tall as the table; a list cell would otherwise propose too little.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }

    private func cellView(_ text: String, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        return cell(text)
            .frame(minWidth: 60, maxWidth: 320, alignment: Alignment(horizontal: alignment, vertical: .center))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .gridColumnAlignment(alignment)
    }
}

struct CodeBlock: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(language == "error" ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    Haptics.tap()
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .labelStyle(.iconOnly)
                .font(.caption)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    // Long lines scroll sideways rather than truncating, wherever the block is placed.
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            // As tall as the code (a list cell would otherwise propose too little), up to 360 points.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 360, alignment: .top)
            .clipped()
        }
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }
}
