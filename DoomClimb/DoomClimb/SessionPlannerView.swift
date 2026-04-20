import SwiftUI

// MARK: - Session Types

enum SessionType: String, CaseIterable, Identifiable {
    case easy    = "Easy Day"
    case normal  = "Normal Session"
    case project = "Project Day"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .easy:    return "leaf.fill"
        case .normal:  return "figure.climbing"
        case .project: return "flame.fill"
        }
    }

    var tint: Color {
        switch self {
        case .easy:    return .green
        case .normal:  return .cyan
        case .project: return .red
        }
    }

    var description: String {
        switch self {
        case .easy:    return "Low-intensity session. Lots of volume, nothing too hard."
        case .normal:  return "Balanced workout with warmups, base grade, and a project."
        case .project: return "Hard session focused on pushing above your base grade."
        }
    }

    /// Structure of the session: ordered list of (category, gradeOffset) tuples.
    /// `gradeOffset` is added to the base grade — e.g. -2 = two grades easier.
    var structure: [(category: SessionCategory, gradeOffset: Int)] {
        switch self {
        case .easy:
            return [
                (.warmup, -3), (.warmup, -3),
                (.base, -1), (.base, -1), (.base, -1),
                (.base, 0),
            ]
        case .normal:
            return [
                (.warmup, -2), (.warmup, -2),
                (.base, 0), (.base, 0), (.base, 0),
                (.project, +1),
            ]
        case .project:
            return [
                (.warmup, -2),
                (.base, 0), (.base, 0),
                (.project, +1), (.project, +1), (.project, +1),
            ]
        }
    }
}

enum SessionCategory: String, Codable {
    case warmup, base, project

    var label: String {
        switch self {
        case .warmup:  return "Warm-up"
        case .base:    return "Base"
        case .project: return "Project"
        }
    }

    var tint: Color {
        switch self {
        case .warmup:  return .green
        case .base:    return .cyan
        case .project: return .red
        }
    }
}

// MARK: - Session Planner View

struct SessionPlannerView: View {
    @ObservedObject var vm: RouteViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: SessionType = .normal
    @State private var baseGrade: Double = 5
    @State private var angle: Double = 40
    @State private var isGenerating = false

    // Celebration
    @State private var confettiTrigger: Int = 0
    @State private var showCompletionSheet = false
    @State private var didCelebrateCurrentSession = false
    @State private var completionStats: (sent: Int, skipped: Int) = (0, 0)

    var body: some View {
        NavigationStack {
            ZStack {
                Group {
                    if vm.session.isEmpty {
                        setupView
                    } else {
                        sessionListView
                    }
                }
                .navigationTitle(vm.session.isEmpty ? "Session Planner" : "Your Session")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    if !vm.session.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("New", role: .destructive) {
                                withAnimation {
                                    vm.clearSession()
                                    didCelebrateCurrentSession = false
                                }
                            }
                        }
                    }
                }

