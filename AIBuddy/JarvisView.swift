import SwiftUI

// Native port of the Jarvis HUD from web/avatar.js — holographic rings that
// pulse and react to the buddy's state. States: idle | listening | thinking | speaking.

private struct HUDStyle {
    let hue: Double
    let sat: Double
    let glow: Double
    let spin: Double
}

private let hudStyles: [String: HUDStyle] = [
    "idle": HUDStyle(hue: 190, sat: 65, glow: 0.45, spin: 0.18),
    "listening": HUDStyle(hue: 207, sat: 95, glow: 0.85, spin: 0.4),
    "thinking": HUDStyle(hue: 38, sat: 95, glow: 0.75, spin: 1.7),
    "speaking": HUDStyle(hue: 187, sat: 95, glow: 1.0, spin: 0.55)
]

/// Approximate CSS hsla() with SwiftUI's HSB color space.
private func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double) -> Color {
    let b = min(1.0, l / 50.0)
    let sat = l <= 50 ? s / 100.0 : max(0.0, (s / 100.0) * (1.0 - (l - 50.0) / 55.0))
    return Color(hue: h / 360.0, saturation: sat, brightness: b, opacity: a)
}

private final class JarvisHolder {
    var bars = [Double](repeating: 0.04, count: 48)
    var smooth = 0.0
    var ripples: [(r: Double, a: Double)] = []
    var rippleTimer = 0.0
    var lastTime: Double? = nil
    var t = 0.0
}

struct JarvisView: View {
    var state: String
    var level: Double

    @State private var holder = JarvisHolder()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size, now: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func noise(_ i: Double, _ tt: Double) -> Double {
        0.5 + 0.28 * sin(i * 1.7 + tt * 11) + 0.22 * sin(i * 3.1 - tt * 7 + 1.3)
    }

    private func draw(ctx: GraphicsContext, size: CGSize, now: Double) {
        let h = holder
        let dt = min(0.05, now - (h.lastTime ?? now))
        h.lastTime = now
        h.t += dt
        h.smooth += (level - h.smooth) * 0.35
        let s = hudStyles[state] ?? hudStyles["idle"]!
        // keep all geometry in Double — mixing CGFloat and Double makes cos/sin ambiguous
        let cx = Double(size.width) / 2
        let cy = Double(size.height) / 2 - Double(size.height) * 0.03
        let R = Double(min(size.width, size.height)) * 0.3
        let t = h.t
        func col(_ l: Double, _ a: Double) -> Color { hsl(s.hue, s.sat, l, a) }

        // listening ripples
        if state == "listening" {
            h.rippleTimer -= dt
            if h.rippleTimer <= 0 {
                h.ripples.append((r: R * 0.5, a: 0.5))
                h.rippleTimer = 0.8
            }
        }
        h.ripples = h.ripples.compactMap { old in
            var rp = old
            rp.r += dt * R * 1.2
            rp.a *= 1 - dt * 1.6
            return rp.a > 0.01 ? rp : nil
        }
        for rp in h.ripples {
            let p = Path(ellipseIn: CGRect(x: cx - rp.r, y: cy - rp.r, width: rp.r * 2, height: rp.r * 2))
            ctx.stroke(p, with: .color(col(70, rp.a)), lineWidth: 1.5)
        }

        // core glow
        let coreR = R * 0.4 * (1 + 0.1 * sin(t * 2.2) + 0.55 * h.smooth)
        let glowR = coreR * 1.9
        let grad = Gradient(stops: [
            Gradient.Stop(color: col(85, 0.95 * s.glow), location: 0),
            Gradient.Stop(color: col(60, 0.5 * s.glow), location: 0.35),
            Gradient.Stop(color: col(50, 0), location: 1)
        ])
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - glowR, y: cy - glowR, width: glowR * 2, height: glowR * 2)),
            with: .radialGradient(grad, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: glowR)
        )
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - coreR * 0.55, y: cy - coreR * 0.55, width: coreR * 1.1, height: coreR * 1.1)),
            with: .color(col(92, 0.9))
        )

        // audio bars ring
        for i in 0..<48 {
            var target = 0.04
            if state == "speaking" {
                target = h.smooth * (0.25 + 0.75 * noise(Double(i), t))
            } else if state == "thinking" {
                target = 0.1 + 0.08 * noise(Double(i), t * 2)
            } else if state == "listening" {
                target = 0.06 + 0.05 * noise(Double(i), t)
            }
            h.bars[i] += (target - h.bars[i]) * 0.35
            let ang = Double(i) / 48.0 * .pi * 2 + t * s.spin * 0.3
            let r0 = R * 0.62
            let r1 = r0 + h.bars[i] * R * 0.55
            var p = Path()
            p.move(to: CGPoint(x: cx + cos(ang) * r0, y: cy + sin(ang) * r0))
            p.addLine(to: CGPoint(x: cx + cos(ang) * r1, y: cy + sin(ang) * r1))
            ctx.stroke(p, with: .color(col(70, 0.35 + h.bars[i] * 0.6)), lineWidth: 2)
        }

        // rotating dashed arcs
        let arcs: [(r: Double, w: Double, dir: Double, span: Double, dash: [CGFloat])] = [
            (R * 0.95, 2.5, 1, 1.9, [26, 14]),
            (R * 1.08, 1.5, -1, 2.6, [8, 10]),
            (R * 1.22, 1.0, 1, 2.2, [2, 7])
        ]
        for a in arcs {
            let start = t * s.spin * a.dir
            var p = Path()
            p.addArc(
                center: CGPoint(x: cx, y: cy), radius: a.r,
                startAngle: .radians(start), endAngle: .radians(start + a.span * .pi),
                clockwise: false
            )
            ctx.stroke(p, with: .color(col(65, 0.5)), style: StrokeStyle(lineWidth: a.w, dash: a.dash))
        }

        // outer tick ring
        for i in 0..<72 {
            let ang = Double(i) / 72.0 * .pi * 2 - t * s.spin * 0.15
            let big = i % 6 == 0
            let r0 = R * 1.32
            let r1 = r0 + (big ? 7.0 : 3.0)
            var p = Path()
            p.move(to: CGPoint(x: cx + cos(ang) * r0, y: cy + sin(ang) * r0))
            p.addLine(to: CGPoint(x: cx + cos(ang) * r1, y: cy + sin(ang) * r1))
            ctx.stroke(p, with: .color(col(70, big ? 0.55 : 0.25)), lineWidth: 1)
        }

        // status label
        let labels = ["idle": "· ONLINE ·", "listening": "● LISTENING", "thinking": "◌ THINKING", "speaking": "▶ SPEAKING"]
        ctx.draw(
            Text(labels[state] ?? "")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(col(75, 0.75)),
            at: CGPoint(x: cx, y: cy + R * 1.32 + 26)
        )
    }
}
