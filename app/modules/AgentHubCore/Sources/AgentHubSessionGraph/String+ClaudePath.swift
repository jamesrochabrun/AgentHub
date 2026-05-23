//
//  String+ClaudePath.swift
//  AgentHubSessionGraph
//
//  Helper for encoding paths to match Claude CLI's project directory naming convention.
//

import Foundation

extension String {
  var claudeProjectPathEncoded: String {
    self
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ".", with: "-")
      .replacingOccurrences(of: "_", with: "-")
  }
}
