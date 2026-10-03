import SwiftUI

struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        let terms = query.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).filter { !$0.contains(":") }
        let pattern = terms.sorted { $0.count > $1.count }.first ?? ""
        if pattern.isEmpty {
            Text(text)
        } else {
            Text(highlighted(pattern))
        }
    }

    private func highlighted(_ term: String) -> AttributedString {
        var output = AttributedString(text)
        var searchStart = output.startIndex
        while let range = output[searchStart...].range(of: term, options: .caseInsensitive) {
            output[range].backgroundColor = .yellow.opacity(0.55)
            output[range].foregroundColor = .primary
            searchStart = range.upperBound
            if searchStart == output.endIndex { break }
        }
        return output
    }
}
