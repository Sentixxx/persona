import SwiftUI
import WatchKit
import PersonaWire

extension InteractionKind {
    /// The kind's colour in the dashboard's ring language (`Theme.Watch`).
    var watchTint: Color {
        switch self {
        case .permission, .plan: Theme.Watch.approvalTint
        case .question, .screen, .elicitation: Theme.Watch.questionTint
        }
    }
}

/// How many sessions need you, in the middle of a ring whose arcs are the waiting approvals, questions and messages.
/// The arcs show the mix; they are not a breakdown of the middle figure (`WatchDashboard`).
struct WatchCountRing: View {
    var count: Int
    var parts: [(count: Int, tint: Color)]
    @ScaledMetric(relativeTo: .title) private var diameter = Theme.Watch.ringDiameter

    var body: some View {
        let size = min(diameter, Theme.Watch.ringMaxDiameter)
        ZStack {
            WatchArcs(parts: parts.filter { $0.count > 0 }.map { (Double($0.count), $0.tint) },
                      stroke: Theme.Watch.ringStroke, gap: Theme.Watch.ringGap)
            Text(WatchCountRing.shown(count)).font(Theme.Watch.ringFigure).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(Theme.Watch.figureMinScale)
                .padding(.horizontal, Theme.Watch.ringStroke)
        }
        .frame(width: size, height: size)
    }

    static func shown(_ count: Int) -> String { count > Theme.Watch.countLimit ? "99+" : String(count) }
}

/// A running session's done / started as a small ring.
struct WatchProgressRing: View {
    var done: Int
    var started: Int
    @ScaledMetric(relativeTo: .body) private var diameter = Theme.Watch.progressRing

    var body: some View {
        let fraction = Double(min(done, started)) / Double(max(started, 1))
        WatchArcs(parts: fraction > 0 ? [(fraction, StatusPalette.working.dot)] : [], total: 1,
                  stroke: Theme.Watch.progressStroke, gap: 0)
            .frame(width: diameter, height: diameter)
            .accessibilityElement()
            .accessibilityLabel(Text("\(done) of \(started) done [Watch Dashboard]"))
    }
}

/// Arcs around a track, from twelve o'clock, with rounded ends.
private struct WatchArcs: View {
    var parts: [(Double, Color)]
    var total: Double?
    var stroke: CGFloat
    var gap: Double

    var body: some View {
        let sum = total ?? max(1, parts.map(\.0).reduce(0, +))
        let gap = parts.count > 1 ? gap : 0
        ZStack {
            Circle().stroke(Theme.Watch.ringTrack, lineWidth: stroke)
            ForEach(parts.indices, id: \.self) { index in
                let start = parts.prefix(index).map(\.0).reduce(0, +) / sum
                let end = start + parts[index].0 / sum
                Circle().trim(from: start + gap / 2, to: max(start + gap / 2, end - gap / 2))
                    .stroke(parts[index].1, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(stroke / 2)
    }
}

/// The count ring with its legend: approvals, questions and messages, each figure in its arc's colour.
struct WatchCountSummary: View {
    var dashboard: WatchDashboard

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) { ring; legend }
            VStack(alignment: .leading, spacing: Theme.Space.s) { ring; legend }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StateName.count(.needsYou, dashboard.needsYou))
        .accessibilityValue([WatchCountKind.approvals, .questions, .messages].map { $0.spoken(count($0)) }
            .joined(separator: ", "))
    }

    private var ring: some View {
        WatchCountRing(count: dashboard.needsYou, parts: [(dashboard.approvals, Theme.Watch.approvalTint),
                                                         (dashboard.questions, Theme.Watch.questionTint),
                                                         (dashboard.messages, Theme.Watch.messageTint)])
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            row(.approvals, Theme.Watch.approvalTint)
            row(.questions, Theme.Watch.questionTint)
            row(.messages, Theme.Watch.messageTint)
        }
    }

    /// The kind's glyph and figure in its colour: short in every language, clear of the toolbar and page dots. The
    /// words are spoken (`accessibilityValue`).
    private func row(_ kind: WatchCountKind, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Theme.Icon.image(kind.symbol).font(Theme.Watch.tag).foregroundStyle(tint)
            Text(WatchCountRing.shown(count(kind))).font(Theme.Watch.legendFigure).monospacedDigit()
        }
        .opacity(count(kind) == 0 ? Theme.Watch.quietOpacity : 1)
    }

    private func count(_ kind: WatchCountKind) -> Int {
        switch kind {
        case .approvals: dashboard.approvals
        case .questions: dashboard.questions
        case .messages: dashboard.messages
        }
    }
}

