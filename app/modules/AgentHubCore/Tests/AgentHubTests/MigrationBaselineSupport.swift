import Foundation
import GRDB

@testable import AgentHubCore

/// Seeds `grdb_migrations` with every migration that ran *before* `identifier`,
/// so opening the store applies `identifier` and everything after it.
///
/// Migration-preservation tests must anchor on the identifier they are testing,
/// never on a positional `dropLast(n)`: the moment a new `vN_` migration is
/// appended, a positional drop silently starts marking the migration under test
/// as already-applied, and the test then exercises a schema it never created.
func seedMigrationBaseline(before identifier: String, in db: Database) throws {
  try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")

  let identifiers = SessionMetadataStore.migrationIdentifiers
  guard let index = identifiers.firstIndex(of: identifier) else {
    fatalError("Unknown migration identifier: \(identifier)")
  }

  for applied in identifiers[..<index] {
    try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [applied])
  }
}
