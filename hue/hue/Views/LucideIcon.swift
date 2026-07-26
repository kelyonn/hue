import SwiftUI

// MARK: - SVGPathParser

/// Minimal SVG path-data (`d` attribute) parser — supports exactly the
/// commands Lucide's icon set uses (M/m, L/l, H/h, V/v, C/c, A/a, Z/z, both
/// absolute and relative, including implicit command repetition). Ported so
/// the app can use Lucide icons' *exact* geometry: the Hue.dc.html design
/// handoff is explicit that SF Symbols are not a substitute — their stroke
/// weight and geometry differ from Lucide's.
enum SVGPathParser {
    static func path(from d: String) -> Path {
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero

        let scanner = Scanner(string: d)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines)

        func number() -> CGFloat? {
            scanner.scanDouble().map { CGFloat($0) }
        }

        while let cmd = scanner.scanCharacter() {
            switch cmd {
            case "M", "m":
                guard let x = number(), let y = number() else { continue }
                let relative = cmd == "m"
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: current)
                subpathStart = current
                // Extra coordinate pairs after M/m are implicit linetos.
                while let nx = number(), let ny = number() {
                    current = relative ? CGPoint(x: current.x + nx, y: current.y + ny) : CGPoint(x: nx, y: ny)
                    path.addLine(to: current)
                }

            case "L", "l":
                let relative = cmd == "l"
                while let x = number(), let y = number() {
                    current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                    path.addLine(to: current)
                }

            case "H", "h":
                let relative = cmd == "h"
                while let x = number() {
                    current = relative ? CGPoint(x: current.x + x, y: current.y) : CGPoint(x: x, y: current.y)
                    path.addLine(to: current)
                }

            case "V", "v":
                let relative = cmd == "v"
                while let y = number() {
                    current = relative ? CGPoint(x: current.x, y: current.y + y) : CGPoint(x: current.x, y: y)
                    path.addLine(to: current)
                }

            case "C", "c":
                let relative = cmd == "c"
                while let x1 = number(), let y1 = number(),
                      let x2 = number(), let y2 = number(),
                      let x  = number(), let y  = number() {
                    let base = relative ? current : .zero
                    let c1 = CGPoint(x: base.x + x1, y: base.y + y1)
                    let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                    let end = CGPoint(x: base.x + x, y: base.y + y)
                    path.addCurve(to: end, control1: c1, control2: c2)
                    current = end
                }

            case "A", "a":
                let relative = cmd == "a"
                while let rx = number(), let ry = number(), let rot = number(),
                      let largeArc = number(), let sweep = number(),
                      let x = number(), let y = number() {
                    let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                    addArc(to: &path, from: current, to: end, rx: rx, ry: ry,
                           xAxisRotationDeg: rot, largeArc: largeArc != 0, sweep: sweep != 0)
                    current = end
                }

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart

            default:
                break
            }
        }

        return path
    }

    /// SVG's endpoint arc parameterization → centre parameterization (SVG 1.1
    /// spec, appendix F.6.5). Every arc actually used by this app's 4 Lucide
    /// icons has `rx == ry` and zero rotation, so the result is drawn as a
    /// true circular arc — this is not a general ellipse renderer.
    private static func addArc(
        to path: inout Path,
        from p1: CGPoint, to p2: CGPoint,
        rx: CGFloat, ry: CGFloat, xAxisRotationDeg: CGFloat,
        largeArc: Bool, sweep: Bool
    ) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p1 != p2 else {
            path.addLine(to: p2)
            return
        }

        let phi = xAxisRotationDeg * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        let dx2 = (p1.x - p2.x) / 2, dy2 = (p1.y - p2.y) / 2
        let x1p =  cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale; ry *= scale
        }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let num = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = den == 0 ? 0 : sign * sqrt(num / den)
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        func angleBetween(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(max(-1, min(1, len == 0 ? 1 : dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angleBetween(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angleBetween((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        path.addArc(
            center: CGPoint(x: cx, y: cy),
            radius: rx,
            startAngle: .radians(theta1),
            endAngle: .radians(theta1 + dTheta),
            clockwise: dTheta < 0
        )
    }
}

// MARK: - LucideShape

/// A stroked Lucide icon, built from raw SVG path-data strings (24×24
/// viewBox, matching Lucide's own). Scales geometry to fit the shape's rect
/// while keeping stroke width constant in view space (set via `.stroke(...)`
/// at the call site, same as any other `Shape`).
struct LucideShape: Shape {
    let paths: [String]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        var combined = Path()
        for d in paths {
            combined.addPath(SVGPathParser.path(from: d).applying(transform))
        }
        return combined
    }
}

// MARK: - LucideIcon

/// Exact path data for the 4 Lucide icons the permission screen uses
/// (`design_handoff_hue_canvas/README.md` § Permission), copied verbatim from
/// the inlined SVGs in the Hue.dc.html design handoff.
enum LucideIcon {
    static let audioWaveform = [
        "M2 13a2 2 0 0 0 2-2V7a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0V4a2 2 0 0 1 4 0v13a2 2 0 0 0 4 0v-4a2 2 0 0 1 2-2"
    ]

    static let eyeOff = [
        "M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49",
        "M14.084 14.158a3 3 0 0 1-4.242-4.242",
        "M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143",
        "m2 2 20 20"
    ]

    static let shieldCheck = [
        "M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z",
        "m9 12 2 2 4-4"
    ]

    static let arrowUpRight = [
        "M7 7h10v10",
        "M7 17 17 7"
    ]

    /// Lucide `info` — circle with an i, used for the in-window help button.
    static let info = [
        "M12 16v-4",
        "M12 8h.01",
        "M12 2a10 10 0 1 0 0 20 10 10 0 1 0 0-20z"
    ]

    /// Lucide `x` — close the info overlay.
    static let x = [
        "M18 6 6 18",
        "M6 6l12 12"
    ]
}
