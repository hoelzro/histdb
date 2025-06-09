DROP TABLE IF EXISTS history;
CREATE TABLE history (
  hostname TEXT,
  session_id TEXT,
  timestamp INTEGER,
  history_id INTEGER,
  cwd TEXT,
  entry TEXT,
  duration INTEGER,
  exit_status INTEGER
);

INSERT INTO history (hostname, session_id, timestamp, history_id, cwd, entry, duration, exit_status) VALUES
  ('host1', '017e12ef-9c00-7a64-ae73-cffc1360299c', 1640995200, 1, '/home/rob', 'vim file1', 10, 0),
  ('host1', '017e12ef-9c00-7a64-ae73-cffc1360299c', 1640995260, 2, '/home/rob', 'ls -l', 2, 0),
  ('host1', '017e1815-f800-715d-88dc-0590f94e9710', 1641081600, 3, '/home/rob/project', 'git status', 3, 0),
  ('host1', '017e1815-f800-715d-88dc-0590f94e9710', 1641168000, 4, '/home/rob', 'vim file2', 20, 0),
  ('host2', '017e2262-b000-78d9-bed8-c98696ada0be', 1641254400, 5, '/home/rob', 'echo test', 1, 0),
  ('host2', NULL, NULL, 6, '/home/rob', 'incomplete', 1, 1),
  ('host3', 'session_today', CAST(strftime('%s','now') AS INTEGER), 7, '/home/rob', 'today cmd', 1, 0);
