//
//  WorktreeSuccessSoundService.swift
//  AgentHub
//

import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AppKit)
import AppKit
#endif

public protocol WorktreeSuccessSoundServiceProtocol: Sendable {
  func playWorktreeCreatedSound() async
}

protocol WorktreeSuccessAudioPlayer: AnyObject, Sendable {
  var duration: TimeInterval { get }
  func prepareToPlay() -> Bool
  func play() -> Bool
}

#if canImport(AVFoundation)
final class AVAudioPlayerAdapter: WorktreeSuccessAudioPlayer, @unchecked Sendable {
  private let player: AVAudioPlayer

  init(url: URL) throws {
    self.player = try AVAudioPlayer(contentsOf: url)
  }

  var duration: TimeInterval {
    player.duration
  }

  func prepareToPlay() -> Bool {
    player.prepareToPlay()
  }

  func play() -> Bool {
    player.play()
  }
}
#endif

public actor WorktreeSuccessSoundService: WorktreeSuccessSoundServiceProtocol {
  typealias PlayerFactory = @Sendable (URL) throws -> any WorktreeSuccessAudioPlayer
  typealias ResourceLocator = @Sendable () -> URL?
  typealias FallbackPlayer = @MainActor @Sendable () -> Void

  private let playerFactory: PlayerFactory
  private let resourceLocator: ResourceLocator
  private let fallbackPlayer: FallbackPlayer
  private var activePlayers: [UUID: any WorktreeSuccessAudioPlayer] = [:]

  init(
    playerFactory: PlayerFactory? = nil,
    resourceLocator: ResourceLocator? = nil,
    fallbackPlayer: FallbackPlayer? = nil
  ) {
    self.playerFactory = playerFactory ?? { url in
      try WorktreeSuccessSoundService.makeDefaultPlayer(url: url)
    }
    self.resourceLocator = resourceLocator ?? {
      WorktreeSuccessSoundService.defaultResourceURL()
    }
    self.fallbackPlayer = fallbackPlayer ?? {
      #if canImport(AppKit)
      NSSound.beep()
      #endif
    }
  }

  public func playWorktreeCreatedSound() async {
    guard let soundURL = resourceLocator() else {
      await playFallback()
      return
    }

    do {
      let player = try playerFactory(soundURL)
      _ = player.prepareToPlay()

      guard player.play() else {
        await playFallback()
        return
      }

      let playerID = UUID()
      activePlayers[playerID] = player
      let cleanupDelay = max(player.duration, 0.75) + 0.15
      let cleanupNanoseconds = UInt64(cleanupDelay * 1_000_000_000)

      Task { [cleanupNanoseconds] in
        try? await Task.sleep(nanoseconds: cleanupNanoseconds)
        self.releasePlayer(id: playerID)
      }
    } catch {
      await playFallback()
    }
  }

  private func releasePlayer(id: UUID) {
    activePlayers.removeValue(forKey: id)
  }

  private func playFallback() async {
    await MainActor.run {
      fallbackPlayer()
    }
  }

  private static func defaultResourceURL() -> URL? {
    Bundle.module.url(forResource: "worktree-success", withExtension: "wav", subdirectory: "Sounds")
      ?? Bundle.module.url(forResource: "worktree-success", withExtension: "wav")
  }

  private static func makeDefaultPlayer(url: URL) throws -> any WorktreeSuccessAudioPlayer {
    #if canImport(AVFoundation)
    return try AVAudioPlayerAdapter(url: url)
    #else
    throw NSError(
      domain: "WorktreeSuccessSoundService",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "AVFoundation is unavailable on this platform"]
    )
    #endif
  }
}
