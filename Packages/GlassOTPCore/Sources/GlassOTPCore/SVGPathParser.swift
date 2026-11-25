import CoreGraphics
import Foundation

private final class PathCacheStore: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: CGPath] = [:]

    func get(_ key: String) -> CGPath? {
        lock.withLock { map[key] }
    }

    func set(_ key: String, path: CGPath) {
        lock.withLock { map[key] = path }
    }
}

public enum SVGPathParser {
    private static let cache = PathCacheStore()

    public static func parse(_ d: String) -> CGPath? {
        let trimmed = d.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cached = cache.get(trimmed) {
            return cached
        }

        guard let parsed = parseUncached(trimmed) else { return nil }
        cache.set(trimmed, path: parsed)
        return parsed
    }

    private static func parseUncached(_ d: String) -> CGPath? {
        let path = CGMutablePath()
        var scanner = PathScanner(d)

        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero
        var prevCommand: Character = "\0"
        var prevCubicControl: CGPoint?
        var prevQuadControl: CGPoint?

        while !scanner.isAtEnd {
            scanner.skipSeparators()
            guard !scanner.isAtEnd else { break }

            let command: Character
            if let ch = scanner.peek(), ch.isLetter {
                _ = scanner.advance()
                command = ch
            } else {
                guard prevCommand != "\0" else { return nil }
                if prevCommand == "M" {
                    command = "L"
                } else if prevCommand == "m" {
                    command = "l"
                } else {
                    command = prevCommand
                }
            }

            switch command {
            case "M", "m":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { return nil }
                let pt = command == "m"
                    ? CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
                    : CGPoint(x: x, y: y)
                path.move(to: pt)
                currentPoint = pt
                subpathStart = pt
                prevCubicControl = nil
                prevQuadControl = nil

            case "L", "l":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { return nil }
                let pt = command == "l"
                    ? CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
                    : CGPoint(x: x, y: y)
                path.addLine(to: pt)
                currentPoint = pt
                prevCubicControl = nil
                prevQuadControl = nil

            case "H", "h":
                guard let x = scanner.readNumber() else { return nil }
                let targetX = command == "h" ? currentPoint.x + x : x
                let pt = CGPoint(x: targetX, y: currentPoint.y)
                path.addLine(to: pt)
                currentPoint = pt
                prevCubicControl = nil
                prevQuadControl = nil

            case "V", "v":
                guard let y = scanner.readNumber() else { return nil }
                let targetY = command == "v" ? currentPoint.y + y : y
                let pt = CGPoint(x: currentPoint.x, y: targetY)
                path.addLine(to: pt)
                currentPoint = pt
                prevCubicControl = nil
                prevQuadControl = nil

            case "C", "c":
                guard let x1 = scanner.readNumber(),
                      let y1 = scanner.readNumber(),
                      let x2 = scanner.readNumber(),
                      let y2 = scanner.readNumber(),
                      let x = scanner.readNumber(),
                      let y = scanner.readNumber() else { return nil }
                let rel = (command == "c")
                let c1 = rel ? CGPoint(x: currentPoint.x + x1, y: currentPoint.y + y1) : CGPoint(x: x1, y: y1)
                let c2 = rel ? CGPoint(x: currentPoint.x + x2, y: currentPoint.y + y2) : CGPoint(x: x2, y: y2)
                let pt = rel ? CGPoint(x: currentPoint.x + x, y: currentPoint.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: pt, control1: c1, control2: c2)
                currentPoint = pt
                prevCubicControl = c2
                prevQuadControl = nil

            case "S", "s":
                guard let x2 = scanner.readNumber(),
                      let y2 = scanner.readNumber(),
                      let x = scanner.readNumber(),
                      let y = scanner.readNumber() else { return nil }
                let c1: CGPoint
                if let prev = prevCubicControl {
                    c1 = CGPoint(x: 2 * currentPoint.x - prev.x, y: 2 * currentPoint.y - prev.y)
                } else {
                    c1 = currentPoint
                }
                let rel = (command == "s")
                let c2 = rel ? CGPoint(x: currentPoint.x + x2, y: currentPoint.y + y2) : CGPoint(x: x2, y: y2)
                let pt = rel ? CGPoint(x: currentPoint.x + x, y: currentPoint.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: pt, control1: c1, control2: c2)
                currentPoint = pt
                prevCubicControl = c2
                prevQuadControl = nil

            case "Q", "q":
                guard let x1 = scanner.readNumber(),
                      let y1 = scanner.readNumber(),
                      let x = scanner.readNumber(),
                      let y = scanner.readNumber() else { return nil }
                let rel = (command == "q")
                let ctrl = rel ? CGPoint(x: currentPoint.x + x1, y: currentPoint.y + y1) : CGPoint(x: x1, y: y1)
                let pt = rel ? CGPoint(x: currentPoint.x + x, y: currentPoint.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: pt, control: ctrl)
                currentPoint = pt
                prevQuadControl = ctrl
                prevCubicControl = nil

            case "T", "t":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { return nil }
                let ctrl: CGPoint
                if let prev = prevQuadControl {
                    ctrl = CGPoint(x: 2 * currentPoint.x - prev.x, y: 2 * currentPoint.y - prev.y)
                } else {
                    ctrl = currentPoint
                }
                let pt = command == "t"
                    ? CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
                    : CGPoint(x: x, y: y)
                path.addQuadCurve(to: pt, control: ctrl)
                currentPoint = pt
                prevQuadControl = ctrl
                prevCubicControl = nil

            case "A", "a":
                guard let rx = scanner.readNumber(),
                      let ry = scanner.readNumber(),
                      let xAxisRotation = scanner.readNumber(),
                      let largeArc = scanner.readFlag(),
                      let sweep = scanner.readFlag(),
                      let x = scanner.readNumber(),
                      let y = scanner.readNumber() else { return nil }
                let pt = command == "a"
                    ? CGPoint(x: currentPoint.x + x, y: currentPoint.y + y)
                    : CGPoint(x: x, y: y)
                addSVGArc(
                    to: path,
                    from: currentPoint,
                    to: pt,
                    rx: rx,
                    ry: ry,
                    angleDegrees: xAxisRotation,
                    largeArc: largeArc,
                    sweep: sweep
                )
                currentPoint = pt
                prevCubicControl = nil
                prevQuadControl = nil

            case "Z", "z":
                path.closeSubpath()
                currentPoint = subpathStart
                prevCubicControl = nil
                prevQuadControl = nil

            default:
                return nil
            }

            prevCommand = command
        }

        return path.copy()
    }

