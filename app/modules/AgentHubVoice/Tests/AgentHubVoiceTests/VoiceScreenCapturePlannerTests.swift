import CoreGraphics
import Testing
@testable import AgentHubVoice

struct VoiceScreenCapturePlannerTests {
  private struct Display: Equatable {
    let id: Int
    let isMain: Bool
  }

  @Test
  func ordersMainDisplayFirstAndPreservesExternalOrder() {
    let displays = [
      Display(id: 10, isMain: false),
      Display(id: 20, isMain: true),
      Display(id: 30, isMain: false),
    ]

    let ordered = VoiceScreenCapturePlanner.orderMainFirst(displays) {
      $0.isMain
    }

    #expect(ordered.map(\.id) == [20, 10, 30])
  }

  @Test
  func selectionDefaultsToMainAndRejectsOutOfRangeIndexes() {
    #expect(
      VoiceScreenCapturePlanner.selectionIndex(requested: nil, displayCount: 2) == 1
    )
    #expect(
      VoiceScreenCapturePlanner.selectionIndex(requested: 2, displayCount: 2) == 2
    )
    #expect(
      VoiceScreenCapturePlanner.selectionIndex(requested: 3, displayCount: 2) == nil
    )
    #expect(
      VoiceScreenCapturePlanner.selectionIndex(requested: 0, displayCount: 2) == nil
    )
    #expect(
      VoiceScreenCapturePlanner.selectionIndex(requested: nil, displayCount: 0) == nil
    )
  }

  @Test
  func clampsRegionsToDisplayBounds() {
    let clamped = VoiceScreenCapturePlanner.clampedRegion(
      VoiceCaptureRegion(x: -100, y: 500, width: 400, height: 2_000),
      displayWidth: 1_512,
      displayHeight: 982
    )

    #expect(clamped == CGRect(x: 0, y: 500, width: 300, height: 482))
  }

  @Test
  func rejectsRegionsOutsideTheDisplay() {
    #expect(
      VoiceScreenCapturePlanner.clampedRegion(
        VoiceCaptureRegion(x: 2_000, y: 0, width: 100, height: 100),
        displayWidth: 1_512,
        displayHeight: 982
      ) == nil
    )
    #expect(
      VoiceScreenCapturePlanner.clampedRegion(
        VoiceCaptureRegion(x: 0, y: 0, width: 0.4, height: 100),
        displayWidth: 1_512,
        displayHeight: 982
      ) == nil
    )
  }
}
