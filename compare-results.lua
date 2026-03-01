#!/usr/bin/env lua5.4

-- compare-results.lua: compare query results between two snapshot JSONL files
-- produced by snapshot-queries.lua. Reports any queries where the result sets
-- differ between the two snapshots.

local has_cjson, json = pcall(require, 'cjson')
if not has_cjson then
  json = require 'dkjson'
end

local tointeger = math.tointeger

local path_a = arg[1]
local path_b = arg[2]

if not path_a or not path_b then
  io.stderr:write('Usage: compare-results.lua <snapshot-a.jsonl> <snapshot-b.jsonl>\n')
  os.exit(1)
end

local function load_snapshot(path)
  local records = {}
  local f = assert(io.open(path, 'r'))
  local line_no = 1
  for line in f:lines() do
    local rec = json.decode(line)
    if rec and rec.query then
      records[rec.query] = rec
    end
    if rec.results then
      for i = 1, #rec.results do
        local res = rec.results[i]
        if res.exit_status then
          res.exit_status = tointeger(res.exit_status)
        end
        if res.history_id then
          res.history_id = tointeger(res.history_id)
        end
      end
    end
    rec.line = line_no
    line_no = line_no + 1
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

local function sorted_result(results)
  local copy = {}
  for i, v in ipairs(results) do
    copy[i] = v
  end

  table.sort(copy, function(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then
      return tostring(a) < tostring(b)
    end

    local uniq_keys = {}
    for k in pairs(a) do
      uniq_keys[k] = true
    end
    for k in pairs(b) do
      uniq_keys[k] = true
    end

    local sorted_keys = {}
    for k in pairs(uniq_keys) do
      sorted_keys[#sorted_keys + 1] = k
    end
    table.sort(sorted_keys)

    for i = 1, #sorted_keys do
      local k = sorted_keys[i]

      local a_value, b_value = tostring(a[k]), tostring(b[k])
      if a_value ~= b_value then
        return a_value < b_value
      end
    end
    return false
  end)
  return copy
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
        -- Check whether the difference is only in ordering
        local sorted_a = sorted_result(a_res)
        local sorted_b = sorted_result(b_res)
        if deep_equal(sorted_a, sorted_b) then
          reason = string.format('same row count (%d), same content, ORDER DIFFERS', #a_res)
        else
          reason = string.format('same row count (%d) but content differs', #a_res)
        end
      end
    end

    if differs then
      diffs = diffs + 1
      print(string.format('[%d] DIFF: (lines %d and %d) %s', diffs, rec_a.line, rec_b.line, query))
      print(string.format('  %s', reason))
      if a_res and b_res then
        -- Show the first differing row as an example
        if #a_res ~= #b_res then
          -- Row count differs: show an extra row from the longer side
          if #a_res > #b_res then
            print(string.format('  example (extra row in A): %s', json.encode(a_res[#b_res + 1])))
          else
            print(string.format('  example (extra row in B): %s', json.encode(b_res[#a_res + 1])))
          end
        else
          -- Same count, find first row that differs
          for i = 1, #a_res do
            if not deep_equal(a_res[i], b_res[i]) then
              print(string.format('  example (row %d):', i))
              print(string.format('    A: %s', json.encode(a_res[i])))
              print(string.format('    B: %s', json.encode(b_res[i])))
              break
            end
          end
        end
      end
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
