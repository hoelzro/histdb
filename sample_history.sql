DROP TABLE IF EXISTS history;
CREATE TABLE history (
  hostname TEXT,
  session_id TEXT,
  timestamp INTEGER,
  history_id INTEGER,
  cwd TEXT,
  entry TEXT,
  duration,
  exit_status
);

INSERT INTO history (hostname, session_id, timestamp, history_id, cwd, entry, duration, exit_status) VALUES
  ('host1', '017e12ef-9c00-7a64-ae73-cffc1360299c', 1640995200, 1, '/home/rob', 'vim file1', 10, 0),
  ('host1', '017e12ef-9c00-7a64-ae73-cffc1360299c', 1640995260, 2, '/home/rob', 'ls -l', 2, 0),
  ('host1', '017e1815-f800-715d-88dc-0590f94e9710', 1641081600, 3, '/home/rob/project', 'git status', 3, 0),
  ('host1', '017e1815-f800-715d-88dc-0590f94e9710', 1641168000, 4, '/home/rob', 'vim file2', 20, 0),
  ('host2', '017e2262-b000-78d9-bed8-c98696ada0be', 1641254400, 5, '/home/rob', 'echo test', 1, 0),
  ('host1', '737207', 1641340800, 7, '/home/rob', 'make test', 5, 0),
  ('host1', '737207', 1641340860, 8, '/home/rob', 'echo done', 1, 0),
  ('host1', 123456, 1641427200, 9, '/home/rob', 'pwd', 1, 0),
  ('host2', NULL, NULL, 10, '/home/rob', 'incomplete', 1, 1),
  ('host1', 'text-types', 1641513600, 11, '/home/rob', 'vim file3', '5', '0'),
  ('host1', 'text-types', 1641513660, 12, '/home/rob', 'make fail', '3', '1'),
  ('host1', 'fed88fae-4d0a-471c-bd1b-94d15c5f80a5', strftime('%s','now','-10 days'), 50002, '/home/rob/cicd', 'cicd build --release', 45, 1),
  ('host1', 'fed88fae-4d0a-471c-bd1b-94d15c5f80a5', strftime('%s','now','-11 days'), 50001, '/home/rob/cicd', 'cicd build --debug', 30, 0),
  ('host1', 'aaa11111-2222-3333-4444-555566667777', strftime('%s','now','-5 days'), 60001, '/home/rob/docs', 'edit README.md', 120, 0),
  ('host1', 'aaa11111-2222-3333-4444-555566667777', strftime('%s','now','-15 days'), 60002, '/home/rob/src', 'edit main.lua', 60, 0),
  ('host1', 'bbb22222-3333-4444-5555-666677778888', strftime('%s','now','-50 days'), 60003, '/home/rob/src', 'edit init.lua', 90, 0);
