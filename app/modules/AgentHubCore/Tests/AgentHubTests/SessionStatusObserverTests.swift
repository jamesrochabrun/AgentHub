import Observation
import Testing
@testable import AgentHubCore

@MainActor
@Observable
private final class ObservableSessionStatusBox {
  var status: SessionStatus?
}

@MainActor
struct SessionStatusObserverTests {
  @Test
  func emitsInitialAndChangedStatusesWithoutPolling() async {
    let box = ObservableSessionStatusBox()
    box.status = .idle
    let observer = SessionStatusObserver { box.status }
    let stream = observer.statusStream()
    var iterator = stream.makeAsyncIterator()

    #expect(await iterator.next() == .idle)

    box.status = .thinking

    #expect(await iterator.next() == .thinking)
  }

  @Test
  func streamRetainsObserverForItsObservationLifetime() async {
    let box = ObservableSessionStatusBox()
    box.status = .idle
    let stream = SessionStatusObserver { box.status }.statusStream()
    var iterator = stream.makeAsyncIterator()

    #expect(await iterator.next() == .idle)

    box.status = .waitingForUser

    #expect(await iterator.next() == .waitingForUser)
  }
}
