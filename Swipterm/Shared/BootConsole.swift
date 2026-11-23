import Foundation
import SwiptermKit

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

nonisolated enum ConsoleMeter {
    case download(DownloadMeter)
    case extraction(name: String?, fraction: Double, elapsed: Duration)

    func lines(width: Int) -> [String] {
        switch self {
        case let .download(meter):
            meter.lines(width: width)
        case let .extraction(name, fraction, elapsed):
            ConsoleLayout.progress(name: name, fields: [ConsoleFormat.clock(elapsed / .seconds(1))], fraction: fraction, width: width)
        }
    }
}

nonisolated struct DownloadMeter {
    private struct Sample {
        let time: ContinuousClock.Instant
        let bytes: Int64
    }

    private static let window = Duration.seconds(3)

    private let start: ContinuousClock.Instant
    private let name: String?
    private var now: ContinuousClock.Instant
    private var progress: HTTPDownloadProgress?
    private var samples: [Sample] = []
    private var sourceSamples: [URL: [Sample]] = [:]

    init(start: ContinuousClock.Instant, name: String? = nil) {
        self.start = start
        self.name = name
        now = start
    }

    mutating func update(_ progress: HTTPDownloadProgress) {
        now = .now
        self.progress = progress
        Self.record(progress.bytesWritten, at: now, in: &samples)
        for source in progress.sources {
            Self.record(source.bytesWritten, at: now, in: &sourceSamples[source.url, default: []])
        }
    }

    func lines(width: Int) -> [String] {
        guard let progress else { return [] }
        let elapsed = start.duration(to: now) / .seconds(1)
        let complete = progress.totalBytes.map { progress.bytesWritten >= $0 } ?? false
        let rate = complete ? Double(progress.bytesWritten) / elapsed : Self.rate(samples)
        var eta = "--:--"
        if complete {
            eta = ConsoleFormat.clock(elapsed)
        } else if let rate, rate > 0, let total = progress.totalBytes {
            eta = ConsoleFormat.clock(Double(total - progress.bytesWritten) / rate)
        }
        let fields = [ConsoleFormat.transfer(progress.bytesWritten, of: progress.totalBytes), rate.map(ConsoleFormat.rate), eta]
            .compactMap(\.self)
        let fraction = progress.totalBytes.map { min(max(Double(progress.bytesWritten) / Double(max($0, 1)), 0), 1) }
        guard progress.sources.count > 1 else {
            let name = name ?? progress.sources.first.map { source in
                source.activeStreams > 1 ? "\(Self.host(source)) (\(source.activeStreams)x)" : Self.host(source)
            }
            return ConsoleLayout.progress(name: name, fields: fields, fraction: fraction, width: width)
        }
        let rows = progress.sources.map { source in
            var status = "failed"
            if !source.failed {
                let rate = complete ? Double(source.bytesWritten) / elapsed : Self.rate(sourceSamples[source.url] ?? [])
                status = [rate.map(ConsoleFormat.rate), source.activeStreams > 1 ? "(\(source.activeStreams)x)" : nil]
                    .compactMap(\.self)
                    .joined(separator: " ")
            }
            return ConsoleLayout.Row(name: Self.host(source), size: ConsoleFormat.size(source.bytesWritten), status: status)
        }
        return ConsoleLayout.table(rows, width: width)
            + ConsoleLayout.progress(name: "Total (\(rows.count) mirrors)", fields: fields, fraction: fraction, width: width)
    }

    private static func host(_ source: HTTPDownloadProgress.Source) -> String {
        source.url.host() ?? source.url.absoluteString
    }

    private static func record(_ bytes: Int64, at time: ContinuousClock.Instant, in samples: inout [Sample]) {
        samples.append(Sample(time: time, bytes: bytes))
        while samples.count > 2, samples[1].time.duration(to: time) >= window {
            samples.removeFirst()
        }
    }

    private static func rate(_ samples: [Sample]) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = first.time.duration(to: last.time)
        guard span >= .seconds(1) else { return nil }
        return max(Double(last.bytes - first.bytes) / (span / .seconds(1)), 0)
    }
}