    private static func addSVGArc(
        to path: CGMutablePath,
        from p0: CGPoint,
        to p1: CGPoint,
        rx rawRx: CGFloat,
        ry rawRy: CGFloat,
        angleDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        guard p0 != p1 else { return }
        var rx = abs(rawRx)
        var ry = abs(rawRy)
        guard rx > 1e-6, ry > 1e-6 else {
            path.addLine(to: p1)
            return
        }

        let phi = angleDegrees * .pi / 180.0
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx2 = (p0.x - p1.x) / 2.0
        let dy2 = (p0.y - p1.y) / 2.0
        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        var rx2 = rx * rx
        var ry2 = ry * ry
        let x1p2 = x1p * x1p
        let y1p2 = y1p * y1p

        let lambda = x1p2 / rx2 + y1p2 / ry2
        if lambda > 1.0 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
            rx2 = rx * rx
            ry2 = ry * ry
        }

        let num = max(0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
        let den = rx2 * y1p2 + ry2 * x1p2
        let factor = den > 0 ? sqrt(num / den) : 0
        let sign: CGFloat = (largeArc == sweep) ? -1.0 : 1.0

        let cxp = sign * factor * (rx * y1p / ry)
        let cyp = sign * factor * -(ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2.0
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2.0

        func vecAngle(ux: CGFloat, uy: CGFloat, vx: CGFloat, vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            guard len > 0 else { return 0 }
            let clamped = max(-1.0, min(1.0, dot / len))
            let angle = acos(clamped)
            return (ux * vy - uy * vx) < 0 ? -angle : angle
        }

        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry

        let theta1 = vecAngle(ux: 1, uy: 0, vx: ux, vy: uy)
        var dTheta = vecAngle(ux: ux, uy: uy, vx: vx, vy: vy)
        if !sweep && dTheta > 0 {
            dTheta -= 2.0 * .pi
        } else if sweep && dTheta < 0 {
            dTheta += 2.0 * .pi
        }

        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2.0))))
        let delta = dTheta / CGFloat(segments)
        let t = (4.0 / 3.0) * tan(delta / 4.0)

        for i in 0..<segments {
            let a1 = theta1 + CGFloat(i) * delta
            let a2 = a1 + delta

            let cos1 = cos(a1), sin1 = sin(a1)
            let cos2 = cos(a2), sin2 = sin(a2)

            let e1x = cos1 - t * sin1
            let e1y = sin1 + t * cos1
            let e2x = cos2 + t * sin2
            let e2y = sin2 - t * cos2

            func mapPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                let px = x * rx
                let py = y * ry
                return CGPoint(
                    x: cosPhi * px - sinPhi * py + cx,
                    y: sinPhi * px + cosPhi * py + cy
                )
            }

            let cp1 = mapPoint(e1x, e1y)
            let cp2 = mapPoint(e2x, e2y)
            let endPt = (i == segments - 1) ? p1 : mapPoint(cos2, sin2)
            path.addCurve(to: endPt, control1: cp1, control2: cp2)
        }
    }
}

private struct PathScanner {
    private let chars: [Character]
    private var index = 0

    init(_ string: String) {
        self.chars = Array(string)
    }

    var isAtEnd: Bool { index >= chars.count }

    func peek() -> Character? {
        guard index < chars.count else { return nil }
        return chars[index]
    }

    mutating func advance() -> Character? {
        guard index < chars.count else { return nil }
        let ch = chars[index]
        index += 1
        return ch
    }

    mutating func skipSeparators() {
        while index < chars.count {
            let ch = chars[index]
            if ch.isWhitespace || ch == "," {
                index += 1
            } else {
                break
            }
        }
    }

    mutating func readFlag() -> Bool? {
        skipSeparators()
        guard let ch = peek(), ch == "0" || ch == "1" else { return nil }
        index += 1
        return ch == "1"
    }

    mutating func readNumber() -> CGFloat? {
        skipSeparators()
        guard index < chars.count else { return nil }

        let start = index
        if chars[index] == "+" || chars[index] == "-" {
            index += 1
        }

        var hasDigits = false
        while index < chars.count && chars[index].isNumber {
            hasDigits = true
            index += 1
        }

        if index < chars.count && chars[index] == "." {
            index += 1
            while index < chars.count && chars[index].isNumber {
                hasDigits = true
                index += 1
            }
        }

        guard hasDigits else {
            index = start
            return nil
        }

        if index < chars.count && (chars[index] == "e" || chars[index] == "E") {
            let expStart = index
            index += 1
            if index < chars.count && (chars[index] == "+" || chars[index] == "-") {
                index += 1
            }
            var expDigits = false
            while index < chars.count && chars[index].isNumber {
                expDigits = true
                index += 1
            }
            if !expDigits {
                index = expStart
            }
        }

        let str = String(chars[start..<index])
        guard let value = Double(str) else { return nil }
        return CGFloat(value)
    }
}
