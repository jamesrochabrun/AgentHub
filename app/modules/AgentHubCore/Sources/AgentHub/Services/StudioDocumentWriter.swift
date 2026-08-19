import AgentHubCLIKit
import CryptoKit
import Foundation

public protocol StudioDocumentWriting: Sendable {
  /// The directory every served document lives under.
  var rootURL: URL { get }
  /// Writes (or rewrites) the served document and returns its `index.html` URL.
  func write(_ artifact: StudioArtifact, projectKey: String) throws -> URL
  /// Where an artifact's `index.html` lives, whether or not it has been written.
  func documentURL(forArtifactId id: String, projectKey: String) -> URL
  /// The document's path relative to `rootURL`, for the static server.
  func relativePath(forArtifactId id: String, projectKey: String) -> String
  func delete(artifactId: String, projectKey: String) throws
  func deleteAll(projectKey: String) throws
  /// Whether the served file exists and was produced by the current host page.
  /// A canvas written by an older writer is stale — host-page fixes must reach
  /// existing canvases without waiting for the agent to re-file.
  func isCurrent(_ artifact: StudioArtifact, projectKey: String) -> Bool
}

/// Materializes a Studio artifact into the file the static server serves.
///
/// Documents are served verbatim; canvases are composed into a host page that
/// owns `<head>`, the pan/zoom transform, and the artboard layout, with every
/// variant's CSS scoped by `StudioCSSScoper`. Nothing here ever writes into a
/// user's repository: `rootURL` is AgentHub's own directory.
public struct StudioDocumentWriter: StudioDocumentWriting {
  public let rootURL: URL

  public init(rootURL: URL = StudioDocumentWriter.defaultRootURL) {
    self.rootURL = rootURL
  }

  public static var defaultRootURL: URL {
    AgentHubApplicationSupport.baseDirectoryURL.appendingPathComponent("studio", isDirectory: true)
  }

  /// Bump whenever the canvas host page (CSS/JS below) changes behaviour, so
  /// canvases already on disk are regenerated on next open.
  public static let hostVersion = 3
  static let hostVersionMarker = "<meta name=\"agenthub-studio-host\" content=\""

  public func isCurrent(_ artifact: StudioArtifact, projectKey: String) -> Bool {
    let url = documentURL(forArtifactId: artifact.id, projectKey: projectKey)
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
    switch artifact.kind {
    case .document:
      return true
    case .canvas:
      return head.contains("\(Self.hostVersionMarker)\(Self.hostVersion)\"")
    }
  }

  public func write(_ artifact: StudioArtifact, projectKey: String) throws -> URL {
    let url = documentURL(forArtifactId: artifact.id, projectKey: projectKey)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let html = try Self.render(artifact)
    try Data(html.utf8).write(to: url, options: [.atomic])
    // Sidecar the CLI reads for `agenthub_get_artifact`: the current payload,
    // including any edits the user baked in from the panel. The CLI never
    // opens SQLite; this file is the agent's view of "what is on the canvas".
    let payloadURL = Self.payloadURL(besideDocument: url)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    try (try encoder.encode(artifact)).write(to: payloadURL, options: [.atomic])
    return url
  }

  public static let payloadFileName = "artifact.json"

  public static func payloadURL(besideDocument documentURL: URL) -> URL {
    documentURL.deletingLastPathComponent().appendingPathComponent(payloadFileName, isDirectory: false)
  }

  public func documentURL(forArtifactId id: String, projectKey: String) -> URL {
    rootURL.appendingPathComponent(relativePath(forArtifactId: id, projectKey: projectKey), isDirectory: false)
  }

  public func relativePath(forArtifactId id: String, projectKey: String) -> String {
    "\(Self.projectDirectoryName(forProjectKey: projectKey))/\(Self.artifactDirectoryName(forId: id))/index.html"
  }

  public func delete(artifactId: String, projectKey: String) throws {
    let directory = documentURL(forArtifactId: artifactId, projectKey: projectKey).deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }

  public func deleteAll(projectKey: String) throws {
    let directory = rootURL.appendingPathComponent(
      Self.projectDirectoryName(forProjectKey: projectKey),
      isDirectory: true
    )
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }

  // MARK: - Naming

