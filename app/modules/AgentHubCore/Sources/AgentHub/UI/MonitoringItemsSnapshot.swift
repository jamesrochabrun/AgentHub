//
//  MonitoringItemsSnapshot.swift
//  AgentHub
//

import Foundation

struct MonitoringItemsSnapshot<Item: Identifiable> where Item.ID == String {
  let allItems: [Item]
  let visibleItems: [Item]
  let groupedItems: [(modulePath: String, items: [Item])]
  let flatSortedItems: [Item]
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
    layoutMode: HubLayoutMode,
    modulePath: (Item) -> String,
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

    if layoutMode == .single, let effectivePrimaryItem {
      self.visibleItems = [effectivePrimaryItem]
    } else {
      self.visibleItems = items
    }

    self.groupedItems = Dictionary(grouping: visibleItems, by: modulePath)
      .sorted { $0.key < $1.key }
      .map { group in
        (
          modulePath: group.key,
          items: group.value.sorted { timestamp($0) > timestamp($1) }
        )
      }
    self.flatSortedItems = groupedItems.flatMap(\.items)
  }
}
