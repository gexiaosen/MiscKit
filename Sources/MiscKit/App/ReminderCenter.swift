import AppKit
import CoreGraphics
import MiscKitCore
import Observation

/// 提醒的运行时中枢：唯一持有"下一次触发"的地方。
///
/// 调度用单触发器按秒对齐：睡眠错过的时刻在唤醒后只重算，不补发一串。
/// 到点先过不打扰判定，再弹屏幕中央的浮层（`ReminderOverlayController`）。
@MainActor
@Observable
final class ReminderCenter {
    static let shared = ReminderCenter()

    private let settings = AppSettings.shared
    private let log = ReminderLogStore.shared
    private let calendar = Calendar.current

    /// 每个种类当前排定的触发时刻；nil 表示该计划未启用或时段无效。
    private(set) var nextFireDates: [ReminderKind: Date] = [:]
    private(set) var remainingSeconds: [ReminderKind: Int] = [:]
    private var timer: Timer?
    private var observers: [any NSObjectProtocol] = []
    private var lastPublishedCountdown: String?

    /// 菜单栏标题的唯一取数入口：由 AppDelegate 挂上，避免两处各起一个计时器。
    var onDisplayChanged: (() -> Void)?

    /// 上一次见过的计划快照：字段没动的 kind 不改它的排程，
    /// 动了的从「此刻」重计——把已排好的未来时刻再喂给调度器会每次往后滑一个间隔。
    private var planSnapshots: [ReminderKind: ReminderPlan] = [:]

    /// 菜单栏倒计时的取数口：优先显示更早到期的那个计划，且只到分钟。
    var countdownText: String? {
        let now = Date()
        var nearest: Date?
        for kind in ReminderKind.allCases {
            guard let next = nextFireDates[kind] else { continue }
            if nearest == nil || next < nearest! { nearest = next }
        }
        guard let nearest else { return nil }
        return ReminderDisplay.menuBarValue(now: now, next: nearest, calendar: calendar)
    }

    /// 看的是**生效**计划而不是已写盘的字典：没动过设置时 reminderPlans 是空的，
    /// 但两种默认计划照样在跑。
    /// 「功能」页整件关掉时这一样为假 —— 菜单栏倒计时和到点浮层都读它，断一处就全断。
    var isCountdownVisible: Bool {
        settings.reminderCountdownInMenuBar
            && settings.isEnabled(.reminder)
            && ReminderKind.allCases.contains { settings.plan(for: $0).enabled }
    }

    // MARK: 生命周期

