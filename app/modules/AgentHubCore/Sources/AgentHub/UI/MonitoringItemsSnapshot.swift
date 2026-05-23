//
//  MonitoringItemsSnapshot.swift
//  AgentHub
//

import Foundation

struct MonitoringItemsSnapshot<Item: Identifiable> where Item.ID == String {
  let allItems: [Item]
  let visibleItems: [Item]
  let effectivePrimaryItem: Item?

  var effectivePrimaryItemID: String? {
    effectivePrimaryItem?.id
  }

  var itemIDs: [String] {
    allItems.map(\.id)
  }

  init(
    items: [Item],
    primaryItemID: String?,
    timestamp: (Item) -> Date
  ) {
    self.allItems = items

    let sortedItems = items.sorted { timestamp($0) > timestamp($1) }
    if let primaryItemID,
       let selectedItem = items.first(where: { $0.id == primaryItemID }) {
      self.effectivePrimaryItem = selectedItem
    } else {
      self.effectivePrimaryItem = sortedItems.first
    }

    self.visibleItems = effectivePrimaryItem.map { [$0] } ?? []
  }
}
