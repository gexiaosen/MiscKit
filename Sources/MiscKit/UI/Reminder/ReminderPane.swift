import MiscKitCore
import SwiftUI

/// 提醒工作区：面板内看今日进度与倒计时，顺手开关计划；细粒度设置留给设置页。
struct ReminderPane: View {
    static let contentHeight: CGFloat = 262

    @State private var center = ReminderCenter.shared
    @State private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        let _ = appLanguage
        VStack(alignment: .leading, spacing: Layout.Spacing.m) {
            header
            ForEach(ReminderKind.allCases) { kind in
                planCard(kind)
            }
            statFooter
        }
        .padding(.horizontal, Layout.Spacing.l)
        .padding(.top, Layout.Spacing.s)
        .padding(.bottom, Layout.Spacing.m)
        .frame(height: Self.contentHeight, alignment: .top)
    }

    // MARK: 顶部状态

    private var header: some View {
        HStack(alignment: .top, spacing: Layout.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textBody)
            }
            Spacer(minLength: Layout.Spacing.m)
            Button(L10n.Common.openSettings) { SettingsRoute.shared.open(.reminders) }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
        }
    }

    private var headerTitle: String {
        let anyEnabled = ReminderKind.allCases.contains { settings.plan(for: $0).enabled }
        return anyEnabled ? L10n.Reminder.activeHeader : L10n.Reminder.pausedHeader
    }

    private var detail: String {
        let enabled = ReminderKind.allCases.filter { settings.plan(for: $0).enabled }
        guard !enabled.isEmpty else { return L10n.Reminder.bothDisabled }
        let window = settings.plan(for: enabled[0])
        let base = L10n.Reminder.detailWindow(
            enabled.map(\.label).joined(separator: L10n.Reminder.joinAnd),
            window.windowStart.display,
            window.windowEnd.display
        )
        return base + (window.skipWeekends ? L10n.Reminder.skipWeekendsTag : "")
    }

    // MARK: 单个计划卡

    private func planCard(_ kind: ReminderKind) -> some View {
        let plan = settings.plan(for: kind)
        let remaining = center.remainingSeconds[kind]
        return HStack(spacing: Layout.Spacing.m) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15))
                .foregroundStyle(plan.enabled ? Theme.accent : Theme.decorationOnly)
                .frame(width: Layout.Metric.tile, height: Layout.Metric.tile)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.label)
                    .font(.system(size: 13, weight: .medium))
                Text(cardSubtitle(kind: kind, plan: plan, remaining: remaining))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textBody)
            }
            Spacer(minLength: Layout.Spacing.m)
            if plan.enabled {
                Button(L10n.Reminder.completeOnce) { center.markCompleted(kind) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
                    .disabled(center.remainingSeconds[kind] == nil)
                Button(L10n.Reminder.snoozeButton) { center.markSnoozed(kind) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(center.remainingSeconds[kind] == nil)
            }
            Toggle("", isOn: Binding(
                get: { plan.enabled },
                set: { enabled in updatePlan(kind, enabled: enabled) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.horizontal, Layout.Spacing.m)
        .frame(height: 64)
        // 玻璃上纯白卡片底等于没画，previewFill + 发丝边才分得出两块卡
        .background(Theme.previewFill,
                    in: RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius,
                                         style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Layout.Metric.innerCornerRadius, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    /// `remaining` 非 nil 就是「排上了」，同时它每秒被中枢重写一次，是这张卡的刷新心跳。
    private func cardSubtitle(kind: ReminderKind, plan: ReminderPlan, remaining: Int?) -> String {
        let today = center.todayCount(kind)
        let progress = L10n.Reminder.todayCount(today)
        guard plan.enabled else { return L10n.Reminder.off(progress) }
        guard remaining != nil, let next = center.nextFireDates[kind] else {
            return L10n.Reminder.outsideWindow(progress)
        }
        return "\(progress) · \(ReminderDisplay.phrase(now: Date(), next: next))"
    }

    private func updatePlan(_ kind: ReminderKind, enabled: Bool) {
        var plan = settings.plan(for: kind)
        plan.enabled = enabled
        settings.setPlan(plan)
        NotificationCenter.default.post(name: .misckitReminderSettingsChanged, object: nil)
    }

    // MARK: 底部统计

    private var statFooter: some View {
        HStack(alignment: .top, spacing: Layout.Spacing.l) {
            ForEach(ReminderKind.allCases) { kind in
                statStrip(kind)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 42, alignment: .top)
        .padding(.top, Layout.Spacing.xs)
    }

    private func statStrip(_ kind: ReminderKind) -> some View {
        let plan = settings.plan(for: kind)
        let counts = center.dailyCounts(kind, days: 7)
        let targets = counts.map { ReminderTarget.perDay(plan: plan, day: $0.day) }
        let expected = counts.map {
            ReminderTarget.expectedSoFar(plan: plan, day: $0.day, now: Date())
        }
        let total = counts.reduce(0) { $0 + $1.count }
        let targetTotal = targets.reduce(0, +)
        let title = targetTotal > 0 ? "\(kind.label) \(total)/\(targetTotal)" : L10n.Reminder.countSuffix(kind.label, total)
        let hue = Theme.reminderHue(for: kind, scheme: scheme)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(Type.micro)
                    .foregroundStyle(Theme.textBody)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(L10n.Reminder.sevenDays)
                    .font(Type.micro)
                    .foregroundStyle(Theme.decorationOnly)
            }
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(counts.enumerated()), id: \.offset) { index, entry in
                    let full = max(1, targets[index])
                    let height = entry.count == 0
                        ? 0
                        : min(20, max(2, 20 * CGFloat(entry.count) / CGFloat(full)))
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(entry.count == 0 ? Color.clear : hue.top.opacity(0.82))
                            .frame(width: 8, height: height)
                        if targets[index] > 0, expected[index] > 0 {
                            DashedTargetLine()
                                .stroke(Theme.textBody.opacity(0.35),
                                        style: StrokeStyle(lineWidth: 0.5, dash: [1.5, 1.5]))
                                .frame(width: 8, height: 1)
                                .offset(y: -min(19, 20 * CGFloat(expected[index]) / CGFloat(full)))
                        }
                    }
                    .frame(width: 8, height: 20, alignment: .bottom)
                }
            }
            .frame(height: 20, alignment: .bottom)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 74, height: 0.5)
                    .offset(y: 1)
            }
        }
        .frame(width: 140, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Reminder.statA11y(kind.label, total, targetTotal))
    }
}

private struct DashedTargetLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
