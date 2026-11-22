import Foundation

final nonisolated class ConsoleNewlineNormalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastByteWasCR = false

    func normalize(_ data: Data) -> Data {
        lock.withLock {
            var out = Data()
            out.reserveCapacity(data.count + 16)
            for byte in data {
                if byte == 0x0A, !lastByteWasCR {
                    out.append(0x0D)
                }
                out.append(byte)
                lastByteWasCR = (byte == 0x0D)
            }
            return out
        }
    }
}

nonisolated enum ConsoleText {
    static func plain(_ chunks: [Data]) -> String {
        var data = Data()
        for chunk in chunks {
            data.append(chunk)
        }
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        var scalars = String(decoding: data, as: UTF8.self).unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let scalar = pending {
                pending = nil
                return scalar
            }
            return scalars.next()
        }
        while let scalar = next() {
            switch scalar {
            case "\u{1B}":
                skipEscape(next: next)
            case "\n":
                lines.append(String(line))
                line.removeAll()
            case "\r":
                let following = next()
                if following != "\n" {
                    line.removeAll()
                }
                pending = following
            case "\u{8}":
                if !line.isEmpty {
                    line.removeLast()
                }
            case "\t":
                line.append(scalar)
            default:
                if scalar.value >= 0x20, scalar.value != 0x7F {
                    line.append(scalar)
                }
            }
        }
        if !line.isEmpty {
            lines.append(String(line))
        }
        return lines.joined(separator: "\n")
    }

    private static func skipEscape(next: () -> Unicode.Scalar?) {
        guard let introducer = next() else { return }
        switch introducer {
        case "[":
            while let scalar = next(), !(0x40 ... 0x7E).contains(scalar.value) {}
        case "]", "P", "_", "^":
            var previous: Unicode.Scalar?
            while let scalar = next() {
                if scalar == "\u{7}" || (previous == "\u{1B}" && scalar == "\\") {
                    break
                }
                previous = scalar
            }
        default:
            var scalar: Unicode.Scalar? = introducer
            while let current = scalar, (0x20 ... 0x2F).contains(current.value) {
                scalar = next()
            }
        }
    }
}

nonisolated enum ConsoleProgressLine {
    private static let barWidths = 10 ... 40

    static func render(fraction: Double?, detail: String?, width: Int) -> String {
        let percent = fraction.map { String(format: "%3ld%%", Int($0 * 100)) }
        let text = [percent, detail].compactMap(\.self).joined(separator: " ")
        if let fraction {
            let barWidth = min(width - text.count - 3, barWidths.upperBound)
            if barWidth >= barWidths.lowerBound {
                let filled = Int(Double(barWidth) * fraction)
                return "[" + String(repeating: "#", count: filled) + String(repeating: "-", count: barWidth - filled) + "] " + text
            }
        }
        if text.count <= width {
            return text
        }
        if let percent, percent.count <= width {
            return percent
        }
        return String(text.prefix(width))
    }
}