/// A request as a page's subject: its kind in its colour, what it asks, and the chat it came from.
struct WatchRequestSubject: View {
    var request: Interaction
    var showsKind = true
    var lineLimit: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            if showsKind {
                Label(request.kind.watchTitle, systemImage: request.kind.watchSymbol)
                    .font(Theme.Watch.tag).foregroundStyle(request.kind.watchTint).lineLimit(1)
            }
            Text(request.watchSummary).font(Theme.Watch.subject).lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
            if let title = request.sessionTitle, !title.isEmpty {
                Text(title).font(Theme.Watch.tag).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hold to confirm. The fill follows the press for `holdDuration`; letting go earlier empties it, so a brushed wrist
/// never approves. VoiceOver's activate confirms at once. `.ring` is the detail page's; `.capsule` sits beside Deny.
struct WatchHoldToConfirm: View {
    enum Shape { case ring, capsule }
    var shape: Shape
    var title: String
    var hint: String
    var confirm: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var progress: CGFloat = 0
    @ScaledMetric(relativeTo: .title) private var diameter = Theme.Watch.holdDiameter

    var body: some View {
        control
            .contentShape(shape == .ring ? AnyShape(Circle()) : AnyShape(Capsule()))
            .onLongPressGesture(minimumDuration: Theme.Watch.holdDuration) {
                confirm()
                progress = 0
            } onPressingChanged: { pressing in
                guard enabled else { return }
                if pressing { WKInterfaceDevice.current().play(.start) }
                withAnimation(pressing ? .linear(duration: Theme.Watch.holdDuration) : Theme.Watch.holdRelease) {
                    progress = pressing ? 1 : 0
                }
            }
            .opacity(enabled ? 1 : Theme.Watch.quietOpacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if enabled { confirm() } }
    }

    @ViewBuilder private var control: some View {
        switch shape {
        case .ring:
            let size = min(diameter, Theme.Watch.ringMaxDiameter)
            ZStack {
                Circle().fill(Theme.Watch.confirmTint.opacity(Theme.Watch.confirmWash))
                    .padding(Theme.Watch.holdStroke + Theme.Space.xs)
                Circle().stroke(Theme.Watch.ringTrack, lineWidth: Theme.Watch.holdStroke)
                    .padding(Theme.Watch.holdStroke / 2)
                Circle().trim(from: 0, to: progress)
                    .stroke(Theme.Watch.confirmTint, style: StrokeStyle(lineWidth: Theme.Watch.holdStroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(Theme.Watch.holdStroke / 2)
                Theme.Icon.image(Theme.Icon.done).font(Theme.Watch.ringFigure).foregroundStyle(Theme.Watch.confirmTint)
            }
            .frame(width: size, height: size)
        case .capsule:
            Label(hint, systemImage: Theme.Icon.done)
                .font(Theme.Font.bodyStrong).lineLimit(1).minimumScaleFactor(Theme.Watch.figureMinScale)
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Space.m)
                .frame(maxWidth: .infinity, minHeight: Theme.Watch.minRowHeight)
                .background {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.Watch.confirmTint.opacity(Theme.Watch.confirmWash))
                            Capsule().fill(Theme.Watch.confirmTint)
                                .frame(width: max(geometry.size.height, geometry.size.width * progress))
                                .opacity(progress > 0 ? 1 : 0)
                        }
                    }
                }
        }
    }
}

/// Approve or turn down a permission or plan request: a round Deny (Revise for a plan) beside hold to confirm. At
/// accessibility text sizes the two stack and Deny says its word.
struct WatchDecisionControl: View {
    var kind: InteractionKind
    var shape: WatchHoldToConfirm.Shape
    var resolve: (Resolution) -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        if textSize.isAccessibilitySize {
            VStack(spacing: Theme.Space.s) {
                hold(.capsule)
                Button(action: decline) { Text(declineTitle).lineLimit(1).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        } else if shape == .ring {
            HStack(alignment: .center, spacing: Theme.Space.flush) {
                declineButton
                Spacer(minLength: Theme.Space.flush)
                hold(.ring)
                Spacer(minLength: Theme.Space.flush)
                Text(hint).font(Theme.Watch.tag).foregroundStyle(Theme.Watch.confirmTint)
                    .multilineTextAlignment(.leading).lineLimit(3).minimumScaleFactor(Theme.Watch.figureMinScale)
                    .frame(width: Theme.Watch.hintWidth, alignment: .leading)
                    .accessibilityHidden(true)
            }
        } else {
            HStack(spacing: Theme.Space.s) {
                declineButton
                hold(.capsule)
            }
        }
    }

    private func hold(_ shape: WatchHoldToConfirm.Shape) -> some View {
        WatchHoldToConfirm(shape: shape, title: confirmTitle, hint: hint) {
            resolve(kind == .plan ? Resolution(approve: true, mode: "acceptEdits") : Resolution(allow: true))
        }
    }

    private var declineButton: some View {
        Button(action: decline) {
            Theme.Icon.image(kind == .plan ? Theme.Icon.undo : Theme.Icon.close).font(Theme.Font.bodyStrong)
                .frame(width: Theme.Watch.minRowHeight, height: Theme.Watch.minRowHeight)
                .background(Theme.Watch.ringTrack, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(declineTitle)
    }

    private func decline() { resolve(WatchQuickAnswer.negativeResolution(for: kind)) }

    private var declineTitle: String {
        kind == .plan ? String(localized: "Revise [Watch Plan]") : String(localized: "Deny")
    }
    private var confirmTitle: String {
        kind == .plan ? String(localized: "Approve") : String(localized: "Allow [Notification Actions ce7ef2]")
    }
    private var hint: String {
        kind == .plan ? String(localized: "Hold to approve [Watch Dashboard]") : String(localized: "Hold to allow [Watch Dashboard]")
    }
}

extension View {
    /// Text that scrolls above a pinned control fades out at its lower edge instead of being cut mid-line.
    func watchBottomFade() -> some View {
        mask {
            VStack(spacing: Theme.Space.flush) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Theme.Watch.fadeHeight)
            }
        }
    }
}
