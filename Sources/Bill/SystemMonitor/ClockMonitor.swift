import AppKit
import Foundation

/// Fires exactly on the wall-clock half hours (:00 and :30), and again
/// whenever the part of the day changes.
///
/// Aligned rather than periodic: a plain `Timer(timeInterval: 1800, repeats:)`
/// drifts away from the clock the moment the machine sleeps, so this computes
/// the next real boundary with `Calendar` and arms a single non-repeating
/// timer for it, re-arming on each fire. That is 48 wakeups a day, and every
/// one lands on an actual half hour.
///
/// Re-arms on wake and on system clock changes, both of which otherwise leave
/// the pending timer pointing at a moment that has already passed (or is now
/// hours away).
@MainActor
final class ClockMonitor {
    /// `(hour, minute)` of the boundary that just passed.
    var onHalfHour: ((Int, Int) -> Void)?
    var onTimeOfDayChanged: ((TimeOfDay) -> Void)?

    private var timer: Timer?
    private var lastTimeOfDay: TimeOfDay?
    private var observers: [NSObjectProtocol] = []

    func start() {
        stop()
        lastTimeOfDay = TimeOfDay.bucket(for: Date())

        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Deliberately `NSWorkspace.shared.notificationCenter`, not
            // `NotificationCenter.default` — sleep/wake notifications are only
            // delivered on the workspace centre, and registering on the
            // default centre is a classic silently-never-fires bug.
            Task { @MainActor in self?.arm() }
        }
        let clockChange = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.arm() }
        }
        observers = [wake, clockChange]

        arm()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func arm() {
        timer?.invalidate()
        let now = Date()
        guard let next = Self.nextBoundary(after: now) else { return }
        let delay = max(1, next.timeIntervalSince(now))
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire() }
        }
        // `.common` so an open menu doesn't delay the chime.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire() {
        defer { arm() }
        let now = Date()
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        guard let hour = components.hour, let minute = components.minute else { return }
        // Snap to the boundary: the timer can fire a fraction late and land on
        // :29 or :59, which would produce a nonsense key like `clock.1129`.
        let snapped = minute >= 30 ? 30 : 0
        let snappedHour = (minute >= 55) ? (hour + 1) % 24 : hour
        onHalfHour?(snappedHour, minute >= 55 ? 0 : snapped)

        let bucket = TimeOfDay.bucket(for: now)
        if bucket != lastTimeOfDay {
            lastTimeOfDay = bucket
            onTimeOfDayChanged?(bucket)
        }
    }

    /// The next :00 or :30 strictly after `date`.
    static func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        let minute = calendar.component(.minute, from: date)
        let targetMinute = minute < 30 ? 30 : 0
        var components = DateComponents()
        components.minute = targetMinute
        components.second = 0
        // `.nextTime` with a minute-only match walks forward to the next
        // occurrence, rolling the hour automatically when target is 0.
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            direction: .forward
        )
    }
}
