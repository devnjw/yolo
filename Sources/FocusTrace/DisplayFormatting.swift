import Foundation

func shareLabel(_ fraction: Double) -> String {
    if fraction > 0 && fraction < 0.01 { return "<1%" }
    return "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
}

func dayLabel(_ date: Date) -> String {
    let label = date.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US")))
    return Calendar.current.isDateInToday(date) ? "Today · \(label)" : label
}

func clockLabel(_ date: Date) -> String {
    date.formatted(.dateTime.hour().minute().second().locale(Locale(identifier: "en_GB")))
}

func timeLabel(_ seconds: Double) -> String {
    if seconds > 0 && seconds < 1 { return "<1s" }
    let value = max(0, Int(seconds))
    if value >= 3600 { return "\(value / 3600)h \(value % 3600 / 60)m" }
    if value >= 60 { return "\(value / 60)m \(value % 60)s" }
    return "\(value)s"
}
