import SwiftUI
import UIKit

struct MarkdownEditorCommand: Equatable {
    let id = UUID()
    let action: MarkdownFormatAction
    var destination: String? = nil
}

struct MarkdownImageContext: Equatable {
    let repositoryRoot: URL
    let documentURL: URL

    func localFileURL(for destination: String) -> URL? {
        var path = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("<"), path.hasSuffix(">") {
            path.removeFirst()
            path.removeLast()
        }
        guard !path.isEmpty,
              URLComponents(string: path)?.scheme == nil,
              !path.hasPrefix("//") else {
            return nil
        }

        path = String(path.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        path = String(path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        path = path.removingPercentEncoding ?? path

        let root = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let base = documentURL.deletingLastPathComponent()
        let candidate = (path.hasPrefix("/")
            ? root.appending(path: String(path.dropFirst()))
            : base.appending(path: path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return candidate
    }
}

struct RichMarkdownDocumentView: UIViewRepresentable {
    @Binding var markdown: String
    @Binding var command: MarkdownEditorCommand?
    var imageContext: MarkdownImageContext? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.textContainerInset = UIEdgeInsets(top: 18, left: 16, bottom: 36, right: 16)
        textView.accessibilityLabel = "Markdown document editor"
        textView.attributedText = MarkdownRichCodec.decode(markdown, imageContext: imageContext)
        context.coordinator.lastMarkdown = markdown
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if markdown != coordinator.lastMarkdown {
            let selectedRange = textView.selectedRange
            textView.attributedText = MarkdownRichCodec.decode(markdown, imageContext: imageContext)
            textView.selectedRange = MarkdownRichCommandApplier.clamp(
                selectedRange,
                to: textView.textStorage.length
            )
            coordinator.lastMarkdown = markdown
        }

        if let command, command.id != coordinator.lastCommandID {
            coordinator.lastCommandID = command.id
            coordinator.restoreSelectionIfNeeded(in: textView)
            MarkdownRichCommandApplier.apply(command, to: textView)
            coordinator.syncAfterViewUpdate(textView)
            coordinator.rememberSelection(in: textView)
            textView.setNeedsDisplay()
            DispatchQueue.main.async { [weak textView] in
                textView?.becomeFirstResponder()
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: RichMarkdownDocumentView
        var lastMarkdown = ""
        var lastCommandID: UUID?
        private var preservedSelection: NSRange?

        init(parent: RichMarkdownDocumentView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            sync(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.isFirstResponder else { return }
            preservedSelection = textView.selectedRange.length > 0
                ? textView.selectedRange
                : nil
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            rememberSelection(in: textView)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n",
                  MarkdownRichCommandApplier.handleReturn(
                    in: textView,
                    replacing: range
                  ) else {
                return true
            }
            sync(textView)
            return false
        }

        func sync(_ textView: UITextView) {
            let encoded = MarkdownRichCodec.encode(textView.attributedText)
            lastMarkdown = encoded
            if parent.markdown != encoded {
                parent.markdown = encoded
            }
        }

        func syncAfterViewUpdate(_ textView: UITextView) {
            let encoded = MarkdownRichCodec.encode(textView.attributedText)
            lastMarkdown = encoded
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.markdown != encoded else { return }
                self.parent.markdown = encoded
            }
        }

        func rememberSelection(in textView: UITextView) {
            let selection = MarkdownRichCommandApplier.clamp(
                textView.selectedRange,
                to: textView.textStorage.length
            )
            if selection.length > 0 {
                preservedSelection = selection
            }
        }

        func restoreSelectionIfNeeded(in textView: UITextView) {
            guard textView.selectedRange.length == 0,
                  !textView.isFirstResponder,
                  let preservedSelection else {
                return
            }
            textView.selectedRange = MarkdownRichCommandApplier.clamp(
                preservedSelection,
                to: textView.textStorage.length
            )
        }
    }
}

@MainActor
enum MarkdownRichCodec {
    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case unordered(String)
        case ordered(Int, String)
        case quote(String)
        case code(String)
        case rule
    }

    static func decode(
        _ markdown: String,
        imageContext: MarkdownImageContext? = nil
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for block in parseBlocks(markdown) {
            append(block, to: output, imageContext: imageContext)
        }
        if output.length > 0, output.string.hasSuffix("\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        return output
    }

    static func encode(_ attributedText: NSAttributedString) -> String {
        guard attributedText.length > 0 else { return "" }
        let source = attributedText.string as NSString
        var paragraphs: [(kind: String, markdown: String)] = []
        var location = 0

        while location < source.length {
            let paragraphRange = source.paragraphRange(for: NSRange(location: location, length: 0))
            var contentRange = paragraphRange
            while contentRange.length > 0 {
                let finalCharacter = source.substring(
                    with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)
                )
                guard finalCharacter == "\n" || finalCharacter == "\r" else { break }
                contentRange.length -= 1
            }

            let blockKind = blockKind(in: attributedText, range: contentRange)
            let content = contentWithoutMarker(in: attributedText, range: contentRange)
            let inline = encodeInline(
                content,
                ignoringBold: blockKind.hasPrefix("heading:"),
                ignoringItalic: blockKind == "quote"
            )
            let markdown: String
            switch blockKind {
            case "heading:1": markdown = "# \(inline)"
            case "heading:2": markdown = "## \(inline)"
            case "heading:3": markdown = "### \(inline)"
            case "heading:4": markdown = "#### \(inline)"
            case "heading:5": markdown = "##### \(inline)"
            case "heading:6": markdown = "###### \(inline)"
            case "unordered": markdown = "- \(inline)"
            case "ordered":
                let marker = markerText(in: attributedText, range: contentRange)
                let number = marker?.prefix { $0.isNumber }
                markdown = "\(number.flatMap { Int($0) } ?? 1). \(inline)"
            case "quote": markdown = "> \(inline)"
            case "code": markdown = content.string
            case "rule": markdown = "---"
            default: markdown = inline
            }
            paragraphs.append((blockKind, markdown))
            location = NSMaxRange(paragraphRange)
        }

        var result = ""
        var index = 0
        while index < paragraphs.count {
            if paragraphs[index].kind == "code" {
                var codeLines: [String] = []
                while index < paragraphs.count, paragraphs[index].kind == "code" {
                    codeLines.append(paragraphs[index].markdown)
                    index += 1
                }
                result += "```\n\(codeLines.joined(separator: "\n"))\n```"
            } else {
                result += paragraphs[index].markdown
                index += 1
            }
            guard index < paragraphs.count else { continue }
            let current = paragraphs[index - 1].kind
            let next = paragraphs[index].kind
            let sameList = (current == "unordered" && next == "unordered")
                || (current == "ordered" && next == "ordered")
            result += sameList ? "\n" : "\n\n"
        }
        return result.trimmingCharacters(in: .newlines)
    }

    private static func parseBlocks(_ markdown: String) -> [Block] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                index += 1
                var code: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(code.joined(separator: "\n")))
                continue
            }

            let hashes = trimmed.prefix { $0 == "#" }
            if (1...6).contains(hashes.count),
               trimmed.dropFirst(hashes.count).first == " " {
                blocks.append(.heading(hashes.count, String(trimmed.dropFirst(hashes.count + 1))))
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if let item = unorderedItem(trimmed) {
                blocks.append(.unordered(item))
                index += 1
                continue
            }

            if let item = orderedItem(trimmed) {
                blocks.append(.ordered(item.number, item.content))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                guard !candidateTrimmed.isEmpty, !isBlockStart(candidateTrimmed) else { break }
                paragraphLines.append(candidate)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
        }

        return blocks
    }

    private static func append(
        _ block: Block,
        to output: NSMutableAttributedString,
        imageContext: MarkdownImageContext?
    ) {
        switch block {
        case .heading(let level, let content):
            let rich = decodeInline(content, imageContext: imageContext)
            markStructuralTrait(.traitBold, key: .gitNoteStructuralBold, in: rich)
            applyBaseFont(headingFont(level), forceBold: true, to: rich)
            append(rich, kind: "heading:\(level)", to: output)
        case .paragraph(let content):
            append(decodeInline(content, imageContext: imageContext), kind: "paragraph", to: output)
        case .unordered(let content):
            append(
                decodeInline(content, imageContext: imageContext),
                kind: "unordered",
                marker: "• ",
                markerColor: .tintColor,
                to: output
            )
        case .ordered(let number, let content):
            append(
                decodeInline(content, imageContext: imageContext),
                kind: "ordered",
                marker: "\(number). ",
                markerColor: .tintColor,
                to: output
            )
        case .quote(let content):
            let rich = decodeInline(content, imageContext: imageContext)
            markStructuralTrait(.traitItalic, key: .gitNoteStructuralItalic, in: rich)
            rich.addAttributes(
                [
                    .foregroundColor: UIColor.secondaryLabel,
                    .font: italicFont(.preferredFont(forTextStyle: .body))
                ],
                range: NSRange(location: 0, length: rich.length)
            )
            append(
                rich,
                kind: "quote",
                marker: "▌ ",
                markerColor: .tertiaryLabel,
                to: output
            )
        case .code(let content):
            let rich = NSMutableAttributedString(
                string: content,
                attributes: [
                    .font: UIFont.monospacedSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
                        weight: .regular
                    ),
                    .foregroundColor: UIColor.label,
                    .backgroundColor: UIColor.secondarySystemBackground
                ]
            )
            append(rich, kind: "code", to: output)
        case .rule:
            append(
                NSMutableAttributedString(
                    string: "━━━━━━━━━━━━",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                        .foregroundColor: UIColor.tertiaryLabel
                    ]
                ),
                kind: "rule",
                to: output
            )
        }
    }

