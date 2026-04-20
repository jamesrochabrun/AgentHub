//
// CodeEditSymbols.swift
//
// Created by Lukas Pistrol on 18.04.22.
//

import SwiftUI

public extension Image {

    /// Creates an Image representing a custom SF Symbol
    /// - Parameter symbol: The name of the symbol in `Symbols.xcassets`
    init(symbol: String) {
        self.init(symbol, bundle: Bundle.module)
    }

    // MARK: - Symbols

    static let vault: Image = .init(symbol: "vault")
    static let vaultFill: Image = .init(symbol: "vault.fill")
    static let commit: Image = .init(symbol: "commit")
    static let checkout: Image = .init(symbol: "checkout")
    static let branch: Image = .init(symbol: "branch")
    static let breakpoint: Image = .init(symbol: "breakpoint")
    static let breakpointFill: Image = .init(symbol: "breakpoint.fill")
    static let chevronUpChevronDown: Image = .init(symbol: "chevron.up.chevron.down")
    static let github: Image = .init(symbol: "github")
    static let docJava: Image = .init(symbol: "doc.java")
    static let docJavascript: Image = .init(symbol: "doc.javascript")
    static let docJson: Image = .init(symbol: "doc.json")
    static let docPython: Image = .init(symbol: "doc.python")
    static let docRuby: Image = .init(symbol: "doc.ruby")
    static let squareSplitHorizontalPlus: Image = .init(symbol: "square.split.horizontal.plus")
    static let squareSplitVerticalPlus: Image = .init(symbol: "square.split.vertical.plus")
    
    // add static properties for your symbols above this line

}


public extension NSImage {

    /// Returns a NSImage representing a custom SF Symbol
    /// - Parameter named: The name of the symbol in `Symbols.xcassets`
    /// - Returns: a NSImage
    static func symbol(named: String) -> NSImage? {
        Bundle.module.image(forResource: named)
    }

    // MARK: - Symbols

    static let vault: NSImage? = .symbol(named: "vault")
    static let vaultFill: NSImage? = .symbol(named: "vault.fill")
    static let commit: NSImage? = .symbol(named: "commit")
    static let checkout: NSImage? = .symbol(named: "checkout")
    static let branch: NSImage? = .symbol(named: "branch")
    static let breakpoint: NSImage? = .symbol(named: "breakpoint")
    static let breakpointFill: NSImage? = .symbol(named: "breakpoint.fill")
    static let chevronUpChevronDown: NSImage? = .symbol(named: "chevron.up.chevron.down")
    static let github: NSImage? = .symbol(named: "github")
    static let docJava: NSImage? = .symbol(named: "doc.java")
    static let docJavascript: NSImage? = .symbol(named: "doc.javascript")
    static let docJson: NSImage? = .symbol(named: "doc.json")
    static let docPython: NSImage? = .symbol(named: "doc.python")
    static let docRuby: NSImage? = .symbol(named: "doc.ruby")
    static let squareSplitHorizontalPlus: NSImage? = .symbol(named: "square.split.horizontal.plus")
    static let squareSplitVerticalPlus: NSImage? = .symbol(named: "square.split.vertical.plus")
    
    // add static properties for your symbols above this line

}
