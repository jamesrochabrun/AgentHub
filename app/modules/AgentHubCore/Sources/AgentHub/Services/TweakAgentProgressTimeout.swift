import Foundation

struct TweakAgentProgressTimeout<Activity: Equatable> {
  private let interval: Duration
  private var lastActivity: Activity
  private var lastProgressAt: ContinuousClock.Instant

  init(
    interval: Duration,
    initialActivity: Activity,
    now: ContinuousClock.Instant = .now
  ) {
    self.interval = interval
    self.lastActivity = initialActivity
    self.lastProgressAt = now
  }

  mutating func hasTimedOut(
    activity: Activity,
    now: ContinuousClock.Instant = .now
  ) -> Bool {
    if activity != lastActivity {
      lastActivity = activity
      lastProgressAt = now
      return false
    }

    return lastProgressAt.duration(to: now) >= interval
  }
}
