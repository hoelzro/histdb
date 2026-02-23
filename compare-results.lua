#!/usr/bin/env lua5.4

-- compare-results.lua: compare query results between two snapshot JSONL files
-- produced by snapshot-queries.lua. Reports any queries where the result sets
-- differ between the two snapshots.

local json = require 'dkjson'

local path_a = arg[1]
local path_b = arg[2]

if not path_a or not path_b then
  io.stderr:write('Usage: compare-results.lua <snapshot-a.jsonl> <snapshot-b.jsonl>\n')
  os.exit(1)
end

local function load_snapshot(path)
  local records = {}
  local f = assert(io.open(path, 'r'))
  for line in f:lines() do
    local rec = json.decode(line)
    if rec and rec.query then
      records[rec.query] = rec
    end
  end
  f:close()
  return records
end

-- Deep equality for JSON-like values (tables, strings, numbers, booleans, nil).
local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end

  -- Check same set of keys
  for k in pairs(a) do
    if not deep_equal(a[k], b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local snap_a = load_snapshot(path_a)
local snap_b = load_snapshot(path_b)

-- Collect all queries from both snapshots
local all_queries = {}
local seen = {}
for q in pairs(snap_a) do
  if not seen[q] then seen[q] = true; all_queries[#all_queries + 1] = q end
end
for q in pairs(snap_b) do
  if not seen[q] then seen[q] = true; all_queries[#all_queries + 1] = q end
end
table.sort(all_queries)

local diffs = 0

for _, query in ipairs(all_queries) do
  local rec_a = snap_a[query]
  local rec_b = snap_b[query]

  if not rec_a then
    diffs = diffs + 1
    io.stderr:write(string.format('[%d] ONLY IN B: %s\n', diffs, query))
  elseif not rec_b then
    diffs = diffs + 1
    io.stderr:write(string.format('[%d] ONLY IN A: %s\n', diffs, query))
  else
    local a_err = rec_a.error
    local b_err = rec_b.error
    local a_res = rec_a.results
    local b_res = rec_b.results

    local differs = false
    local reason

    if a_err and b_err then
      if a_err ~= b_err then
        differs = true
        reason = string.format('error changed: %q -> %q', a_err, b_err)
      end
    elseif a_err then
      differs = true
      reason = string.format('A errored (%q), B returned %d rows', a_err, #b_res)
    elseif b_err then
      differs = true
      reason = string.format('A returned %d rows, B errored (%q)', #a_res, b_err)
    elseif not deep_equal(a_res, b_res) then
      differs = true
      reason = string.format('row count: %d -> %d', #a_res, #b_res)
      if #a_res == #b_res then
        reason = string.format('same row count (%d) but content differs', #a_res)
      end
    end

    if differs then
      diffs = diffs + 1
      print(string.format('[%d] DIFF: %s', diffs, query))
      print(string.format('  %s', reason))
      print()
    end
  end
end

if diffs == 0 then
  io.stderr:write('All query results match.\n')
else
  io.stderr:write(string.format('\n%d difference(s) found.\n', diffs))
  os.exit(1)
end
