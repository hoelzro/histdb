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
  ('host1', '1', 1640995200, 1, '/home/rob', 'vim file1', 10, 0),
  ('host1', '1', 1640995260, 2, '/home/rob', 'ls -l', 2, 0),
  ('host1', '2', 1641081600, 3, '/home/rob/project', 'git status', 3, 0),
  ('host1', '2', 1641168000, 4, '/home/rob', 'vim file2', 20, 0),
  ('host2', '3', 1641254400, 5, '/home/rob', 'echo test', 1, 0),
  ('host2', '4', NULL, 6, '/home/rob', 'incomplete', 1, 1);