  /// A short, stable, filesystem-safe name for a project bucket. Not reversible
  /// on purpose — the database holds the mapping — so long paths never hit the
  /// 255-byte component limit and never leak into a served URL.
  public static func projectDirectoryName(forProjectKey key: String) -> String {
    let digest = SHA256.hash(data: Data(MeasurementProjectScope.normalized(key).utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// Agent-supplied ids are used as-is only when they are plainly safe as a
  /// single path component; anything else is hashed. `..` and `/` never reach
  /// the filesystem.
  public static func artifactDirectoryName(forId id: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    // Dot-prefixed names are hashed too: the static server refuses dotfiles.
    let isSafe = !id.isEmpty
      && id.count <= 80
      && !id.hasPrefix(".")
      && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    if isSafe { return id }
    let digest = SHA256.hash(data: Data(id.utf8))
    return "h-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Rendering

  public static func render(_ artifact: StudioArtifact) throws -> String {
    switch artifact.kind {
    case .document:
      return artifact.html ?? ""
    case .canvas:
      return try renderCanvas(artifact)
    }
  }

  /// The canvas host page: one document, N artboards, pan/zoom on the container.
  ///
  /// Artboards are sibling sections rather than iframes because the inspector
  /// bridge is main-frame-only. Each artboard resets inheritance (`all: initial`)
  /// and contains its own paint, so the host chrome never leaks in and a
  /// variant never paints out.
  static func renderCanvas(_ artifact: StudioArtifact) throws -> String {
    var variantStyles: [String] = []
    var artboards: [String] = []

    for variant in artifact.variants {
      let scoped = try StudioCSSScoper.scope(variant.css, variantName: variant.name)
      let selector = StudioCSSScoper.artboardSelector(forVariantName: variant.name)
      var sizing: [String] = []
      if let width = variant.width { sizing.append("width: \(Self.pixels(width))") }
      if let height = variant.height { sizing.append("height: \(Self.pixels(height)); overflow: auto") }
      var block = ""
      if !sizing.isEmpty {
        block += "\(selector) { \(sizing.joined(separator: "; ")); }\n"
      }
      block += scoped.css
      variantStyles.append("<style data-variant=\"\(escape(variant.name))\">\n\(block)\n</style>")

      let notes = variant.notes.map { "<p class=\"studio-notes\">\(escape($0))</p>" } ?? ""
      artboards.append("""
        <figure class="studio-frame" data-variant="\(escape(variant.name))">
          <figcaption class="studio-caption">
            <div class="studio-caption-row">
              <span class="studio-name">\(escape(variant.name))</span>
              <button type="button" class="studio-implement" data-variant="\(escape(variant.name))" title="Ask the agent to implement this variant in the project">Implement</button>
            </div>
            \(notes)
          </figcaption>
          <div class="studio-frame-body">
            <section class="studio-artboard" data-variant="\(escape(variant.name))">
        \(variant.html)
            </section>
          </div>
        </figure>
        """)
    }

    // Shared tweak props: defaults land in a stylesheet so the canvas renders
    // correctly with no JS at all (export, plain browser); the script below
    // re-applies them and wires live changes from the Tweaks panel.
    let propsCSS = artifact.props.isEmpty ? "" : """
      <style id="studio-props">
      .studio-artboard {
      \(artifact.props.map { "  \($0.cssVariableName): \(cssBlockValue($0.cssValue));" }.joined(separator: "\n"))
      }
      </style>
      """
    let propsJSON = try propsSchemaJSON(artifact.props)

    return """
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="agenthub-studio-host" content="\(Self.hostVersion)">
      <title>\(escape(artifact.title))</title>
      <style>
      \(hostCSS)
      </style>
      \(propsCSS)
      \(variantStyles.joined(separator: "\n"))
      </head>
      <body>
      <div id="studio-viewport">
        <div id="studio-canvas">
      \(artboards.joined(separator: "\n"))
        </div>
      </div>
      <div id="studio-hud" aria-label="Canvas zoom">
        <button type="button" data-zoom="out" title="Zoom out">−</button>
        <button type="button" data-zoom="reset" title="Reset zoom"><span id="studio-zoom-label">100%</span></button>
        <button type="button" data-zoom="in" title="Zoom in">+</button>
        <button type="button" data-zoom="fit" title="Fit all">Fit</button>
      </div>
      <script>
      window.__studioProps = \(propsJSON);
      \(hostScript)
      </script>
      </body>
      </html>
      """
  }

  /// A prop value as it may appear inside the static `<style>` block. Text and
  /// select values are agent- or user-authored strings: `}` would end the rule,
  /// `;` would start a declaration, and `</style>` would end the element. CSS
  /// hex escapes keep the token stream intact and decode to the same characters
  /// (`\3c ` → `<`), so `var(--x)` sees what the live `setProperty` path sets.
  static func cssBlockValue(_ value: String) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "<", ">", "{", "}", ";", "\\", "\n", "\r", "\u{2028}", "\u{2029}":
        out += String(format: "\\%x ", scalar.value)
      default:
        out.unicodeScalars.append(scalar)
      }
    }
    return out
  }

  /// The ordered schema the host page hands to `dc_set_props`, as a JSON array
  /// literal safe to inline in a `<script>`.
  static func propsSchemaJSON(_ props: [StudioTweakProp]) throws -> String {
    let objects: [[String: Any]] = props.map { prop in
      var declaration = prop.declaration
      declaration["name"] = prop.name
      return declaration
    }
    let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "</", with: "<\\/")
      .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
      .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
  }

