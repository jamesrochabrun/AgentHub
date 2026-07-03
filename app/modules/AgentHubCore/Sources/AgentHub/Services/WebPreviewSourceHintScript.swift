//
//  WebPreviewSourceHintScript.swift
//  AgentHub
//
//  Generates the in-page script that reads framework dev-build source
//  metadata for the selected element. Every accessor is wrapped so a missing
//  framework or a production build simply yields no hints.
//

import Foundation

enum WebPreviewSourceHintScript {

  static func script(selector: String) -> String? {
    guard let selectorJSON = jsonLiteral(selector) else { return nil }

    return """
    (function() {
      var SELECTOR = \(selectorJSON);

      var el = null;
      try { el = document.querySelector(SELECTOR); } catch (err) {}
      if (!el) { return { ok: false, reason: 'element-not-found' }; }

      var hints = [];
      function push(kind, file, line, column, detail) {
        hints.push({
          kind: kind,
          file: file || null,
          line: line || null,
          column: column || null,
          detail: detail || null
        });
      }

      function parseLocation(value) {
        if (!value) { return null; }
        var match = /^(.*):(\\d+):(\\d+)$/.exec(value);
        if (!match) { return { file: value, line: null, column: null }; }
        return { file: match[1], line: parseInt(match[2], 10), column: parseInt(match[3], 10) };
      }

      // Svelte dev builds annotate every element with its source location.
      try {
        var svelteMeta = el.__svelte_meta;
        if (svelteMeta && svelteMeta.loc && svelteMeta.loc.file) {
          push('svelteMeta', svelteMeta.loc.file, svelteMeta.loc.line || null, svelteMeta.loc.column || null, null);
        }
      } catch (err) {}

      // Compile-time attributes on the element and up to three ancestors.
      var node = el;
      for (var depth = 0; node && depth < 4; depth += 1) {
        try {
          if (node.getAttribute) {
            var ancestorSuffix = depth > 0 ? ' (ancestor)' : '';

            var vueLocation = parseLocation(node.getAttribute('data-v-inspector'));
            if (vueLocation) {
              push('vueInspector', vueLocation.file, vueLocation.line, vueLocation.column,
                   depth > 0 ? 'ancestor' : null);
            }

            var sourceLoc = parseLocation(node.getAttribute('data-source-loc'));
            if (sourceLoc) {
              push('genericAttribute', sourceLoc.file, sourceLoc.line, sourceLoc.column,
                   'data-source-loc' + ancestorSuffix);
            }

            var inspectorPath = node.getAttribute('data-inspector-relative-path');
            if (inspectorPath) {
              push('genericAttribute', inspectorPath,
                   parseInt(node.getAttribute('data-inspector-line') || '0', 10) || null,
                   parseInt(node.getAttribute('data-inspector-column') || '0', 10) || null,
                   'data-inspector' + ancestorSuffix);
            }

            var lovLocation = parseLocation(node.getAttribute('data-lov-id'));
            if (lovLocation && lovLocation.line) {
              push('genericAttribute', lovLocation.file, lovLocation.line, lovLocation.column,
                   'data-lov-id' + ancestorSuffix);
            }

            var oid = node.getAttribute('data-onlook-id') || node.getAttribute('data-oid');
            if (oid) {
              push('genericAttribute', null, null, null,
                   'data-oid=' + oid + ancestorSuffix);
            }
          }
        } catch (err) {}
        node = node.parentElement;
      }

      // React fibers: exact source on <=18 dev builds, owner component chain on 19.
      try {
        var fiberKey = null;
        for (var key in el) {
          if (key.indexOf('__reactFiber$') === 0) { fiberKey = key; break; }
        }
        if (fiberKey) {
          var fiber = el[fiberKey];
          var debugSource = fiber && fiber._debugSource;
          if (debugSource && debugSource.fileName) {
            push('reactDebugSource', debugSource.fileName,
                 debugSource.lineNumber || null, debugSource.columnNumber || null, null);
          } else {
            var names = [];
            var owner = fiber && fiber._debugOwner;
            var hops = 0;
            while (owner && hops < 5) {
              var type = owner.type;
              var name = type && (type.displayName || type.name);
              if (typeof name === 'string' && name) { names.push(name); }
              owner = owner._debugOwner;
              hops += 1;
            }
            if (names.length > 0) {
              push('reactOwnerChain', null, null, null, 'component chain: ' + names.reverse().join(' > '));
            }
          }
        }
      } catch (err) {}

      return { ok: true, hints: hints };
    })();
    """
  }

  private static func jsonLiteral(_ value: String) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: [value]),
          let wrapped = String(data: data, encoding: .utf8),
          wrapped.hasPrefix("["), wrapped.hasSuffix("]") else {
      return nil
    }
    return String(wrapped.dropFirst().dropLast())
  }
}
