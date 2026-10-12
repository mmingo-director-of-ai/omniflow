import SwiftUI

/// Native selectable Markdown presentation. Copy uses the untouched source string.
struct MarkdownView: View {
    let source: String
    private enum Block { case text(String), heading(String), quote(String), code(String), table([[String]]), chart(DictatedChart) }
    private var blocks: [Block] {
        let lines = source.components(separatedBy: .newlines)
        var output: [Block] = []; var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                let fence = String(line.prefix(while: { $0 == "`" }))
                let language = String(line.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                i += 1; var code: [String] = []
                while i < lines.count && !lines[i].hasPrefix(fence) { code.append(lines[i]); i += 1 }
                let payload = code.joined(separator: "\n")
                if language == "freeflow-chart", let spec = DictatedChart.parse(json: payload) { output.append(.chart(spec)) }
                else { output.append(.code(payload)) }
            } else if i + 1 < lines.count, line.contains("|"), lines[i + 1].contains("-"),
                      lines[i + 1].allSatisfy({ "|:- \t".contains($0) }) {
                var rows = [cells(line)]; i += 2
                while i < lines.count && lines[i].contains("|") { rows.append(cells(lines[i])); i += 1 }
                output.append(.table(rows)); continue
            } else if line.hasPrefix("> ") {
                output.append(.quote(String(line.dropFirst(2))))
            } else if line.hasPrefix("#") {
                output.append(.heading(String(line.drop(while: { $0 == "#" || $0 == " " }))))
            } else if !line.isEmpty { output.append(.text(line)) }
            i += 1
        }
        return output
    }
    private func cells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(.init((text.hasPrefix("- ") || text.hasPrefix("* ")) ? "• " + text.dropFirst(2) : text)).font(.system(size: 13)).lineSpacing(4)
                case .quote(let text):
                    Text(.init(text)).font(.system(size: 13)).foregroundStyle(.secondary)
                        .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.4)).frame(width: 2) }
                case .heading(let text): Text(text).font(.system(size: 15, weight: .semibold)).padding(.top, 5)
                case .code(let code):
                    ScrollView(.horizontal) { Text(code).font(.system(size: 12, design: .monospaced)).padding(12) }
                        .background(Color.flowInk.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                case .chart(let spec): DictatedChartView(spec: spec)
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        Text(.init(cell)).font(.system(size: 12, weight: rowIndex == 0 ? .semibold : .regular)).frame(minWidth: 80, alignment: .leading)
                                    }
                                }
                                if rowIndex == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(12)
                    }.background(Color.flowInk.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
}

/// HTML is projected into native text formatting, never loaded into a browser.
/// Attributes other than a validated link destination are discarded; resources never load.
enum AssistantMarkup {
    static func formatted(_ source: String) -> String {
        var result: [String] = []
        var outside: [String] = []
        var fenced = false
        func flush() { if !outside.isEmpty { result.append(html(outside.joined(separator: "\n"))); outside = [] } }
        for line in source.components(separatedBy: "\n") {
            if line.hasPrefix("```") { flush(); fenced.toggle(); result.append(line) }
            else if fenced { result.append(line) }
            else { outside.append(line) }
        }
        flush()
        return result.joined(separator: "\n")
    }

    static func html(_ source: String) -> String {
        guard source.range(of: #"</?[a-zA-Z][^>]*>"#, options: .regularExpression) != nil else { return source }
        let blocked: Set<String> = ["script", "style", "head", "iframe", "object", "embed", "svg", "math", "template", "form", "video", "audio"]
        let voids: Set<String> = ["img", "br", "hr", "meta", "link", "input", "embed", "source", "area", "base", "wbr"]
        var hidden: [String] = []
        var links: [String?] = []
        var output = ""
        var row: [String] = []
        var cell: String?
        var firstRow = true
        var preText: String?
        func append(_ text: String) { if cell != nil { cell! += text } else { output += text } }
        func escape(_ text: String) -> String {
            text.reduce(into: "") { result, char in
                if "\\`*_[]<>#|".contains(char) { result += "\\" }
                result.append(char)
            }
        }
        for token in ReaderMarkup.tokens(source) {
            switch token {
            case .text(let text):
                if hidden.isEmpty {
                    if preText != nil { preText! += text } else { append(escape(text)) }
                }
            case .start(let name, let attributes, let selfClosing):
                if !hidden.isEmpty || blocked.contains(name) {
                    if !selfClosing && !voids.contains(name) { hidden.append(name) }
                    continue
                }
                if preText != nil { continue }
                switch name {
                case "p", "div", "section", "article": append("\n\n")
                case "h1", "h2", "h3", "h4", "h5", "h6": append("\n\n## ")
                case "br": append("\n")
                case "strong", "b": append("**")
                case "em", "i": append("*")
                case "li": append("\n- ")
                case "blockquote": append("\n> ")
                case "code": append("`")
                case "pre": preText = ""
                case "a":
                    let link = safeWebURL(attributes["href"])?.absoluteString
                        .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                    links.append(link)
                    if link != nil { append("[") }
                case "table": firstRow = true; append("\n\n")
                case "tr": row = []
                case "td", "th": cell = ""
                default: break
                }
            case .end(let name):
                if !hidden.isEmpty {
                    if let i = hidden.lastIndex(of: name) { hidden.removeSubrange(i...) }
                    continue
                }
                if let code = preText {
                    if name == "pre" {
                        let longest = code.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
                        let fence = String(repeating: "`", count: max(3, longest + 1))
                        append("\n\n" + fence + "\n" + code + "\n" + fence + "\n\n")
                        preText = nil
                    }
                    continue
                }
                switch name {
                case "p", "div", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "ul", "ol", "blockquote": append("\n\n")
                case "strong", "b": append("**")
                case "em", "i": append("*")
                case "code": append("`")
                case "a": if let last = links.popLast(), let link = last { append("](\(link))") }
                case "td", "th": if let value = cell { row.append(value.trimmingCharacters(in: .whitespacesAndNewlines)); cell = nil }
                case "tr":
                    if !row.isEmpty {
                        output += "| " + row.joined(separator: " | ") + " |\n"
                        if firstRow { output += "| " + row.map { _ in "---" }.joined(separator: " | ") + " |\n"; firstRow = false }
                    }
                default: break
                }
            }
        }
        if let code = preText { append(escape(code)) }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AssistantReplyView: View {
    let source: String
    var body: some View {
        MarkdownView(source: AssistantMarkup.formatted(source))
            .environment(\.openURL, OpenURLAction { url in
                guard safeWebURL(url.absoluteString) != nil else { return .discarded }
                return .systemAction
            })
    }
}