nonisolated enum ConsoleFormat {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB"]

    static func size(_ bytes: Int64) -> String {
        let (divisor, unit) = scale(Double(bytes))
        return String(format: "%.1f", Double(bytes) / divisor) + " " + unit
    }

    static func transfer(_ written: Int64, of total: Int64?) -> String {
        guard let total, written < total else { return size(written) }
        let (divisor, unit) = scale(Double(total))
        return String(format: "%.1f / %.1f", Double(written) / divisor, Double(total) / divisor) + " " + unit
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let (divisor, unit) = scale(bytesPerSecond)
        let value = bytesPerSecond / divisor
        let format = value < 9.995 ? "%.2f" : value < 99.95 ? "%.1f" : "%.0f"
        return String(format: format, value) + " " + unit + "/s"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds < 100 * 3600 else { return "--:--" }
        let seconds = Int(seconds)
        let (hours, minutes) = (seconds / 3600, seconds / 60 % 60)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
        }
        return String(format: "%02d:%02d", minutes, seconds % 60)
    }

    private static func scale(_ value: Double) -> (divisor: Double, unit: String) {
        var divisor = 1.0
        var index = 0
        while index < units.count - 1, value / divisor > 2048 {
            divisor *= 1024
            index += 1
        }
        return (divisor, units[index])
    }
}

nonisolated enum ConsoleLayout {
    struct Row {
        let name: String
        let size: String
        let status: String
    }

    private static let minimumBar = 10
    private static let minimumName = 8

    static func progress(name: String?, fields: [String], fraction: Double?, width: Int) -> [String] {
        guard let fraction else {
            return Self.info(name: name, fields: fields, width: width)
        }
        let info = fields.joined(separator: " ")
        let percent = String(format: "%3d%%", Int(fraction * 100))
        let tail = info.count + 1 + 1 + percent.count
        if let name {
            let room = width - 1 - 2 - tail - minimumBar
            if room >= min(name.count, minimumName) {
                let label = compact(name, to: room)
                let available = width - 1 - label.count - 2 - tail
                let barWidth = min(available, max(minimumBar, width * 2 / 5))
                return [" " + label + String(repeating: " ", count: 2 + available - barWidth) + info + " " + bar(fraction, width: barWidth) + " " + percent]
            }
        } else if width - 1 - tail >= minimumBar {
            let barWidth = min(width - 1 - tail, max(minimumBar, width * 2 / 5))
            return [" " + info + " " + bar(fraction, width: barWidth) + " " + percent]
        }
        return Self.info(name: name, fields: fields, width: width) + [" " + bar(fraction, width: width - 2 - percent.count) + " " + percent]
    }

    static func table(_ rows: [Row], width: Int) -> [String] {
        let sizeWidth = rows.map(\.size.count).max() ?? 0
        let statusWidth = rows.map(\.status.count).max() ?? 0
        var room = width - 1 - 2 - sizeWidth - 2 - statusWidth
        let showsStatus = room >= minimumName
        if !showsStatus {
            room = width - 1 - 2 - sizeWidth
        }
        let nameWidth = max(min(rows.map(\.name.count).max() ?? 0, room), 1)
        return rows.map { row in
            let name = compact(row.name, to: nameWidth)
            var line = " " + name + String(repeating: " ", count: nameWidth - name.count)
            line += "  " + String(repeating: " ", count: sizeWidth - row.size.count) + row.size
            if showsStatus {
                line += "  " + String(repeating: " ", count: statusWidth - row.status.count) + row.status
            }
            return line
        }
    }

    private static func info(name: String?, fields: [String], width: Int) -> [String] {
        var fields = fields
        while fields.count > 1, 1 + fields.joined(separator: " ").count > width {
            fields.removeLast()
        }
        let info = String(fields.joined(separator: " ").prefix(width - 1))
        guard let name else {
            return [" " + info]
        }
        let gap = width - 1 - name.count - info.count
        if gap >= 2 {
            return [" " + name + String(repeating: " ", count: gap) + info]
        }
        return [" " + compact(name, to: width - 1), " " + info]
    }

    private static func compact(_ name: String, to width: Int) -> String {
        guard name.count > width else { return name }
        var name = Substring(name)
        if let prefix = ["mirrors.", "mirror."].first(where: { name.hasPrefix($0) }) {
            name = name.dropFirst(prefix.count)
        }
        return String(name.prefix(width))
    }

    private static func bar(_ fraction: Double, width: Int) -> String {
        let inner = max(width - 2, 0)
        let filled = Int(Double(inner) * fraction)
        return "[" + String(repeating: "#", count: filled) + String(repeating: "-", count: inner - filled) + "]"
    }
}
