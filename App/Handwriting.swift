import SwiftUI

/// Draws each glyph as if a pen were writing it: a left-to-right wipe across the letter,
/// with a little ink blur that sharpens and a tiny settle. Letters are scheduled one after
/// another, so a burst of streamed tokens is still written in sequence.
struct HandwritingRenderer: TextRenderer {
    /// Start time (seconds since reference date) per glyph index. Glyphs past the end are
    /// treated as already written.
    var starts: [Double]
    var now: Double
    static let stroke: Double = 0.32

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                for glyph in run {
                    defer { index += 1 }
                    let progress = index < starts.count ? min(1, max(0, (now - starts[index]) / Self.stroke)) : 1
                    if progress >= 1 { context.draw(glyph); continue }
                    if progress <= 0 { continue }
                    let eased = 1 - pow(1 - progress, 3)
                    let bounds = glyph.typographicBounds.rect
                    var pen = context
                    pen.clip(to: Path(CGRect(x: bounds.minX - 2, y: bounds.minY - 6, width: (bounds.width + 4) * eased, height: bounds.height + 12)))
                    pen.opacity = min(1, progress * 1.8)
                    pen.addFilter(.blur(radius: (1 - eased) * 1.4))
                    pen.translateBy(x: 0, y: (1 - eased) * 1.6)
                    pen.draw(glyph)
                }
            }
        }
    }
}

/// Tracks when each character of a growing string arrived and renders it with the pen.
struct HandwrittenText: View {
    let text: AttributedString
    let live: Bool
    @State private var starts: [Double] = []
    @State private var settled = true

    /// Seconds between consecutive letters when a chunk arrives at once.
    private static let gap = 0.016

    var body: some View {
        TimelineView(.animation(paused: settled)) { timeline in
            Text(text)
                .textRenderer(HandwritingRenderer(starts: starts, now: timeline.date.timeIntervalSinceReferenceDate))
        }
        .onAppear { if live { schedule(from: 0) } }
        .onChange(of: glyphCount) { old, new in
            if new < old { starts = Array(starts.prefix(new)); return }
            if live || !starts.isEmpty { schedule(from: old) }
        }
        .task(id: starts.count) {
            guard let last = starts.last else { settled = true; return }
            let remaining = last + HandwritingRenderer.stroke + 0.05 - Date.now.timeIntervalSinceReferenceDate
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            if !Task.isCancelled { settled = true }
        }
    }

    /// Glyph-ish count: rendered characters minus line breaks (which draw no glyph).
    private var glyphCount: Int { text.characters.reduce(0) { $0 + ($1.isNewline ? 0 : 1) } }

    private func schedule(from old: Int) {
        let now = Date.now.timeIntervalSinceReferenceDate
        var next = max(now, (starts.last ?? 0) + Self.gap)
        if starts.count > old { starts = Array(starts.prefix(old)) }
        while starts.count < old { starts.append(0) } // earlier glyphs: already written
        for _ in old..<glyphCount {
            starts.append(next)
            next += Self.gap
        }
        settled = false
    }
}

/// Makes a partially streamed reply safe to lay out, so nothing already on screen moves.
enum StreamingText {
    /// While generating: show only whole words (a half word at the end of a line would
    /// otherwise jump to the next line once it completes), and temporarily close any open
    /// `**bold**` or `code` span (otherwise its markers show as raw text, then vanish and
    /// reflow the paragraph). Finished text is returned unchanged.
    static func stable(_ text: String, live: Bool) -> String {
        guard live else { return text }
        guard let cut = text.lastIndex(where: { $0.isWhitespace }) else { return "" }
        var body = String(text[...cut])
        // Put closers before trailing whitespace: Markdown ignores a closer after a space.
        let trailing = String(body.reversed().prefix { $0.isWhitespace }.reversed())
        body.removeLast(trailing.count)
        if body.components(separatedBy: "**").count % 2 == 0 { body += "**" }
        if body.filter({ $0 == "`" }).count % 2 == 1 { body += "`" }
        return body + trailing
    }
}