  private static func pixels(_ value: Double) -> String {
    value == value.rounded() ? "\(Int(value))px" : "\(value)px"
  }

  static func escape(_ text: String) -> String {
    text
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  private static let hostCSS = """
    :root { color-scheme: light dark; }
    html, body { margin: 0; height: 100%; overflow: hidden; }
    body {
      background: #ececef;
      background-image: radial-gradient(rgba(0,0,0,0.10) 1px, transparent 1px);
      background-size: 24px 24px;
      font: 13px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      color: #1d1d1f;
    }
    @media (prefers-color-scheme: dark) {
      body {
        background: #1c1c1e;
        background-image: radial-gradient(rgba(255,255,255,0.09) 1px, transparent 1px);
        color: #f2f2f7;
      }
    }
    #studio-viewport { position: fixed; inset: 0; overflow: hidden; cursor: grab; }
    #studio-viewport.panning { cursor: grabbing; }
    #studio-canvas {
      position: absolute; top: 0; left: 0;
      transform-origin: 0 0;
      display: flex; flex-wrap: wrap; align-items: flex-start; gap: 48px;
      padding: 48px; box-sizing: border-box; width: 100vw;
    }
    .studio-frame { margin: 0; display: flex; flex-direction: column; gap: 8px; max-width: 100%; }
    .studio-caption { display: flex; flex-direction: column; gap: 2px; padding: 0 2px; }
    .studio-name { font-weight: 600; font-size: 12px; letter-spacing: 0.01em; }
    .studio-notes { margin: 0; font-size: 12px; opacity: 0.7; max-width: 48ch; }
    .studio-caption-row { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
    .studio-implement {
      all: unset; cursor: pointer; display: none;
      font: 600 11px -apple-system, system-ui, sans-serif; letter-spacing: 0.01em;
      padding: 3px 9px; border-radius: 999px;
      color: #1d1d1f; background: rgba(0,0,0,0.08);
    }
    .studio-implement:hover { background: #0a84ff; color: #fff; }
    .studio-implement:active { transform: translateY(0.5px); }
    body.studio-hosted .studio-implement { display: inline-block; }
    @media (prefers-color-scheme: dark) {
      .studio-implement { color: #f2f2f7; background: rgba(255,255,255,0.12); }
    }
    .studio-frame-body {
      border-radius: 10px; overflow: hidden;
      background: #fff;
      box-shadow: 0 0 0 1px rgba(0,0,0,0.08), 0 8px 24px rgba(0,0,0,0.10);
    }
    @media (prefers-color-scheme: dark) {
      .studio-frame-body { box-shadow: 0 0 0 1px rgba(255,255,255,0.10), 0 8px 24px rgba(0,0,0,0.5); }
    }
    .studio-artboard {
      all: initial;
      display: block;
      contain: layout paint;
      isolation: isolate;
      box-sizing: border-box;
      background: #fff;
      color: #111;
      font: 16px/1.4 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
      min-width: 120px; min-height: 40px;
    }
    #studio-hud {
      position: fixed; right: 12px; bottom: 12px; z-index: 2147483000;
      display: flex; gap: 2px; padding: 3px;
      background: rgba(255,255,255,0.85); backdrop-filter: blur(12px);
      border-radius: 8px; box-shadow: 0 1px 4px rgba(0,0,0,0.18);
    }
    @media (prefers-color-scheme: dark) { #studio-hud { background: rgba(44,44,46,0.85); } }
    #studio-hud button {
      all: unset; cursor: pointer; font: 12px -apple-system, system-ui, sans-serif;
      min-width: 24px; height: 24px; padding: 0 6px; border-radius: 6px; text-align: center;
      color: inherit;
    }
    #studio-hud button:hover { background: rgba(127,127,127,0.18); }
    """

  private static let hostScript = """
    (function () {
      var viewport = document.getElementById('studio-viewport');
      var canvas = document.getElementById('studio-canvas');
      var label = document.getElementById('studio-zoom-label');
      var scale = 1, tx = 0, ty = 0;
      var MIN = 0.1, MAX = 6;

      // The inspector overlay (highlight + native comment box) tracks the
      // selected element by listening for window 'scroll'. Panning here is a
      // CSS transform, which never scrolls, so tell it the viewport moved:
      // getBoundingClientRect() already reflects the new transform.
      function notifyViewportMoved() {
        try { window.dispatchEvent(new Event('scroll')); } catch (err) {}
      }
      function apply() {
        canvas.style.transform = 'translate(' + tx + 'px,' + ty + 'px) scale(' + scale + ')';
        label.textContent = Math.round(scale * 100) + '%';
        notifyViewportMoved();
      }
      function zoomAt(factor, cx, cy) {
        var next = Math.min(MAX, Math.max(MIN, scale * factor));
        var ratio = next / scale;
        tx = cx - (cx - tx) * ratio;
        ty = cy - (cy - ty) * ratio;
        scale = next;
        apply();
      }
      function fit() {
        var rect = canvas.getBoundingClientRect();
        var w = rect.width / scale, h = rect.height / scale;
        if (!w || !h) return;
        var s = Math.min(viewport.clientWidth / w, viewport.clientHeight / h, 1);
        scale = Math.max(MIN, s);
        tx = (viewport.clientWidth - w * scale) / 2;
        ty = Math.max(0, (viewport.clientHeight - h * scale) / 2);
        apply();
      }

      viewport.addEventListener('wheel', function (e) {
        if (e.target.closest && e.target.closest('#studio-hud')) return;
        e.preventDefault();
        if (e.ctrlKey || e.metaKey) {
          zoomAt(Math.exp(-e.deltaY * 0.01), e.clientX, e.clientY);
        } else {
          tx -= e.deltaX; ty -= e.deltaY; apply();
        }
      }, { passive: false });

      var dragging = false, lastX = 0, lastY = 0;
      viewport.addEventListener('mousedown', function (e) {
        if (e.button !== 1 && !(e.button === 0 && (e.altKey || e.target === viewport || e.target === canvas))) return;
        dragging = true; lastX = e.clientX; lastY = e.clientY;
        viewport.classList.add('panning');
        e.preventDefault();
      });
      window.addEventListener('mousemove', function (e) {
        if (!dragging) return;
        tx += e.clientX - lastX; ty += e.clientY - lastY;
        lastX = e.clientX; lastY = e.clientY; apply();
      });
      window.addEventListener('mouseup', function () {
        dragging = false; viewport.classList.remove('panning');
      });

      document.getElementById('studio-hud').addEventListener('click', function (e) {
        var button = e.target.closest('button'); if (!button) return;
        var cx = viewport.clientWidth / 2, cy = viewport.clientHeight / 2;
        switch (button.getAttribute('data-zoom')) {
          case 'in': zoomAt(1.25, cx, cy); break;
          case 'out': zoomAt(0.8, cx, cy); break;
          case 'reset': scale = 1; tx = 0; ty = 0; apply(); break;
          case 'fit': fit(); break;
        }
      });

      window.addEventListener('keydown', function (e) {
        if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable)) return;
        if ((e.metaKey || e.ctrlKey) && (e.key === '=' || e.key === '+')) { e.preventDefault(); zoomAt(1.25, viewport.clientWidth/2, viewport.clientHeight/2); }
        if ((e.metaKey || e.ctrlKey) && e.key === '-') { e.preventDefault(); zoomAt(0.8, viewport.clientWidth/2, viewport.clientHeight/2); }
        if ((e.metaKey || e.ctrlKey) && e.key === '0') { e.preventDefault(); scale = 1; tx = 0; ty = 0; apply(); }
        if (e.key === '1' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); fit(); }
      });

      // Shared tweak props → CSS custom properties on every artboard.
      var propsSchema = Array.isArray(window.__studioProps) ? window.__studioProps : [];
      var propsByName = {};
      propsSchema.forEach(function (p) { propsByName[p.name] = p; });
      function cssValueFor(p, value) {
        if (p.type === 'slider' && typeof value === 'number') {
          return (Number.isInteger(value) ? String(value) : String(value)) + (p.unit || '');
        }
        if (typeof value === 'boolean') return value ? '1' : '0';
        return String(value);
      }
      function applyProp(name, value) {
        var p = propsByName[name]; if (!p) return;
        var css = cssValueFor(p, value);
        var boards = document.querySelectorAll('.studio-artboard');
        for (var i = 0; i < boards.length; i++) boards[i].style.setProperty('--' + name, css);
        if (p.type === 'text' || p.type === 'select') {
          var sel = '.studio-artboard [data-prop="' + (window.CSS && CSS.escape ? CSS.escape(name) : name) + '"]';
          var targets = document.querySelectorAll(sel);
          for (var j = 0; j < targets.length; j++) targets[j].textContent = String(value);
        }
        // A tweak can resize the selected element; keep the highlight on it.
        if (typeof notifyViewportMoved === 'function') notifyViewportMoved();
      }
      if (propsSchema.length) {
        propsSchema.forEach(function (p) { applyProp(p.name, p.value); });
        window.dc_on_props_changed = function (props) {
          Object.keys(props || {}).forEach(function (name) { applyProp(name, props[name]); });
        };
        if (typeof window.dc_set_props === 'function') {
          var schema = {};
          propsSchema.forEach(function (p) {
            var d = { type: p.type, label: p.label, value: p.value };
            if (p.min !== undefined) d.min = p.min;
            if (p.max !== undefined) d.max = p.max;
            if (p.step !== undefined) d.step = p.step;
            if (p.options) d.options = p.options;
            schema[p.name] = d;
          });
          window.dc_set_props(schema);
        }
      }

      // Inside AgentHub the panel registers a message handler; the Implement
      // buttons only show when it exists (a plain browser or an export has
      // no agent to talk to).
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.agentHubStudio;
      if (bridge) {
        document.body.classList.add('studio-hosted');
        document.addEventListener('click', function (e) {
          var button = e.target && e.target.closest ? e.target.closest('.studio-implement') : null;
          if (!button) return;
          e.preventDefault(); e.stopPropagation();
          try { bridge.postMessage({ type: 'implement', variant: button.getAttribute('data-variant') }); } catch (err) {}
        }, true);
      }

      window.__agenthubStudio = {
        variantForSelector: function (selector) {
          try {
            var el = document.querySelector(selector);
            var board = el && el.closest ? el.closest('.studio-artboard') : null;
            return board ? board.getAttribute('data-variant') : null;
          } catch (err) { return null; }
        },
        fit: fit,
        // Edit mode bakes changes back into the variant payload: the artboard's
        // innerHTML *is* the edited variant (inline styles/text from the design
        // toolbar), so serialize it. Returns { variantName: html }.
        serializeArtboards: function (names) {
          var out = {};
          var boards = document.querySelectorAll('.studio-artboard');
          for (var i = 0; i < boards.length; i++) {
            var name = boards[i].getAttribute('data-variant');
            if (!names || names.indexOf(name) !== -1) out[name] = boards[i].innerHTML.trim();
          }
          return out;
        },
        variantsForSelectors: function (selectors) {
          var out = {};
          (selectors || []).forEach(function (sel) {
            try {
              var el = document.querySelector(sel);
              var board = el && el.closest ? el.closest('.studio-artboard') : null;
              if (board) out[sel] = board.getAttribute('data-variant');
            } catch (err) {}
          });
          return out;
        },
        removeElement: function (selector) {
          try { var el = document.querySelector(selector); if (el) { el.remove(); return true; } } catch (err) {}
          return false;
        }
      };
      apply();
    })();
    """
}
