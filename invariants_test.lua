local json = require 'dkjson'

-- Invariants:
--
--   - WHERE clause invariants
--   - ORDER BY clause invariants
--     - ordering by a column should result in rows being ordered in a way consistent with the SQL spec
--   - LIMIT invariants
--     - exactly LIMIT rows should be present (assuming sufficient rows)
--   - ROWIDs are all unique

local SENTINULL = setmetatable({}, {__tostring = function() return 'NULL' end})

local function get_query_results(sql)
  sql = string.gsub(sql, '\n', ' ')

  local pipe <close> = assert(io.popen(string.format('./histdb -json %q', sql)))
  local res, err = json.decode(pipe:read 'a', 1, SENTINULL)
  assert(res, err)
  return res
end

local function keys(t)
  local res = {}

  for k in pairs(t) do
    res[#res + 1] = k
  end

  table.sort(res)
  return res
end

local function count_tuples(results)
  local counts = {}
  local columns = keys(results[1])

  for i = 1, #results do
    local row = results[i]

    local k = {}
    for j = 1, #columns do
      k[#k + 1] = tostring(row[columns[j]])
    end
    k = table.concat(k)

    counts[k] = (counts[k] or 0) + 1
  end

  return counts
end

local function assert_result_sets_match_unordered(results_a, results_b)
  local columns_a = keys(results_a[1])
  local columns_b = keys(results_b[1])

  -- verify that the column sets are the same
  assert(#columns_a == #columns_b, string.format('%q vs %q', table.concat(columns_a, ' '), table.concat(columns_b, ' ')))
  for i = 1, #columns_a do
    assert(columns_a[1] == columns_b[1])
  end

  local counts_a = count_tuples(results_a)
  local counts_b = count_tuples(results_b)

  for tuple, count_a in pairs(counts_a) do
    assert(counts_b[tuple], string.format('%q not present in result set B', tuple)) -- verify that all tuples in A are present in B

    local count_b = counts_b[tuple]
    assert(count_a == count_b) -- …and that their counts are the same
  end

  for tuple in pairs(counts_b) do
    assert(counts_a[tuple], string.format('%q not present in result set A', tuple)) -- verify that all tuples in B are present in A
  end
end

local function assert_result_sets_match_ordered(results_a, results_b)
  local columns_a = keys(results_a[1])
  local columns_b = keys(results_b[1])

  -- verify that the column sets are the same
  assert(#columns_a == #columns_b, string.format('%q vs %q', table.concat(columns_a, ' '), table.concat(columns_b, ' ')))
  for i = 1, #columns_a do
    assert(columns_a[1] == columns_b[1])
  end

  -- the number of rows in each should match
  assert(#results_a == #results_b, string.format('result set row count mismatch:\n  a: %d\n  b: %d', #results_a, #results_b))

  for row = 1, #results_a do
    local row_a = results_a[row]
    local row_b = results_b[row]

    for col = 1, #columns_a do
      local value_a = row_a[columns_a[col]]
      local value_b = row_b[columns_a[col]]

      if value_a ~= value_b then
        assert(value_a == value_b, string.format('values for %s in row %d do not match\n  a: %s\n  b: %s', columns_a[col], row, value_a, value_b))
      end
    end
  end
end

local invariants = {
  -- all rows with a valid timestamp should be present
  {
    direct_sql = [[SELECT DATETIME(timestamp, 'unixepoch', 'localtime') AS timestamp, entry FROM history WHERE TYPEOF(timestamp) = 'integer']],
    vtab_sql   = 'SELECT timestamp, entry FROM h',

    unordered = true,
  },

  -- ordering by timestamp should be the same
  {
    direct_sql = [[SELECT DATETIME(timestamp, 'unixepoch', 'localtime') AS timestamp, entry FROM history WHERE TYPEOF(timestamp) = 'integer' ORDER BY timestamp]],
    vtab_sql   = 'SELECT timestamp, entry FROM h ORDER BY timestamp',
  },

  -- ordering by COLUMN should be the same
  {
    vtab_sql = 'SELECT timestamp, entry FROM h ORDER BY session_id',
    direct_sql = [[
SELECT
  DATETIME(timestamp, 'unixepoch', 'localtime') AS timestamp,
  entry
FROM history
WHERE TYPEOF(timestamp) = 'integer'
ORDER BY session_id
    ]],
  },

  -- ordering by (timestamp, COLUMN) should be the same
  {
    vtab_sql = 'SELECT timestamp, entry FROM h ORDER BY timestamp, session_id',
    direct_sql = [[
SELECT
  DATETIME(timestamp, 'unixepoch', 'localtime') AS timestamp,
  entry
FROM history
WHERE TYPEOF(timestamp) = 'integer'
ORDER BY timestamp, session_id
    ]],
  },

  -- ordering by (COLUMN, timestamp) should be the same
  {
    vtab_sql = 'SELECT timestamp, entry FROM h ORDER BY session_id, timestamp',
    direct_sql = [[
SELECT
  DATETIME(timestamp, 'unixepoch', 'localtime') AS timestamp,
  entry
FROM history
WHERE TYPEOF(timestamp) = 'integer'

ORDER BY session_id, timestamp
    ]],
  },

  -- ordering by (COLUMN, timestamp, COLUMN) should be the same
  {
    vtab_sql = 'SELECT timestamp, entry FROM h ORDER BY session_id, timestamp, duration',
    direct_sql = [[
SELECT
  DATETIME(timestamp, 'unixepoch', 'localtime') AS timestamp,
  entry
FROM history
WHERE TYPEOF(timestamp) = 'integer'

ORDER BY session_id, timestamp, duration
    ]],
  },

  -- ordering by (COLUMN, COLUMN, timestamp) should be the same
  {
    vtab_sql = 'SELECT timestamp, entry FROM h ORDER BY session_id, duration, timestamp',
    direct_sql = [[
SELECT
  DATETIME(timestamp, 'unixepoch', 'localtime') AS timestamp,
  entry
FROM history
WHERE TYPEOF(timestamp) = 'integer'

ORDER BY session_id, duration, timestamp
    ]],
  },
}

-- when filtering by `timestamp IS NOT NULL`, each row should have a non-NULL timestamp column
do
  local results = get_query_results 'SELECT timestamp FROM h WHERE timestamp IS NOT NULL'
  for i = 1, #results do
    assert(results[i].timestamp ~= SENTINULL)
  end
end

-- rowids must all be unique
do
  local results = get_query_results 'SELECT rowid FROM h'
  local counts = count_tuples(results)
  for rowid, count in pairs(counts) do
    assert(count == 1, string.format('rowid %d appeared more than once', rowid))
  end
end

for i = 1, #invariants do
  local inv = invariants[i]

  local direct_results = get_query_results(inv.direct_sql)
  local vtab_results = get_query_results(inv.vtab_sql)

  if inv.unordered then
    assert_result_sets_match_unordered(direct_results, vtab_results)
  else
    assert_result_sets_match_ordered(direct_results, vtab_results)
  end
end
