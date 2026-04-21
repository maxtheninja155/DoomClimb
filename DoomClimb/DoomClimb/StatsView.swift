import SwiftUI
import Charts

struct StatsView: View {
    @ObservedObject var vm: RouteViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    streakRow
                    summaryRow
                    gradePyramidCard
                    weeklyActivityCard
                }
                .padding()
            }
            .navigationTitle("Stats")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Streak row

    private var streakRow: some View {
        HStack(spacing: 12) {
            streakCard(
                value: currentStreak,
                label: "Current Streak",
                icon: "flame.fill",
                color: .orange
            )
            streakCard(
                value: longestStreak,
                label: "Best Streak",
                icon: "trophy.fill",
                color: .yellow
            )
        }
    }

    private func streakCard(value: Int, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text("\(value)")
                .font(.system(size: 48, weight: .heavy, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(value == 1 ? "day" : "days")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Summary row

    private var summaryRow: some View {
        HStack(spacing: 12) {
            summaryCard(value: vm.store.history.count, label: "Total Climbs", color: .cyan)
            summaryCard(value: vm.store.sends.count,   label: "Total Sends",  color: .green)
            summaryCard(value: vm.store.history.filter(\.isFavorite).count, label: "Favorites", color: .yellow)
        }
    }

    private func summaryCard(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Grade pyramid

    private var gradePyramidCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Grade Pyramid", systemImage: "chart.bar.fill")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))

            if pyramidData.isEmpty {
                emptyChart("Generate some climbs to see your grade breakdown.")
            } else {
                Chart(pyramidData) { item in
                    BarMark(
                        x: .value("Count", item.count),
                        y: .value("Grade", item.grade)
                    )
                    .foregroundStyle(item.isSent ? Color.green : Color.cyan.opacity(0.45))
                    .cornerRadius(4)
                    .annotation(position: .trailing, alignment: .leading) {
                        if item.isSent && item.count > 0 {
                            Text("\(item.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisValueLabel {
                            if let g = value.as(String.self) {
                                Text(g)
                                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                            }
                        }
                    }
                }
                .frame(height: CGFloat(pyramidGrades.count) * 28 + 20)

                HStack(spacing: 16) {
                    legendDot(.green, label: "Sent")
                    legendDot(.cyan.opacity(0.45), label: "Climbed")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Weekly activity

    private var weeklyActivityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Weekly Activity", systemImage: "calendar")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))

            if weeklyData.isEmpty {
                emptyChart("Climb more to see your weekly volume.")
            } else {
                Chart(weeklyData) { item in
                    BarMark(
                        x: .value("Week", item.label),
                        y: .value("Climbs", item.count)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.indigo, .cyan],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .cornerRadius(4)
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text("\(v)")
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic) { value in
                        AxisValueLabel {
                            if let s = value.as(String.self) {
                                Text(s)
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 160)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Empty state

    @ViewBuilder
    private func emptyChart(_ hint: String) -> some View {
        Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
    }

    private func legendDot(_ color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }

    // MARK: - Data helpers

    /// All unique grades that appear in history, sorted ascending.
    private var pyramidGrades: [String] {
        let grades = Set(vm.store.history.map { $0.route.grade })
        return grades.sorted { gradeNum($0) < gradeNum($1) }
    }

    /// Two bars per grade: one for total climbs (cyan), one for sends (green).
    private struct PyramidItem: Identifiable {
        let id = UUID()
        let grade: String
        let count: Int
        let isSent: Bool
    }

    private var pyramidData: [PyramidItem] {
        pyramidGrades.flatMap { grade -> [PyramidItem] in
            let all  = vm.store.history.filter { $0.route.grade == grade }.count
            let sent = vm.store.history.filter { $0.route.grade == grade && $0.isSent }.count
            return [
                PyramidItem(grade: grade, count: all,  isSent: false),
                PyramidItem(grade: grade, count: sent, isSent: true),
            ]
        }
    }

    private func gradeNum(_ grade: String) -> Int {
        Int(grade.dropFirst()) ?? 0
    }

    /// Last 10 calendar weeks, each with a climb count.
    private struct WeekItem: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
        let weekStart: Date
    }

    private var weeklyData: [WeekItem] {
        let cal = Calendar.current
        let now = Date()
        return (0..<10).reversed().compactMap { weeksAgo -> WeekItem? in
            guard let weekStart = cal.date(byAdding: .weekOfYear, value: -weeksAgo, to: now),
                  let interval = cal.dateInterval(of: .weekOfYear, for: weekStart)
            else { return nil }

            let count = vm.store.history.filter {
                interval.contains($0.savedAt)
            }.count

            let formatter = DateFormatter()
            formatter.dateFormat = weeksAgo == 0 ? "'This\nweek'" : "MMM d"
            let label = weeksAgo == 0 ? "This\nweek" : formatter.string(from: interval.start)
            return WeekItem(label: label, count: count, weekStart: interval.start)
        }
    }

    // MARK: - Streak calculations

    private var currentStreak: Int {
        let cal = Calendar.current
        let days = Set(vm.store.history.map { cal.startOfDay(for: $0.savedAt) })
        var date = cal.startOfDay(for: Date())
        if !days.contains(date) {
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        var streak = 0
        while days.contains(date) {
            streak += 1
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        return streak
    }

    private var longestStreak: Int {
        let cal = Calendar.current
        let days = Set(vm.store.history.map { cal.startOfDay(for: $0.savedAt) })
            .sorted()
        var longest = 0
        var current = 0
        var prev: Date?
        for day in days {
            if let p = prev, cal.date(byAdding: .day, value: 1, to: p) == day {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
            prev = day
        }
        return longest
    }
}
