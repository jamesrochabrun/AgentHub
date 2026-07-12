//
//  InspectorTweakResult.swift
//  AgentHub
//

enum InspectorTweakResult: Equatable, Sendable {
  case applied
  case noChanges
  case conflict
}

enum InspectorTweakPolicy: Equatable, Sendable {
  case flexible
  case additive
}
