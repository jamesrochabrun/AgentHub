import Foundation

/// A tweakable value on a design canvas.
public enum StudioTweakValue: Equatable, Sendable, Codable {
  case number(Double)
  case string(String)
  case boolean(Bool)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let bool = try? container.decode(Bool.self) {
      self = .boolean(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .boolean(let value): try container.encode(value)
    }
  }

  /// The JSON-compatible value, for the `dc_set_props` schema the host page declares.
  public var jsonValue: Any {
    switch self {
    case .number(let value): return value
    case .string(let value): return value
    case .boolean(let value): return value
    }
  }
}

/// One control in a canvas's shared tweak schema.
///
/// The schema is **per canvas, not per variant**: the point of a canvas is
/// comparing variants under the same knobs. Every prop is exposed to every
/// artboard as the CSS custom property `--{name}`; variants read it with
/// `var(--name)`. `text` and `select` values are additionally written into any
/// element carrying `data-prop="{name}"`, so copy can be tweaked without JS.
///
/// The shape mirrors the `dc_set_props` declaration the Tweaks panel already
/// understands (`type`, `label`, `value`, `min`/`max`/`step`, `options`), plus
/// `unit` for sliders whose CSS value needs one (`px`, `rem`, `%`, `ms`).
public struct StudioTweakProp: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case slider, select, color, toggle, text
  }

  public let name: String
  public let label: String
  public let type: Kind
  public var value: StudioTweakValue
  public let minimum: Double?
  public let maximum: Double?
  public let step: Double?
  public let options: [String]
  public let unit: String?

  public var id: String { name }

  public init(
    name: String,
    label: String? = nil,
    type: Kind,
    value: StudioTweakValue,
    minimum: Double? = nil,
    maximum: Double? = nil,
    step: Double? = nil,
    options: [String] = [],
    unit: String? = nil
  ) {
    self.name = name
    self.label = label.flatMap { $0.isEmpty ? nil : $0 } ?? name
    self.type = type
    self.value = value
    self.minimum = minimum
    self.maximum = maximum
    self.step = step
    self.options = options
    self.unit = unit
  }

  /// The CSS custom property this prop drives.
  public var cssVariableName: String { "--\(name)" }

  /// The CSS token for a value of this prop's type: sliders carry their unit,
  /// toggles become `1`/`0` (usable in `calc()` and `opacity`), everything
  /// else is injected raw so keyword values (`600`, `center`, `#0a84ff`) work.
  public func cssValue(for value: StudioTweakValue) -> String {
    switch (type, value) {
    case (.slider, .number(let number)):
      let text = number == number.rounded() && abs(number) < 1e15
        ? String(Int(number))
        : String(number)
      return text + (unit ?? "")
    case (.toggle, .boolean(let flag)):
      return flag ? "1" : "0"
    case (_, .number(let number)):
      return number == number.rounded() ? String(Int(number)) : String(number)
    case (_, .boolean(let flag)):
      return flag ? "1" : "0"
    case (_, .string(let string)):
      return string
    }
  }

  public var cssValue: String { cssValue(for: value) }

  /// The prop with a new value, keeping everything else.
  public func withValue(_ newValue: StudioTweakValue) -> StudioTweakProp {
    var copy = self
    copy.value = newValue
    return copy
  }

  /// The `dc_set_props` declaration for this prop, for the host page.
  public var declaration: [String: Any] {
    var object: [String: Any] = [
      "type": type.rawValue,
      "label": label,
      "value": value.jsonValue,
    ]
    if let minimum { object["min"] = minimum }
    if let maximum { object["max"] = maximum }
    if let step { object["step"] = step }
    if !options.isEmpty { object["options"] = options }
    if let unit { object["unit"] = unit }
    return object
  }
}

