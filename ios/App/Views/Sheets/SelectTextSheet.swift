import SwiftUI
import UIKit

extension View {
    /// Long-press offers Copy for the whole message and Select Text, which opens it in a sheet where
    /// any part of it can be selected. SwiftUI text in a list only ever selects all of itself.
    func messageMenu(_ text: String, markdown: Bool = false) -> some View {
        modifier(MessageMenu(text: text, markdown: markdown))
    }
}

private struct MessageMenu: ViewModifier {
    let text: String
    let markdown: Bool
    @State private var selecting = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                CopyButton(text: text)
                Button("Select Text", systemImage: "selection.pin.in.out", action: tap { selecting = true })
            }
            .sheet(isPresented: $selecting) { SelectTextSheet(text: text, markdown: markdown) }
    }
}

/// The message as one native text view, read-only, for selecting a line or a word to copy, look up
/// or share with the system's own handles and edit menu.
struct SelectTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    let markdown: Bool

    var body: some View {
        NavigationStack {
            SelectableText(text: markdown ? Self.render(text) : Self.plain(text))
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle("Select Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close, action: tap { dismiss() })
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy All", systemImage: "doc.on.doc", action: tap {
                            UIPasteboard.general.string = text
                            dismiss()
                        })
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    private static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label,
        ])
    }

    /// The reply's Markdown as the transcript draws it, one block per paragraph, so what is selected
    /// reads the same as what was on screen.
    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = UIFont.preferredFont(forTextStyle: .body)
        for block in MarkdownText.parse(text) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 10
            var paragraph: NSMutableAttributedString
            switch block {
            case .paragraph(let text):
                paragraph = inline(text, font: body)
            case .heading(let level, let text):
                let textStyle: UIFont.TextStyle = level == 1 ? .title2 : level == 2 ? .title3 : .headline
                paragraph = inline(text, font: UIFont.preferredFont(forTextStyle: textStyle).bold)
            case .bullet(let marker, let text, let depth):
                paragraph = NSMutableAttributedString(string: marker + "\t", attributes: [
                    .font: body, .foregroundColor: UIColor.secondaryLabel,
                ])
                paragraph.append(inline(text, font: body))
                let indent = CGFloat(depth) * 16
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 22
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]
            case .quote(let text):
                paragraph = inline(text, font: body, color: .secondaryLabel)
                style.firstLineHeadIndent = 12
                style.headIndent = 12
            case .code(_, let code):
                paragraph = NSMutableAttributedString(string: code, attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular),
                    .foregroundColor: UIColor.label,
                    .backgroundColor: UIColor.tertiarySystemFill,
                ])
            case .table(let table):
                let rows = [table.header] + table.rows
                paragraph = NSMutableAttributedString()
                for (index, row) in rows.enumerated() {
                    if index > 0 { paragraph.append(NSAttributedString(string: "\n")) }
                    paragraph.append(inline(row.joined(separator: "\t"), font: index == 0 ? body.bold : body))
                }
            case .rule:
                paragraph = NSMutableAttributedString(string: "———", attributes: [
                    .font: body, .foregroundColor: UIColor.tertiaryLabel,
                ])
            }
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            result.append(paragraph)
        }
        return result
    }

    /// Inline Markdown (bold, italics, code, links) in UIKit attributes.
    private static func inline(_ text: String, font: UIFont, color: UIColor = .label) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize * 0.94, weight: .regular)
                    attributes[.backgroundColor] = UIColor.tertiarySystemFill
                }
                if intent.contains(.stronglyEmphasized) { runFont = runFont.bold }
                if intent.contains(.emphasized) { runFont = runFont.italic }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link { attributes[.link] = link }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 32, right: 16)
        view.alwaysBounceVertical = true
        view.dataDetectorTypes = []
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.attributedText != text { view.attributedText = text }
    }
}

private extension UIFont {
    var bold: UIFont { adding(.traitBold) }
    var italic: UIFont { adding(.traitItalic) }

    func adding(_ trait: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
