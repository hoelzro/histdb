-- Optional acceleration for `entry MATCH ...` queries in histdb's h virtual table.
--
-- This creates an FTS5 trigram index over history.entry, rebuilds it for
-- existing rows, and installs triggers so future INSERT/UPDATE/DELETE changes
-- keep the index current.

CREATE VIRTUAL TABLE IF NOT EXISTS history_entry_trigram_idx
USING fts5(entry, content='history', content_rowid='rowid', tokenize='trigram');

INSERT INTO history_entry_trigram_idx(history_entry_trigram_idx) VALUES('rebuild');

CREATE TRIGGER IF NOT EXISTS history_entry_trigram_ai
AFTER INSERT ON history BEGIN
  INSERT INTO history_entry_trigram_idx(rowid, entry)
  VALUES (new.rowid, new.entry);
END;

CREATE TRIGGER IF NOT EXISTS history_entry_trigram_ad
AFTER DELETE ON history BEGIN
  INSERT INTO history_entry_trigram_idx(history_entry_trigram_idx, rowid, entry)
  VALUES('delete', old.rowid, old.entry);
END;

CREATE TRIGGER IF NOT EXISTS history_entry_trigram_au
AFTER UPDATE OF entry ON history BEGIN
  INSERT INTO history_entry_trigram_idx(history_entry_trigram_idx, rowid, entry)
  VALUES('delete', old.rowid, old.entry);

  INSERT INTO history_entry_trigram_idx(rowid, entry)
  VALUES (new.rowid, new.entry);
END;