                // Confetti always lives at the top of the ZStack so it
                // renders over NavigationLink destinations too.
                ConfettiBurst(trigger: $confettiTrigger)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                // Completion card: inline overlay so it presents cleanly
                // even when a NavigationLink destination is visible, avoiding
                // the "presenting from detached view controller" warning that
                // occurs when a nested .sheet is triggered from a nav-pushed child.
                if showCompletionSheet {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { }  // swallow taps

                    completionCard
                        .padding(.horizontal, 24)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showCompletionSheet)
        }
        .onChange(of: completionKey) { _, newKey in checkForCompletion(key: newKey) }
    }

    /// Stable key that changes whenever any entry's effective done/skipped
    /// state changes. `.onChange` on this fires the completion detector.
    private var completionKey: String {
        vm.session.map { e -> String in
            let done = isEntryDone(e)
            let skip = e.status == .skipped
            return "\(e.id.uuidString.prefix(8)):\(done ? "d" : skip ? "s" : "p")"
        }.joined(separator: "|")
    }

    /// Fires the big celebration when every entry is either done or skipped,
    /// but only once per session (resets when a new session is built).
    /// Uses the key value directly so counts are derived from the same
    /// snapshot that triggered the change — no risk of stale store reads.
    private func checkForCompletion(key: String) {
        guard !vm.session.isEmpty, !didCelebrateCurrentSession else { return }

        // completionKey encodes state as "<uuid-prefix>:d" / ":s" / ":p"
        let parts = key.split(separator: "|").map(String.init)
        guard !parts.isEmpty else { return }

        let allResolved = parts.allSatisfy { $0.hasSuffix(":d") || $0.hasSuffix(":s") }
        guard allResolved else { return }

        let sent    = parts.filter { $0.hasSuffix(":d") }.count
        let skipped = parts.filter { $0.hasSuffix(":s") }.count

        didCelebrateCurrentSession = true
        completionStats = (sent, skipped)

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        confettiTrigger &+= 1

        // Let confetti start before the card slides in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showCompletionSheet = true
            }
        }
    }

    // MARK: - Completion card

    @ViewBuilder
    private var completionCard: some View {
        VStack(spacing: 18) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 52))
                .foregroundStyle(.yellow)
                .shadow(color: .yellow.opacity(0.4), radius: 14)
                .padding(.top, 8)

            Text("Session Complete!")
                .font(.system(.title2, design: .rounded, weight: .bold))

            HStack(spacing: 20) {
                statChip(value: "\(completionStats.sent)",
                         label: "Sent",
                         color: .green,
                         icon: "checkmark.seal.fill")
                statChip(value: "\(completionStats.skipped)",
                         label: "Skipped",
                         color: .secondary,
                         icon: "forward.end.fill")
            }

            Text(encouragement)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 10) {
                Button {
                    withAnimation {
                        showCompletionSheet = false
                        vm.clearSession()
                        didCelebrateCurrentSession = false
                    }
                } label: {
                    Text("New Session")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Finish") {
                    withAnimation { showCompletionSheet = false }
                    dismiss()
                }
                .font(.subheadline)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func statChip(value: String, label: String, color: Color, icon: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Short varied line based on how the session went. Kept to a single
    /// short sentence so the popup stays a dopamine hit, not a wall of text.
    private var encouragement: String {
        let sent = completionStats.sent
        let skipped = completionStats.skipped
        if sent == 0 { return "Every session counts. Rest up and come back strong." }
        if skipped == 0 { return "Flawless run — you cleared the board!" }
        if sent >= skipped { return "Strong session. The skipped ones are tomorrow's sends." }
        return "Nice work getting through it. Progress, not perfection."
    }

    // MARK: - Setup view

    @ViewBuilder
    private var setupView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Plan a full climbing session tailored to your grade. DoomClimb will generate warm-ups, base climbs, and a project.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                VStack(spacing: 10) {
                    ForEach(SessionType.allCases) { type in
                        sessionTypeCard(type)
                    }
                }

                ControlCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Base Grade", systemImage: "figure.climbing")
                            Spacer()
                            Text("V\(Int(baseGrade))")
                                .font(.title3.bold())
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        Slider(value: $baseGrade, in: 0...16, step: 1)
                            .tint(.green)
                    }
                }

                ControlCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Wall Angle", systemImage: "angle")
                            Spacer()
                            Text("\(Int(angle))°")
                                .font(.title3.bold())
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                        Slider(value: $angle, in: 0...60, step: 5)
                            .tint(.orange)
                    }
                }

                Button {
                    Task { await generateSession() }
                } label: {
                    HStack {
                        if isGenerating { ProgressView().tint(.white) }
                        Text(isGenerating ? "Building session…" : "Generate Session")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedType.tint)
                .disabled(isGenerating)
            }
            .padding()
        }
    }

    private func sessionTypeCard(_ type: SessionType) -> some View {
        Button {
            withAnimation { selectedType = type }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: type.iconName)
                    .font(.title2)
                    .foregroundStyle(type.tint)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.rawValue)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(type.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                if selectedType == type {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(type.tint)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(selectedType == type ? type.tint : .clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Session list view

    @ViewBuilder
    private var sessionListView: some View {
        VStack(spacing: 0) {
            progressHeader
                .padding()
                .background(.ultraThinMaterial)

            List {
                ForEach(vm.session) { entry in
                    sessionRow(entry)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
        }
        .navigationDestination(for: UUID.self) { climbId in
            ClimbDetailView(vm: vm, climbId: climbId)
        }
    }

    /// An entry is "done" when its underlying climb is marked sent OR the
    /// user explicitly marked the slot done. Deriving from `isSent` keeps
    /// the planner in sync with the Send Tracker in ClimbDetailView.
    private func isEntryDone(_ entry: SessionEntry) -> Bool {
        if entry.status == .done { return true }
        if let climb = vm.store.history.first(where: { $0.id == entry.climbId }) {
            return climb.isSent
        }
        return false
    }

    private var progressHeader: some View {
        let done = vm.session.filter(isEntryDone).count
        let total = vm.session.count
        return VStack(spacing: 8) {
            HStack {
                Text("Progress")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                Spacer()
                Text("\(done)/\(total) complete")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.green)
            }
            ProgressView(value: Double(done), total: Double(total))
                .tint(.green)
        }
    }

    @ViewBuilder
    private func sessionRow(_ entry: SessionEntry) -> some View {
        if let climb = vm.store.history.first(where: { $0.id == entry.climbId }) {
            let done = isEntryDone(entry)
            let skipped = entry.status == .skipped

            NavigationLink(value: climb.id) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(entry.category.tint.opacity(0.15))
                        .overlay(
                            Text(climb.route.grade)
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(entry.category.tint)
                        )
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.category.label)
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(entry.category.tint)
                            if done {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else if skipped {
                                Image(systemName: "forward.end.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(vm.store.displayName(for: climb))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(climb.route.grade)
                            Text("•")
                            Text("\(climb.route.angle)°")
                            Text("•")
                            Text("\(climb.route.moveCount) moves")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    Button {
                        withAnimation {
                            vm.setSessionEntryStatus(
                                entryId: entry.id,
                                status: skipped ? .pending : .skipped
                            )
                        }
                    } label: {
                        Image(systemName: skipped ? "arrow.uturn.backward" : "forward.end")
                            .font(.callout)
                            .foregroundStyle(skipped ? .orange : .secondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(skipped ? 0.5 : 1.0)
        }
    }

    // MARK: - Generation

    private func generateSession() async {
        isGenerating = true
        defer { isGenerating = false }
        await vm.generateSession(
            type: selectedType,
            baseGrade: Int(baseGrade),
            angle: Int(angle)
        )
    }
}
