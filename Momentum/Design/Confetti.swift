import SwiftUI

/// A short, joyful burst. Respects Reduce Motion with a calm checkmark instead.
struct ConfettiView: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?
    @State private var pieces: [Piece] = []

    struct Piece {
        var x: Double
        var vx: Double
        var vy: Double
        var spin: Double
        var size: Double
        var color: Color
    }

    private static let palette: [Color] = [.blue, .green, .orange, .pink, .yellow, .purple, .mint]
    private static let duration: Double = 2.2

    var body: some View {
        Group {
            if let startedAt {
                if reduceMotion {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    TimelineView(.animation) { timeline in
                        Canvas { context, size in
                            let t = timeline.date.timeIntervalSince(startedAt)
                            for piece in pieces {
                                let x = piece.x * size.width + piece.vx * t * 60
                                let y = -20 + piece.vy * t * 60 + 0.5 * 420 * t * t
                                guard y < size.height + 20 else { continue }
                                let opacity = max(0, 1 - t / Self.duration)
                                var item = context
                                item.opacity = opacity
                                item.translateBy(x: x, y: y)
                                item.rotate(by: .degrees(piece.spin * t * 360))
                                let rect = CGRect(x: -piece.size / 2, y: -piece.size / 4, width: piece.size, height: piece.size / 2)
                                item.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(piece.color))
                            }
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        pieces = (0..<90).map { _ in
            Piece(x: .random(in: 0...1), vx: .random(in: -2...2), vy: .random(in: -6 ... -1),
                  spin: .random(in: -1.5...1.5), size: .random(in: 7...12), color: Self.palette.randomElement()!)
        }
        withAnimation { startedAt = Date() }
        let token = startedAt
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.duration))
            if startedAt == token { withAnimation { startedAt = nil } }
        }
    }
}
