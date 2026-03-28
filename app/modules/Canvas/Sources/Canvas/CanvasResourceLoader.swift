import Foundation

enum CanvasResourceLoader {
  static func base64EncodedResource(named name: String) -> String {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil),
          let data = try? Data(contentsOf: url) else {
      return ""
    }

    return data.base64EncodedString()
  }
}
