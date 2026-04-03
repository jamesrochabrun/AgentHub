//
//  WorktreeSuccessSoundService.swift
//  AgentHub
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

public protocol WorktreeSuccessSoundServiceProtocol: Sendable {
  func playWorktreeCreatedSound() async
}

public actor WorktreeSuccessSoundService: WorktreeSuccessSoundServiceProtocol {
  typealias SoundPlayer = @MainActor @Sendable () -> Void

  private let soundPlayer: SoundPlayer

  init(
    soundPlayer: SoundPlayer? = nil
  ) {
    self.soundPlayer = soundPlayer ?? {
      #if canImport(AppKit)
      if let sound = NSSound(named: "Glass") {
        sound.play()
      } else {
        NSSound.beep()
      }
      #endif
    }
  }

  public func playWorktreeCreatedSound() async {
    await MainActor.run {
      soundPlayer()
    }
  }
}
