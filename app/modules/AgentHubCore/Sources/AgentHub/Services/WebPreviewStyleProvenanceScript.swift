//
//  WebPreviewStyleProvenanceScript.swift
//  AgentHub
//
//  Generates the in-page script that computes per-property winning-declaration
//  provenance from CSSOM. Injected on demand via `evaluateJavaScript`, anchored
//  by the selected element's CSS selector. Any cascade feature the script
//  cannot evaluate faithfully is reported as an uncertainty flag so the caller
//  degrades to agent-applied edits instead of guessing.
//

import Foundation

enum WebPreviewStyleProvenanceScript {

  /// Builds the provenance script for one element and property set.
  /// The script evaluates to a JSON-serializable object (see
  /// `WebPreviewStyleProvenance.parse`).
  static func script(selector: String, properties: [String]) -> String? {
    guard let selectorJSON = jsonLiteral(selector),
          let propertiesJSON = jsonLiteral(properties) else {
      return nil
    }

    return """
    (function() {
      var SELECTOR = \(selectorJSON);
      var PROPERTIES = \(propertiesJSON);

      var el = null;
      try { el = document.querySelector(SELECTOR); } catch (err) {}
      if (!el) { return { ok: false, reason: 'element-not-found' }; }

      var unreadableSheets = [];
      var orderCounter = 0;
      var candidates = {};
      PROPERTIES.forEach(function(p) { candidates[p] = []; });

      var adoptedSheets = [];
      try { adoptedSheets = Array.prototype.slice.call(document.adoptedStyleSheets || []); } catch (err) {}

      function isType(rule, name) {
        try {
          var ctor = window[name];
          if (ctor && rule instanceof ctor) { return true; }
        } catch (err) {}
        try {
          return Object.prototype.toString.call(rule) === '[object ' + name + ']';
        } catch (err) {}
        return false;
      }

      function selectorHasComplexPseudo(sel) {
        return /:(not|is|where|has|matches)\\(/i.test(sel);
      }

      function partSpecificity(part) {
        var a = 0, b = 0, c = 0;
        var s = part;
        s = s.replace(/\\[[^\\]]*\\]/g, function() { b += 1; return ' '; });
        s = s.replace(/::[a-zA-Z-]+(\\([^)]*\\))?/g, function() { c += 1; return ' '; });
        s = s.replace(/:[a-zA-Z-]+(\\([^)]*\\))?/g, function() { b += 1; return ' '; });
        s = s.replace(/#-?[_a-zA-Z][\\w-]*/g, function() { a += 1; return ' '; });
        s = s.replace(/\\.-?[_a-zA-Z][\\w-]*/g, function() { b += 1; return ' '; });
        s = s.replace(/[_a-zA-Z][\\w-]*/g, function() { c += 1; return ' '; });
        return [a, b, c];
      }

      function matchingSpecificity(selectorText) {
        var best = null;
        var parts = selectorText.split(',');
        for (var i = 0; i < parts.length; i++) {
          var part = parts[i].trim();
          if (!part) { continue; }
          var matched = false;
          try { matched = el.matches(part); } catch (err) { continue; }
          if (!matched) { continue; }
          var spec = partSpecificity(part);
          if (!best || compareSpecificity(spec, best) > 0) { best = spec; }
        }
        return best;
      }

      function compareSpecificity(lhs, rhs) {
        for (var i = 0; i < 3; i++) {
          if (lhs[i] !== rhs[i]) { return lhs[i] - rhs[i]; }
        }
        return 0;
      }

      function ownerNodeAttributes(sheet) {
        var attrs = {};
        try {
          var node = sheet.ownerNode;
          if (node && node.attributes) {
            for (var i = 0; i < node.attributes.length; i++) {
              var attr = node.attributes[i];
              if (attr.name === 'id' || attr.name.indexOf('data-') === 0) {
                attrs[attr.name] = attr.value;
              }
            }
          }
        } catch (err) {}
        return attrs;
      }

      function contextFlags(ctx) {
        var flags = [];
        if (ctx.layer) { flags.push('layer'); }
        if (ctx.scope) { flags.push('scope'); }
        if (ctx.container) { flags.push('containerQuery'); }
        if (ctx.unknownGroup) { flags.push('unknownGroup'); }
        if (ctx.adopted) { flags.push('adoptedSheet'); }
        return flags;
      }

      function mergeCtx(ctx, extra) {
        var merged = {};
        for (var key in ctx) { merged[key] = ctx[key]; }
        for (var extraKey in extra) { merged[extraKey] = extra[extraKey]; }
        return merged;
      }

      function handleStyleRule(rule, path, sheetIndex, sheet, ctx) {
        var selectorText = rule.selectorText || '';
        var matched = false;
        try { matched = el.matches(selectorText); } catch (err) { matched = false; }

        var isNested = selectorText.indexOf('&') >= 0 || (ctx.nestedParent === true);
        if (!matched && !isNested) { return; }

        for (var i = 0; i < PROPERTIES.length; i++) {
          var property = PROPERTIES[i];
          var value = '';
          try { value = rule.style.getPropertyValue(property); } catch (err) {}
          if (!value) { continue; }

          var flags = contextFlags(ctx);
          if (isNested) { flags.push('nestedSelector'); }
          if (selectorHasComplexPseudo(selectorText)) { flags.push('complexSelector'); }

          var spec = matched ? matchingSpecificity(selectorText) : null;
          candidates[property].push({
            value: value,
            important: rule.style.getPropertyPriority(property) === 'important',
            order: orderCounter,
            sheetIndex: sheetIndex,
            path: path,
            selectorText: selectorText,
            spec: spec || [0, 0, 0],
            flags: flags,
            href: sheet.href || null,
            ownerNodeAttributes: ownerNodeAttributes(sheet),
            adopted: ctx.adopted === true
          });
        }
        orderCounter += 1;
      }

      function walkRules(rules, pathPrefix, sheetIndex, sheet, ctx) {
        if (!rules) { return; }
        for (var i = 0; i < rules.length; i++) {
          var rule = rules[i];
          var path = pathPrefix.concat([i]);

          if (rule.selectorText !== undefined && rule.style) {
            handleStyleRule(rule, path, sheetIndex, sheet, ctx);
            if (rule.cssRules && rule.cssRules.length) {
              walkRules(rule.cssRules, path, sheetIndex, sheet, mergeCtx(ctx, { nestedParent: true }));
            }
          } else if (isType(rule, 'CSSMediaRule')) {
            var mediaMatches = false;
            try {
              mediaMatches = window.matchMedia(rule.conditionText || rule.media.mediaText).matches;
            } catch (err) {}
            if (mediaMatches) { walkRules(rule.cssRules, path, sheetIndex, sheet, ctx); }
          } else if (isType(rule, 'CSSSupportsRule')) {
            var supported = false;
            try { supported = CSS.supports(rule.conditionText); } catch (err) {}
            if (supported) { walkRules(rule.cssRules, path, sheetIndex, sheet, ctx); }
          } else if (isType(rule, 'CSSLayerBlockRule')) {
            walkRules(rule.cssRules, path, sheetIndex, sheet, mergeCtx(ctx, { layer: true }));
          } else if (isType(rule, 'CSSContainerRule')) {
            walkRules(rule.cssRules, path, sheetIndex, sheet, mergeCtx(ctx, { container: true }));
          } else if (isType(rule, 'CSSScopeRule')) {
            walkRules(rule.cssRules, path, sheetIndex, sheet, mergeCtx(ctx, { scope: true }));
          } else if (rule.cssRules && rule.cssRules.length) {
            walkRules(rule.cssRules, path, sheetIndex, sheet, mergeCtx(ctx, { unknownGroup: true }));
          }
        }
      }

      var documentSheets = [];
      try { documentSheets = Array.prototype.slice.call(document.styleSheets || []); } catch (err) {}

      for (var s = 0; s < documentSheets.length; s++) {
        var sheet = documentSheets[s];
        var rules = null;
        try { rules = sheet.cssRules; } catch (err) {
          unreadableSheets.push(sheet.href || '(inline)');
          continue;
        }
        walkRules(rules, [], s, sheet, {});
      }

      for (var a = 0; a < adoptedSheets.length; a++) {
        var adoptedSheet = adoptedSheets[a];
        var adoptedRules = null;
        try { adoptedRules = adoptedSheet.cssRules; } catch (err) {
          unreadableSheets.push('(adopted)');
          continue;
        }
        walkRules(adoptedRules, [], documentSheets.length + a, adoptedSheet, { adopted: true });
      }

      var winners = [];
      for (var p = 0; p < PROPERTIES.length; p++) {
        var property = PROPERTIES[p];
        var list = candidates[property];

        var inlineValue = '';
        var inlineImportant = false;
        try {
          inlineValue = el.style.getPropertyValue(property);
          inlineImportant = el.style.getPropertyPriority(property) === 'important';
        } catch (err) {}

        var best = null;
        var importantCount = 0;
        for (var c = 0; c < list.length; c++) {
          var candidate = list[c];
          if (candidate.important) { importantCount += 1; }
          if (!best) { best = candidate; continue; }
          if (candidate.important !== best.important) {
            if (candidate.important) { best = candidate; }
            continue;
          }
          var specComparison = compareSpecificity(candidate.spec, best.spec);
          if (specComparison > 0 || (specComparison === 0 && candidate.order >= best.order)) {
            best = candidate;
          }
        }

        var winner = null;
        if (inlineValue && (!best || !best.important || inlineImportant)) {
          winner = {
            property: property,
            declaredValue: inlineValue,
            isInline: true,
            isImportant: inlineImportant,
            rule: null,
            flags: []
          };
        } else if (best) {
          var flags = best.flags.slice();
          if (importantCount > 1 || (best.important && inlineValue)) {
            flags.push('importantConflict');
          }
          if (unreadableSheets.length > 0) {
            flags.push('unreadableSheet');
          }
          winner = {
            property: property,
            declaredValue: best.value,
            isInline: false,
            isImportant: best.important,
            rule: best.adopted ? null : {
              stylesheetHref: best.href,
              styleSheetIndex: best.sheetIndex,
              ruleIndexPath: best.path,
              selectorText: best.selectorText,
              specificity: best.spec,
              ownerNodeAttributes: best.ownerNodeAttributes
            },
            flags: flags
          };
        }

        if (winner) { winners.push(winner); }
      }

      return {
        ok: true,
        winners: winners,
        unreadableSheets: unreadableSheets,
        hasAdoptedSheets: adoptedSheets.length > 0
      };
    })();
    """
  }

  private static func jsonLiteral(_ value: Any) -> String? {
    guard JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value]),
          let wrapped = String(data: data, encoding: .utf8),
          wrapped.hasPrefix("["), wrapped.hasSuffix("]") else {
      return nil
    }
    return String(wrapped.dropFirst().dropLast())
  }
}