    private static func append(
        _ content: NSMutableAttributedString,
        kind: String,
        marker: String? = nil,
        markerColor: UIColor = .secondaryLabel,
        to output: NSMutableAttributedString
    ) {
        let paragraph = paragraphStyle(for: kind)
        if let marker {
            output.append(NSAttributedString(
                string: marker,
                attributes: [
                    .gitNoteBlockKind: kind,
                    .gitNoteMarker: true,
                    .font: boldFont(.preferredFont(forTextStyle: .body)),
                    .foregroundColor: markerColor,
                    .paragraphStyle: paragraph
                ]
            ))
        }
        let contentRange = NSRange(location: 0, length: content.length)
        content.addAttributes(
            [.gitNoteBlockKind: kind, .paragraphStyle: paragraph],
            range: contentRange
        )
        output.append(content)
        output.append(NSAttributedString(
            string: "\n",
            attributes: [
                .gitNoteBlockKind: kind,
                .font: UIFont.preferredFont(forTextStyle: .body),
                .paragraphStyle: paragraph
            ]
        ))
    }

    private static func decodeInline(
        _ markdown: String,
        imageContext: MarkdownImageContext?
    ) -> NSMutableAttributedString {
        guard let expression = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\((<[^>]+>|[^\s\)]+)(?:\s+(?:"[^"]*"|'[^']*'|\([^\)]*\)))?\)"#
        ) else {
            return decodeStandardInline(markdown)
        }

        let source = markdown as NSString
        let matches = expression.matches(
            in: markdown,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return decodeStandardInline(markdown) }

        let output = NSMutableAttributedString()
        var location = 0
        for match in matches {
            if match.range.location > location {
                output.append(decodeStandardInline(source.substring(
                    with: NSRange(location: location, length: match.range.location - location)
                )))
            }

            let altMarkdown = source.substring(with: match.range(at: 1))
            var destination = source.substring(with: match.range(at: 2))
            if destination.hasPrefix("<"), destination.hasSuffix(">") {
                destination.removeFirst()
                destination.removeLast()
            }
            appendImage(
                altMarkdown: altMarkdown,
                destination: destination,
                imageContext: imageContext,
                to: output
            )
            location = NSMaxRange(match.range)
        }
        if location < source.length {
            output.append(decodeStandardInline(source.substring(from: location)))
        }
        return output
    }