    func start() {
        rescheduleAll()
        // 1 秒对齐：既要按时弹，也要让面板卡的秒级倒计时走得动。
        // 菜单栏只到分钟，`updateRemaining` 比出文字变化才会重绘。
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        #if DEBUG
        // 验收用：立刻弹一次屏幕提醒，不用等一个真实间隔。
        if ProcessInfo.processInfo.environment["MISCKIT_DEBUG_POST_REMINDER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.presentReminder(.water)
            }
        }
        #endif

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // 睡眠期间错过的时刻全部作废，从醒来这一刻重新算
                self?.rescheduleAll(treatOverdueAsNow: true)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .misckitReminderSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rescheduleAll() }
        })
        observeFeatureSwitch()
    }

    /// 「功能」页整件关掉不改任何计划字段，所以那条广播不会发；这里自己盯开关本身。
    private func observeFeatureSwitch() {
        withObservationTracking {
            _ = settings.disabledTools
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // 重新打开从此刻起算：沿用关掉前排的那些时刻，等于把错过的点一次性补弹
                self.rescheduleAll(treatOverdueAsNow: true)
                self.observeFeatureSwitch()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: 调度

    /// `treatOverdueAsNow` 为真时（唤醒后）把过期的基准挪到当前时刻，避免补发一整串。
    private func rescheduleAll(treatOverdueAsNow: Bool = false) {
        let now = Date()
        for kind in ReminderKind.allCases {
            let plan = settings.plan(for: kind)
            // 唤醒 = 「计划没变但睡眠错过了」，用 nil 快照强制从此刻重计
            let previous = treatOverdueAsNow ? nil : planSnapshots[kind]
            planSnapshots[kind] = plan
            guard settings.isEnabled(.reminder) else {
                // 整件功能关掉：不排下一次，tick 自然到不了点，浮层也就不会弹
                nextFireDates[kind] = nil
                continue
            }
            nextFireDates[kind] = ReminderScheduler.rescheduled(now: now, previous: previous,
                                                                current: plan,
                                                                existing: nextFireDates[kind],
                                                                calendar: calendar)
        }
        updateRemaining(now: now)
    }

    private func tick() {
        let now = Date()
        for kind in ReminderKind.allCases {
            guard let scheduled = nextFireDates[kind] else { continue }
            // 时钟被手动改过、或系统睡过一觉：落后超过 90 秒就重算而不是补弹。
            if now.timeIntervalSince(scheduled) > 90 {
                nextFireDates[kind] = ReminderScheduler.nextFire(now: now, lastDue: now,
                                                                plan: settings.plan(for: kind),
                                                                calendar: calendar)
                continue
            }
            if now >= scheduled {
                deliver(kind: kind, at: now)
            }
        }
        updateRemaining(now: now)
    }

    private func updateRemaining(now: Date) {
        for kind in ReminderKind.allCases {
            remainingSeconds[kind] = ReminderScheduler.remaining(now: now, next: nextFireDates[kind])
        }
        let text = countdownText
        if text != lastPublishedCountdown {
            lastPublishedCountdown = text
            onDisplayChanged?()
        }
    }

    /// 到点：先判打扰，再弹。被抑制时静默顺延，不记完成也不记稍后。
    private func deliver(kind: ReminderKind, at now: Date) {
        let plan = settings.plan(for: kind)
        let next = ReminderScheduler.nextFire(now: now, lastDue: now, plan: plan, calendar: calendar)
        nextFireDates[kind] = next

        let context = Self.currentContext(now: now, settings: settings, calendar: calendar)
        guard !ReminderSuppression.isSuppressed(at: now, context: context,
                                                blacklist: settings.reminderSuppressionBlacklist,
                                                calendar: calendar) else { return }
        // 锁屏 / 显示器睡眠时浮层叫不出来，这次直接跳过（和睡眠错过不补发一致）
        guard Self.screenCanShowReminder else { return }
        presentReminder(kind)
    }

    private func presentReminder(_ kind: ReminderKind) {
        let plan = settings.plan(for: kind)
        ReminderOverlayController.shared.show(
            kind: kind,
            snoozeMinutes: plan.snoozeMinutes,
            onComplete: { [weak self] in self?.markCompleted(kind) },
            onSnooze: { [weak self] in self?.markSnoozed(kind) }
        )
    }

    /// 屏幕睡着、锁屏时窗口不会出现在用户眼前；此时跳过这次，不补发。
    private static var screenCanShowReminder: Bool {
        guard !NSScreen.screens.isEmpty else { return false }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           session["CGSSessionScreenIsLocked"] as? Bool == true {
            return false
        }
        return true
    }

    // MARK: 用户处置

    /// 完成：重置到下一个整间隔，并记一次完成。
    func markCompleted(_ kind: ReminderKind) {
        let now = Date()
        log.record(ReminderRecord(kind: kind, date: now, outcome: .completed))
        nextFireDates[kind] = ReminderScheduler.nextFire(now: now, lastDue: now,
                                                        plan: settings.plan(for: kind),
                                                        calendar: calendar)
        updateRemaining(now: now)
    }

    /// 稍后：只顺延 snooze 时长，不计入完成次数。
    func markSnoozed(_ kind: ReminderKind) {
        let now = Date()
        let plan = settings.plan(for: kind)
        log.record(ReminderRecord(kind: kind, date: now, outcome: .snoozed))
        nextFireDates[kind] = ReminderScheduler.snoozed(from: now, plan: plan, calendar: calendar)
        updateRemaining(now: now)
    }

    func todayCount(_ kind: ReminderKind) -> Int {
        log.count(kind: kind, on: Date())
    }

    func dailyCounts(_ kind: ReminderKind, days: Int) -> [(day: Date, count: Int)] {
        log.dailyCounts(kind: kind, days: days, now: Date())
    }

    // MARK: 打扰上下文采集

    private static func currentContext(now: Date, settings: AppSettings,
                                       calendar: Calendar) -> ReminderContext {
        let front = NSWorkspace.shared.frontmostApplication
        return ReminderContext(
            frontmostBundleID: front?.bundleIdentifier,
            hasFullscreenWindow: hasFullscreenWindow(ownerPID: front?.processIdentifier),
            focusWindows: settings.reminderFocusWindows.filter(\.isValid).map(\.range))
    }

    /// 前台 App 是否有一个铺满整块屏幕的普通层窗口。只读窗口几何，不需要屏幕录制权限。
    private static func hasFullscreenWindow(ownerPID: pid_t?) -> Bool {
        guard let ownerPID,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        let frames = NSScreen.screens.map(\.frame)
        for window in list {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == ownerPID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { continue }
            // CGRect 也满足 contains(_:)，必须写 where: 才不会被解析成元素相等判断
            let covers = frames.contains(where: { screen in
                width >= screen.width * 0.98 && height >= screen.height * 0.98
            })
            if covers { return true }
        }
        return false
    }
}

extension Notification.Name {
    /// 设置页改过计划后广播，让中枢立刻重排而不是等下一次对齐。
    static let misckitReminderSettingsChanged = Notification.Name("app.misckit.reminderSettingsChanged")
}