/// Validates the `props` argument of `agenthub_design` at the tool boundary.
public enum StudioTweakPropParser {
  public struct ValidationError: Error, Equatable, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
  }

  public static let maxProps = 24
  private static let namePattern = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_-]{0,39}$")

  /// `raw` is the JSON object the agent passed: `{ name: { type, value, … } }`.
  /// Declaration order is preserved when the host serializes an ordered array;
  /// a dictionary loses it, so an array of `{ name, … }` objects is accepted too.
  public static func parse(_ raw: Any?) throws -> [StudioTweakProp] {
    guard let raw, !(raw is NSNull) else { return [] }

    var entries: [(String, [String: Any])] = []
    if let array = raw as? [[String: Any]] {
      for object in array {
        guard let name = object["name"] as? String else {
          throw ValidationError("Every props entry needs a name.")
        }
        entries.append((name, object))
      }
    } else if let object = raw as? [String: Any] {
      // Dictionaries are unordered; sort by name for a stable panel order.
      entries = object.keys.sorted().compactMap { key in
        (object[key] as? [String: Any]).map { (key, $0) }
      }
      if entries.count != object.count {
        throw ValidationError("Every props entry must be an object like { type, value }.")
      }
    } else {
      throw ValidationError("props must be an object keyed by prop name, or an array of { name, type, value, … } objects.")
    }

    guard entries.count <= maxProps else {
      throw ValidationError("props has \(entries.count) entries but the limit is \(maxProps).")
    }

    var seen: Set<String> = []
    return try entries.map { name, declaration in
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard namePattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil else {
        throw ValidationError("Prop name \"\(name)\" must be a CSS-identifier-safe name (letters, digits, - and _; starts with a letter or _; ≤40 chars).")
      }
      guard seen.insert(trimmed).inserted else {
        throw ValidationError("Prop \"\(trimmed)\" is declared more than once.")
      }
      guard let typeString = declaration["type"] as? String,
            let type = StudioTweakProp.Kind(rawValue: typeString.lowercased())
      else {
        let supported = StudioTweakProp.Kind.allCases.map(\.rawValue).joined(separator: ", ")
        throw ValidationError("Prop \"\(trimmed)\" needs a type: one of \(supported).")
      }

      let label = declaration["label"] as? String
      let unit = (declaration["unit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      let options = (declaration["options"] as? [Any])?.compactMap { $0 as? String } ?? []
      let minimum = (declaration["min"] as? NSNumber)?.doubleValue
      let maximum = (declaration["max"] as? NSNumber)?.doubleValue
      let step = (declaration["step"] as? NSNumber)?.doubleValue

      let value: StudioTweakValue
      switch type {
      case .slider:
        guard let number = numberValue(declaration["value"]) else {
          throw ValidationError("Slider prop \"\(trimmed)\" needs a numeric value.")
        }
        if let minimum, let maximum, minimum > maximum {
          throw ValidationError("Slider prop \"\(trimmed)\" has min greater than max.")
        }
        if let minimum, number < minimum { throw ValidationError("Slider prop \"\(trimmed)\" value is below its min.") }
        if let maximum, number > maximum { throw ValidationError("Slider prop \"\(trimmed)\" value is above its max.") }
        value = .number(number)
      case .toggle:
        guard let flag = boolValue(declaration["value"]) else {
          throw ValidationError("Toggle prop \"\(trimmed)\" needs a boolean value.")
        }
        value = .boolean(flag)
      case .select:
        guard !options.isEmpty else {
          throw ValidationError("Select prop \"\(trimmed)\" needs a non-empty options array.")
        }
        guard let string = declaration["value"] as? String, options.contains(string) else {
          throw ValidationError("Select prop \"\(trimmed)\" value must be one of its options.")
        }
        value = .string(string)
      case .color, .text:
        guard let string = declaration["value"] as? String else {
          throw ValidationError("\(type == .color ? "Color" : "Text") prop \"\(trimmed)\" needs a string value.")
        }
        value = .string(string)
      }

      return StudioTweakProp(
        name: trimmed,
        label: label,
        type: type,
        value: value,
        minimum: type == .slider ? minimum : nil,
        maximum: type == .slider ? maximum : nil,
        step: type == .slider ? step : nil,
        options: type == .select ? options : [],
        unit: type == .slider ? unit : nil
      )
    }
  }

  /// JSON `true`/`false` arrive as `NSNumber` too; `is Bool` is true for any
  /// 0/1 NSNumber under bridging, so ask CoreFoundation which it really is.
  private static func isBooleanNumber(_ raw: Any?) -> Bool {
    guard let number = raw as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  /// Props no variant references — neither `--<name>` in its CSS/markup nor a
  /// `data-prop="<name>"` element. A control that moves nothing is exactly the
  /// bug a user reports as "tweaks don't work", so the tool rejects it.
  public static func unusedProps(_ props: [StudioTweakProp], variants: [StudioVariant]) -> [String] {
    let haystack = variants.map { $0.css + "\n" + $0.html }.joined(separator: "\n")
    return props.compactMap { prop in
      let usesVariable = haystack.contains(prop.cssVariableName)
      let usesDataProp = haystack.contains("data-prop=\"\(prop.name)\"") || haystack.contains("data-prop='\(prop.name)'")
      return usesVariable || usesDataProp ? nil : prop.name
    }
  }

  private static func numberValue(_ raw: Any?) -> Double? {
    if let number = raw as? NSNumber, !isBooleanNumber(raw) { return number.doubleValue }
    if let string = raw as? String { return Double(string) }
    return nil
  }

  private static func boolValue(_ raw: Any?) -> Bool? {
    if isBooleanNumber(raw), let number = raw as? NSNumber { return number.boolValue }
    if let bool = raw as? Bool, !(raw is NSNumber) { return bool }
    if let string = raw as? String {
      switch string.lowercased() {
      case "true", "yes", "on": return true
      case "false", "no", "off": return false
      default: return nil
      }
    }
    return nil
  }
}
