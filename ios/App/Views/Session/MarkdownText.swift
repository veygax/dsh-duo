import SwiftUI

/// Block-level Markdown for assistant replies: paragraphs, headings, lists,
/// quotes and fenced code. Inline styling uses Foundation's Markdown parser.
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
        case rule
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

        for raw in text.components(separatedBy: "\n") {
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
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .frame(maxHeight: 360)
        }
        .background(.fill.tertiary, in: .rect(cornerRadius: 12))
    }
}
