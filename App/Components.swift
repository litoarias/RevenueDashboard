import RevenueKit
import SwiftUI

// MARK: - Formato

func amountParts(_ d: Decimal) -> (int: String, frac: String) {
    let v = NSDecimalNumber(decimal: d).doubleValue
    let s = v.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "es_ES")))
    guard let i = s.lastIndex(of: ",") else { return (s, "00") }
    return (String(s[..<i]), String(s[s.index(after: i)...]))
}

func eur(_ d: Decimal) -> String { let p = amountParts(d); return "\(p.int),\(p.frac) €" }

func dayLabel(_ d: Date?) -> String {
    guard let d else { return "—" }
    var f = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).locale(Locale(identifier: "es_ES"))
    f = f.day().month(.abbreviated)
    return d.formatted(f)
}

// MARK: - Tipografía

extension Font {
    static func eyebrow(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font { .system(size: size, weight: weight, design: .serif) }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(.eyebrow()).tracking(1.4).foregroundStyle(.secondary) }
}

// MARK: - Número protagonista

struct HeroAmount: View {
    let value: Decimal?
    var size: CGFloat = 84

    var body: some View {
        Group {
            if let value {
                let p = amountParts(value)
                Text(p.int).font(.serif(size, .ultraLight)) + Text(",\(p.frac)").font(.serif(size * 0.38, .light)).foregroundColor(.secondary)
                    + Text(" €").font(.serif(size * 0.38, .light)).foregroundColor(.secondary)
            } else {
                Text("—").font(.serif(size, .ultraLight)).foregroundColor(.secondary)
            }
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
        .contentTransition(.numericText())
    }
}

// MARK: - Composición: una sola barra, proporcional

struct CompositionBar: View {
    let parts: [(source: RevenueSource, value: Decimal)]
    var height: CGFloat = 8

    var body: some View {
        let total = parts.reduce(Decimal(0)) { $0 + $1.value }
        GeometryReader { g in
            HStack(spacing: 2) {
                if total <= 0 {
                    Capsule().fill(.quaternary)
                } else {
                    ForEach(parts.filter { $0.value > 0 }, id: \.source) { p in
                        Capsule().fill(p.source.color)
                            .frame(width: max(4, g.size.width * CGFloat(truncating: (p.value / total) as NSDecimalNumber)))
                    }
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Aura: el color de fondo refleja de dónde viene el dinero

struct Aura: View {
    let shares: [(Color, Double)]
    var body: some View {
        ZStack {
            ForEach(Array(shares.enumerated()), id: \.offset) { i, s in
                Circle().fill(s.0).frame(width: 260, height: 260).blur(radius: 90)
                    .opacity(0.10 + 0.30 * s.1)
                    .offset(x: CGFloat(i - 1) * 110, y: CGFloat(i % 2) * 30)
            }
        }
        .frame(height: 260).allowsHitTesting(false)
    }
}

// MARK: - Estado de una fuente

enum SourceState { case ok, missing, failed(String)
    var color: Color { switch self { case .ok: .green; case .missing: .orange; case .failed: .red } }
}

struct SourcePill: View {
    let name: String, through: Date?, state: SourceState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(name).fontWeight(.medium)
            Text({ if case .ok = state { return "hasta \(dayLabel(through))" } else { return "sin conectar" } }())
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12)).lineLimit(1).fixedSize()
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }
}

extension RevenueSource {
    var color: Color {
        switch self {
        case .ads: Color(red: 1.0, green: 0.58, blue: 0.22)
        case .subscription: Color(red: 0.25, green: 0.85, blue: 0.62)
        case .iap: Color(red: 0.42, green: 0.55, blue: 1.0)
        case .app: Color(red: 0.78, green: 0.45, blue: 0.95)
        }
    }
}

struct HeroNumber: View {
    let text: String
    var size: CGFloat = 84
    var body: some View {
        Text(text).font(.serif(size, .ultraLight)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
            .contentTransition(.numericText())
    }
}

func count(_ n: Int) -> String { n.formatted(.number.locale(Locale(identifier: "es_ES"))) }

// MARK: - Granularidad de los gráficos largos

/// 7–30 días: barras diarias. 90–180: semanales. 365: mensuales.
enum Granularity {
    case day, week, month

    init(days: Int) { self = days <= 30 ? .day : days <= 180 ? .week : .month }

    var unit: Calendar.Component { self == .day ? .day : self == .week ? .weekOfYear : .month }
    var noun: String { self == .day ? "día" : self == .week ? "semana" : "mes" }
    var singular: String { self == .day ? "ese día" : self == .week ? "esa semana" : "ese mes" }

    private static var utc: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 2; return c
    }()

    func bucket(_ d: Date) -> Date {
        self == .day ? d : Self.utc.dateInterval(of: unit, for: d)?.start ?? d
    }

    func axisCount(days: Int) -> Int {
        switch self {
        case .day: days <= 7 ? 1 : 7
        case .week: days <= 90 ? 2 : 4
        case .month: 2
        }
    }

    func label(_ d: Date) -> String {
        var f = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).locale(Locale(identifier: "es_ES"))
        switch self {
        case .day: f = f.day().month(.abbreviated)
        case .week: return "sem. " + d.formatted(f.day().month(.abbreviated))
        case .month: f = f.month(.wide).year()
        }
        return d.formatted(f)
    }

    func axisLabel(_ d: Date) -> String {
        var f = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).locale(Locale(identifier: "es_ES"))
        f = self == .month ? f.month(.abbreviated) : f.day().month(.abbreviated)
        return d.formatted(f)
    }
}

func periodName(_ days: Int) -> String {
    switch days { case 7: "7 días"; case 30: "30 días"; case 90: "90 días"; case 180: "6 meses"; case 365: "1 año"; default: "\(days) días" }
}
func periodShort(_ days: Int) -> String {
    switch days { case 180: "6m"; case 365: "1a"; default: "\(days)d" }
}

func periodEyebrow(_ days: Int) -> String {
    switch days { case 180: "últimos 6 meses"; case 365: "último año"; default: "últimos \(days) días" }
}
