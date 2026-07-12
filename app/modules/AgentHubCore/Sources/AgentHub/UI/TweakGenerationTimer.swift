import Foundation

struct TweakGenerationTimer: Equatable {
  private(set) var startedAt: Date?

  mutating func start(at date: Date = .now) {
    startedAt = date
  }

  mutating func stop() {
    startedAt = nil
  }
}