    private static func decodeStandardInline(_ markdown: String) -> NSMutableAttributedString {
        guard let parsed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSMutableAttributedString(
                string: markdown,
                attributes: bodyAttributes
            )
        }

        let output = NSMutableAttributedString()
        for run in parsed.runs {
            let value = String(parsed[run.range].characters)
            var attributes = bodyAttributes
            if let intent = run.inlinePresentationIntent {
                let bold = intent.contains(.stronglyEmphasized)
                let italic = intent.contains(.emphasized)
                if intent.contains(.code) {
                    attributes[.font] = UIFont.monospacedSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                        weight: .regular
                    )
                    attributes[.backgroundColor] = UIColor.secondarySystemBackground
                    attributes[.gitNoteInlineCode] = true
                } else if bold && italic {
                    attributes[.font] = boldItalicFont(.preferredFont(forTextStyle: .body))
                } else if bold {
                    attributes[.font] = boldFont(.preferredFont(forTextStyle: .body))
                } else if italic {
                    attributes[.font] = italicFont(.preferredFont(forTextStyle: .body))
                }
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = UIColor.tintColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            output.append(NSAttributedString(string: value, attributes: attributes))
        }
        return output
    }

    private static func appendImage(
        altMarkdown: String,
        destination: String,
        imageContext: MarkdownImageContext?,
        to output: NSMutableAttributedString
    ) {
        let altText = decodeStandardInline(altMarkdown).string
        if let fileURL = imageContext?.localFileURL(for: destination),
           let image = UIImage(contentsOfFile: fileURL.path) {
            let attachment = NSTextAttachment()
            attachment.image = image
            let maximumWidth = min(max(UIScreen.main.bounds.width - 64, 240), 1_000)
            let scale = min(1, maximumWidth / max(image.size.width, 1))
            attachment.bounds = CGRect(
                x: 0,
                y: -4,
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            let rendered = NSMutableAttributedString(attachment: attachment)
            rendered.addAttributes(
                [
                    .gitNoteImageURL: destination,
                    .gitNoteImageAltText: altText
                ],
                range: NSRange(location: 0, length: rendered.length)
            )
            output.append(rendered)
            return
        }

        let fallback = altText.isEmpty ? "image" : altText
        var attributes = bodyAttributes
        attributes[.gitNoteImageURL] = destination
        attributes[.gitNoteImageAltText] = altText
        attributes[.foregroundColor] = UIColor.secondaryLabel
        output.append(NSAttributedString(string: fallback, attributes: attributes))
    }

    private static func encodeInline(
        _ content: NSAttributedString,
        ignoringBold: Bool = false,
        ignoringItalic: Bool = false
    ) -> String {
        var markdown = ""
        content.enumerateAttributes(
            in: NSRange(location: 0, length: content.length),
            options: []
        ) { attributes, range, _ in
            let raw = (content.string as NSString).substring(with: range)
            if let imageURL = attributes[.gitNoteImageURL] as? String {
                let altText = attributes[.gitNoteImageAltText] as? String
                    ?? (raw == "\u{fffc}" ? "" : raw)
                markdown += "![\(escapeInline(altText))](\(imageURL))"
                return
            }
            if attributes[.gitNoteInlineCode] as? Bool == true {
                markdown += "`\(raw.replacingOccurrences(of: "`", with: "\\`"))`"
                return
            }

            var value = escapeInline(raw)
            if let font = attributes[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                let bold = traits.contains(.traitBold) && !ignoringBold
                let italic = traits.contains(.traitItalic) && !ignoringItalic
                if bold && italic {
                    value = "***\(value)***"
                } else if bold {
                    value = "**\(value)**"
                } else if italic {
                    value = "*\(value)*"
                }
            }
            if let link = attributes[.link] as? URL {
                value = "[\(value)](\(link.absoluteString))"
            }
            markdown += value
        }
        return markdown
    }

    private static func contentWithoutMarker(
        in source: NSAttributedString,
        range: NSRange
    ) -> NSAttributedString {
        guard range.length > 0 else { return NSAttributedString(string: "") }
        var contentRange = range
        var effectiveRange = NSRange()
        if source.attribute(
            .gitNoteMarker,
            at: range.location,
            longestEffectiveRange: &effectiveRange,
            in: range
        ) as? Bool == true {
            let markerEnd = min(NSMaxRange(effectiveRange), NSMaxRange(range))
            contentRange.location = markerEnd
            contentRange.length = NSMaxRange(range) - markerEnd
        }
        return source.attributedSubstring(from: contentRange)
    }

    private static func markerText(
        in source: NSAttributedString,
        range: NSRange
    ) -> String? {
        guard range.length > 0 else { return nil }
        var markerRange = NSRange()
        guard source.attribute(
            .gitNoteMarker,
            at: range.location,
            longestEffectiveRange: &markerRange,
            in: range
        ) as? Bool == true else {
            return nil
        }
        return (source.string as NSString).substring(with: markerRange)
    }

    private static func blockKind(in source: NSAttributedString, range: NSRange) -> String {
        guard source.length > 0 else { return "paragraph" }
        let location = min(range.location, source.length - 1)
        return source.attribute(.gitNoteBlockKind, at: location, effectiveRange: nil) as? String
            ?? "paragraph"
    }

    private static func applyBaseFont(
        _ font: UIFont,
        forceBold: Bool,
        to content: NSMutableAttributedString
    ) {
        content.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: content.length),
            options: []
        ) { value, range, _ in
            let oldTraits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            var traits = oldTraits.intersection([.traitBold, .traitItalic])
            if forceBold { traits.insert(.traitBold) }
            content.addAttribute(.font, value: font.withTraits(traits), range: range)
        }
    }

    private static func markStructuralTrait(
        _ trait: UIFontDescriptor.SymbolicTraits,
        key: NSAttributedString.Key,
        in content: NSMutableAttributedString
    ) {
        content.enumerateAttribute(
            .font,
            in: NSRange(location: 0, length: content.length),
            options: []
        ) { value, range, _ in
            let traits = (value as? UIFont)?.fontDescriptor.symbolicTraits ?? []
            if !traits.contains(trait) {
                content.addAttribute(key, value: true, range: range)
            }
        }
    }

    private static var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]
    }

    static func paragraphStyle(for kind: String) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 8
        if ["unordered", "ordered", "quote"].contains(kind) {
            style.firstLineHeadIndent = 4
            style.headIndent = 24
        }
        return style
    }

    static func headingFont(_ level: Int) -> UIFont {
        let style: UIFont.TextStyle
        switch level {
        case 1: style = .largeTitle
        case 2: style = .title1
        case 3: style = .title2
        case 4: style = .title3
        case 5: style = .headline
        default: style = .subheadline
        }
        return boldFont(.preferredFont(forTextStyle: style))
    }

    private static func escapeInline(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["*", "_", "[", "]", "`"] {
            escaped = escaped.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return escaped
    }

    private static func unorderedItem(_ line: String) -> String? {
        if ["-", "*", "+"].contains(line) {
            return ""
        }
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(_ line: String) -> (number: Int, content: String)? {
        guard let dot = line.firstIndex(of: "."),
              let number = Int(line[..<dot]) else {
            return nil
        }
        let afterDot = line.index(after: dot)
        let suffix = line[afterDot...]
        guard suffix.isEmpty || suffix.first == " " else { return nil }
        let content = suffix.first == " " ? suffix.dropFirst() : suffix[...]
        return (number, String(content))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private static func isBlockStart(_ line: String) -> Bool {
        let hashes = line.prefix { $0 == "#" }
        return line.hasPrefix("```")
            || ((1...6).contains(hashes.count) && line.dropFirst(hashes.count).first == " ")
            || isRule(line)
            || unorderedItem(line) != nil
            || orderedItem(line) != nil
            || line.hasPrefix(">")
    }
}

@MainActor
enum MarkdownRichCommandApplier {
    static func apply(_ command: MarkdownEditorCommand, to textView: UITextView) {
        apply(command.action, destination: command.destination, to: textView)
    }

    static func apply(_ action: MarkdownFormatAction, to textView: UITextView) {
        apply(action, destination: nil, to: textView)
    }

    static func handleReturn(in textView: UITextView, replacing rawRange: NSRange) -> Bool {
        let storage = textView.textStorage
        guard storage.length > 0 else { return false }
        let range = clamp(rawRange, to: storage.length)
        let lookupLocation = min(max(range.location - 1, 0), storage.length - 1)
        guard let kind = storage.attribute(
            .gitNoteBlockKind,
            at: lookupLocation,
            effectiveRange: nil
        ) as? String else {
            return false
        }

        let paragraphRange = (storage.string as NSString).paragraphRange(
            for: NSRange(location: lookupLocation, length: 0)
        )
        let content = visibleContent(in: storage, paragraphRange: paragraphRange)

        if ["unordered", "ordered", "quote"].contains(kind),
           content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            removeMarker(at: paragraphRange.location, from: storage)
            let updatedParagraph = (storage.string as NSString).paragraphRange(
                for: NSRange(location: paragraphRange.location, length: 0)
            )
            storage.addAttributes(
                [
                    .gitNoteBlockKind: "paragraph",
                    .paragraphStyle: MarkdownRichCodec.paragraphStyle(for: "paragraph"),
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label,
                    .backgroundColor: UIColor.clear
                ],
                range: updatedParagraph
            )
            textView.selectedRange = NSRange(location: paragraphRange.location, length: 0)
            return true
        }

        let marker: String?
        switch kind {
        case "unordered": marker = "• "
        case "ordered": marker = "\(nextOrderedNumber(in: storage, paragraphRange: paragraphRange)). "
        case "quote": marker = "▌ "
        default: marker = nil
        }

        if let marker {
            let inserted = NSMutableAttributedString(
                string: "\n",
                attributes: [
                    .gitNoteBlockKind: kind,
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .paragraphStyle: MarkdownRichCodec.paragraphStyle(for: kind)
                ]
            )
            inserted.append(NSAttributedString(
                string: marker,
                attributes: [
                    .gitNoteBlockKind: kind,
                    .gitNoteMarker: true,
                    .font: boldFont(.preferredFont(forTextStyle: .body)),
                    .foregroundColor: UIColor.tintColor,
                    .paragraphStyle: MarkdownRichCodec.paragraphStyle(for: kind)
                ]
            ))
            storage.replaceCharacters(in: range, with: inserted)
            textView.selectedRange = NSRange(location: range.location + inserted.length, length: 0)
            return true
        }

        if kind.hasPrefix("heading:") {
            let inserted = NSAttributedString(
                string: "\n",
                attributes: [
                    .gitNoteBlockKind: "paragraph",
                    .font: UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: MarkdownRichCodec.paragraphStyle(for: "paragraph")
                ]
            )
            storage.replaceCharacters(in: range, with: inserted)
            textView.selectedRange = NSRange(location: range.location + 1, length: 0)
            return true
        }

        return false
    }

    private static func apply(
        _ action: MarkdownFormatAction,
        destination: String?,
        to textView: UITextView
    ) {
        switch action {
        case .bold:
            toggleTrait(.traitBold, placeholder: "bold text", in: textView)
        case .italic:
            toggleTrait(.traitItalic, placeholder: "italic text", in: textView)
        case .inlineCode:
            toggleInlineCode(in: textView)
        case .heading(let level):
            applyBlock("heading:\(min(max(level, 1), 6))", to: textView)
        case .paragraph:
            applyBlock("paragraph", to: textView)
        case .unorderedList:
            applyBlock("unordered", to: textView)
        case .orderedList:
            applyBlock("ordered", to: textView)
        case .blockquote:
            applyBlock("quote", to: textView)
        case .codeBlock:
            applyBlock("code", to: textView)
        case .horizontalRule:
            insertRule(in: textView)
        case .link:
            applyLink(image: false, destination: destination, to: textView)
        case .image:
            applyLink(image: true, destination: destination, to: textView)
        }
    }

    static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        return NSRange(
            location: location,
            length: min(max(range.length, 0), length - location)
        )
    }

    private static func toggleTrait(
        _ trait: UIFontDescriptor.SymbolicTraits,
        placeholder: String,
        in textView: UITextView
    ) {
        let range = ensureSelection(placeholder: placeholder, in: textView)
        let storage = textView.textStorage
        var shouldRemove = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, stop in
            guard let font = value as? UIFont,
                  font.fontDescriptor.symbolicTraits.contains(trait) else {
                shouldRemove = false
                stop.pointee = true
                return
            }
        }
        storage.enumerateAttribute(.font, in: range, options: []) { value, attributeRange, _ in
            let font = value as? UIFont ?? .preferredFont(forTextStyle: .body)
            var traits = font.fontDescriptor.symbolicTraits
            if shouldRemove { traits.remove(trait) } else { traits.insert(trait) }
            storage.addAttribute(.font, value: font.withTraits(traits), range: attributeRange)
        }
        textView.selectedRange = range
    }

    private static func toggleInlineCode(in textView: UITextView) {
        let range = ensureSelection(placeholder: "code", in: textView)
        let storage = textView.textStorage
        let enabled = storage.attribute(.gitNoteInlineCode, at: range.location, effectiveRange: nil) as? Bool == true
        if enabled {
            storage.removeAttribute(.gitNoteInlineCode, range: range)
            storage.addAttribute(.backgroundColor, value: UIColor.clear, range: range)
            storage.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: range)
        } else {
            storage.addAttributes(
                [
                    .gitNoteInlineCode: true,
                    .backgroundColor: UIColor.secondarySystemBackground,
                    .font: UIFont.monospacedSystemFont(
                        ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                        weight: .regular
                    )
                ],
                range: range
            )
        }
        textView.selectedRange = range
    }

    private static func applyLink(
        image: Bool,
        destination: String?,
        to textView: UITextView
    ) {
        let range = ensureSelection(
            placeholder: image ? "image description" : "link text",
            in: textView
        )
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.tintColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let destination = destination?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = destination?.isEmpty == false ? destination! : "https://"
        if image {
            attributes[.gitNoteImageURL] = value
        } else if let url = URL(string: value) {
            attributes[.link] = url
        }
        textView.textStorage.addAttributes(attributes, range: range)
        textView.selectedRange = range
    }

    private static func applyBlock(_ kind: String, to textView: UITextView) {
        let storage = textView.textStorage
        let selected = clamp(textView.selectedRange, to: storage.length)
        let source = storage.string as NSString
        let target = source.paragraphRange(for: selected)
        var starts: [Int] = []
        var location = target.location
        while location < NSMaxRange(target), location < storage.length {
            starts.append(location)
            let paragraph = (storage.string as NSString).paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let next = NSMaxRange(paragraph)
            guard next > location else { break }
            location = next
        }
        if starts.isEmpty { starts = [selected.location] }

        for (offset, start) in starts.enumerated().reversed() {
            removeMarker(at: start, from: storage)
            let marker: String?
            switch kind {
            case "unordered": marker = "• "
            case "ordered": marker = "\(offset + 1). "
            case "quote": marker = "▌ "
            default: marker = nil
            }
            if let marker {
                storage.insert(
                    NSAttributedString(
                        string: marker,
                        attributes: [
                            .gitNoteMarker: true,
                            .gitNoteBlockKind: kind,
                            .font: boldFont(.preferredFont(forTextStyle: .body)),
                            .foregroundColor: UIColor.tintColor,
                            .paragraphStyle: MarkdownRichCodec.paragraphStyle(for: kind)
                        ]
                    ),
                    at: start
                )
            }
            let paragraph = (storage.string as NSString).paragraphRange(
                for: NSRange(location: start, length: 0)
            )
            storage.addAttributes(
                [
                    .gitNoteBlockKind: kind,
                    .paragraphStyle: MarkdownRichCodec.paragraphStyle(for: kind)
                ],
                range: paragraph
            )
            restyle(paragraph, as: kind, in: storage)
        }

        let newTarget = (storage.string as NSString).paragraphRange(
            for: NSRange(location: target.location, length: 0)
        )
        textView.selectedRange = clamp(newTarget, to: storage.length)
    }

    private static func insertRule(in textView: UITextView) {
        let selected = clamp(textView.selectedRange, to: textView.textStorage.length)
        let value = NSAttributedString(
            string: "━━━━━━━━━━━━\n",
            attributes: [
                .gitNoteBlockKind: "rule",
                .font: UIFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: UIColor.tertiaryLabel,
                .paragraphStyle: MarkdownRichCodec.paragraphStyle(for: "rule")
            ]
        )
        textView.textStorage.replaceCharacters(in: selected, with: value)
        textView.selectedRange = NSRange(location: selected.location + value.length, length: 0)
    }

    private static func ensureSelection(
        placeholder: String,
        in textView: UITextView
    ) -> NSRange {
        let selected = clamp(textView.selectedRange, to: textView.textStorage.length)
        guard selected.length == 0 else { return selected }
        let attributes = textView.typingAttributes.merging([
            .font: UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label
        ]) { current, _ in current }
        let inserted = NSAttributedString(string: placeholder, attributes: attributes)
        textView.textStorage.insert(inserted, at: selected.location)
        return NSRange(location: selected.location, length: inserted.length)
    }

    private static func removeMarker(at location: Int, from storage: NSMutableAttributedString) {
        guard location < storage.length else { return }
        var range = NSRange()
        guard storage.attribute(
            .gitNoteMarker,
            at: location,
            longestEffectiveRange: &range,
            in: NSRange(location: location, length: storage.length - location)
        ) as? Bool == true else { return }
        storage.deleteCharacters(in: range)
    }

    private static func visibleContent(
        in storage: NSAttributedString,
        paragraphRange: NSRange
    ) -> String {
        guard paragraphRange.length > 0 else { return "" }
        var contentRange = paragraphRange
        var markerRange = NSRange()
        if storage.attribute(
            .gitNoteMarker,
            at: paragraphRange.location,
            longestEffectiveRange: &markerRange,
            in: paragraphRange
        ) as? Bool == true {
            let markerEnd = min(NSMaxRange(markerRange), NSMaxRange(paragraphRange))
            contentRange.location = markerEnd
            contentRange.length = NSMaxRange(paragraphRange) - markerEnd
        }
        return (storage.string as NSString).substring(with: contentRange)
    }

    private static func nextOrderedNumber(
        in storage: NSAttributedString,
        paragraphRange: NSRange
    ) -> Int {
        guard paragraphRange.length > 0 else { return 1 }
        var markerRange = NSRange()
        guard storage.attribute(
            .gitNoteMarker,
            at: paragraphRange.location,
            longestEffectiveRange: &markerRange,
            in: paragraphRange
        ) as? Bool == true else {
            return 1
        }
        let marker = (storage.string as NSString).substring(with: markerRange)
        let digits = marker.prefix { $0.isNumber }
        return (Int(digits) ?? 0) + 1
    }

    private static func restyle(
        _ range: NSRange,
        as kind: String,
        in storage: NSMutableAttributedString
    ) {
        storage.enumerateAttributes(in: range, options: []) { attributes, attributeRange, _ in
            let oldFont = attributes[.font] as? UIFont ?? .preferredFont(forTextStyle: .body)
            var oldTraits = oldFont.fontDescriptor.symbolicTraits
            if attributes[.gitNoteStructuralBold] as? Bool == true {
                oldTraits.remove(.traitBold)
            }
            if attributes[.gitNoteStructuralItalic] as? Bool == true {
                oldTraits.remove(.traitItalic)
            }
            let baseFont: UIFont
            if kind.hasPrefix("heading:"),
               let level = Int(kind.replacingOccurrences(of: "heading:", with: "")) {
                baseFont = MarkdownRichCodec.headingFont(level)
            } else if kind == "code" {
                baseFont = .monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize,
                    weight: .regular
                )
            } else {
                baseFont = .preferredFont(forTextStyle: .body)
            }
            var traits = oldTraits.intersection([.traitBold, .traitItalic])
            if kind.hasPrefix("heading:"), !traits.contains(.traitBold) {
                traits.insert(.traitBold)
                storage.addAttribute(.gitNoteStructuralBold, value: true, range: attributeRange)
            } else {
                storage.removeAttribute(.gitNoteStructuralBold, range: attributeRange)
            }
            if kind == "quote", !traits.contains(.traitItalic) {
                traits.insert(.traitItalic)
                storage.addAttribute(.gitNoteStructuralItalic, value: true, range: attributeRange)
            } else {
                storage.removeAttribute(.gitNoteStructuralItalic, range: attributeRange)
            }
            storage.addAttribute(.font, value: baseFont.withTraits(traits), range: attributeRange)
        }
        storage.addAttribute(
            .backgroundColor,
            value: kind == "code" ? UIColor.secondarySystemBackground : UIColor.clear,
            range: range
        )
        if kind == "quote" {
            storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: range)
        }
    }
}

extension NSAttributedString.Key {
    static let gitNoteBlockKind = NSAttributedString.Key("GitNoteMarkdownBlockKind")
    static let gitNoteMarker = NSAttributedString.Key("GitNoteMarkdownMarker")
    static let gitNoteInlineCode = NSAttributedString.Key("GitNoteMarkdownInlineCode")
    static let gitNoteImageURL = NSAttributedString.Key("GitNoteMarkdownImageURL")
    static let gitNoteImageAltText = NSAttributedString.Key("GitNoteMarkdownImageAltText")
    static let gitNoteStructuralBold = NSAttributedString.Key("GitNoteMarkdownStructuralBold")
    static let gitNoteStructuralItalic = NSAttributedString.Key("GitNoteMarkdownStructuralItalic")
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

func boldFont(_ font: UIFont) -> UIFont {
    font.withTraits(.traitBold)
}

func italicFont(_ font: UIFont) -> UIFont {
    font.withTraits(.traitItalic)
}

func boldItalicFont(_ font: UIFont) -> UIFont {
    font.withTraits([.traitBold, .traitItalic])
}
