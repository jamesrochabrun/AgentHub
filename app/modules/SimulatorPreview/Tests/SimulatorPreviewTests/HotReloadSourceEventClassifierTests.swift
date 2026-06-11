import Testing

@testable import SimulatorPreview

@Suite("HotReloadSourceEventClassifier")
struct HotReloadSourceEventClassifierTests {

  @Test("edit to a known file is injectable")
  func knownEdit() {
    var classifier = HotReloadSourceEventClassifier(
      knownSources: ["/p/App/HomeView.swift"])
    let change = classifier.classify(
      path: "/p/App/HomeView.swift", fileExists: { _ in true })
    #expect(change == .injectable(path: "/p/App/HomeView.swift"))
  }

  @Test("atomic-save rename of a known file is still injectable")
  func atomicSave() {
    // Editors save via temp-file + rename; the path exists and was known,
    // so FSEvents "renamed" flags must not be treated as structural.
    var classifier = HotReloadSourceEventClassifier(
      knownSources: ["/p/App/HomeView.swift"])
    let change = classifier.classify(
      path: "/p/App/HomeView.swift", fileExists: { _ in true })
    #expect(change == .injectable(path: "/p/App/HomeView.swift"))
  }

  @Test("new file is structural and joins the known set")
  func newFile() {
    var classifier = HotReloadSourceEventClassifier(knownSources: [])
    let first = classifier.classify(
      path: "/p/App/NewView.swift", fileExists: { _ in true })
    #expect(first == .structural(path: "/p/App/NewView.swift", kind: .created))

    // Subsequent edits to it are injectable… in principle. (After the
    // rebuild relaunch the watcher restarts with a fresh snapshot anyway.)
    let second = classifier.classify(
      path: "/p/App/NewView.swift", fileExists: { _ in true })
    #expect(second == .injectable(path: "/p/App/NewView.swift"))
  }

  @Test("deleted file is structural and leaves the known set")
  func deletedFile() {
    var classifier = HotReloadSourceEventClassifier(
      knownSources: ["/p/App/OldView.swift"])
    let change = classifier.classify(
      path: "/p/App/OldView.swift", fileExists: { _ in false })
    #expect(change == .structural(path: "/p/App/OldView.swift", kind: .deleted))

    // A second event for the already-forgotten path is transient noise.
    let again = classifier.classify(
      path: "/p/App/OldView.swift", fileExists: { _ in false })
    #expect(again == nil)
  }

  @Test("non-Swift files and excluded directories are ignored")
  func ignored() {
    var classifier = HotReloadSourceEventClassifier(knownSources: [])
    #expect(classifier.classify(
      path: "/p/App/README.md", fileExists: { _ in true }) == nil)
    #expect(classifier.classify(
      path: "/p/.git/objects/tmp.swift", fileExists: { _ in true }) == nil)
    #expect(classifier.classify(
      path: "/p/DerivedData/X/foo.swift", fileExists: { _ in true }) == nil)
    #expect(classifier.classify(
      path: "/p/.build/checkouts/dep/foo.swift", fileExists: { _ in true }) == nil)
    #expect(classifier.classify(
      path: "/p/Pods/Lib/foo.swift", fileExists: { _ in true }) == nil)
  }
}
