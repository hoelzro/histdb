#!/usr/bin/env lua5.4

-- compare-timing.lua: find queries that got meaningfully slower between two
-- snapshot JSONL files produced by snapshot-queries.lua.
--
-- A query is flagged as a regression if it is BOTH:
--   - more than --pct percent slower (default 20)
--   - more than --ms milliseconds slower in absolute terms (default 50)

local json = require 'dkjson'

-- Parse CLI args
local path_a, path_b
local threshold_pct = 20
local threshold_ms = 50

local i = 1
while i <= #arg do
  if arg[i] == '--pct' then
    i = i + 1
    threshold_pct = assert(tonumber(arg[i]), '--pct requires a number')
  elseif arg[i] == '--ms' then
    i = i + 1
    threshold_ms = assert(tonumber(arg[i]), '--ms requires a number')
  elseif not path_a then
    path_a = arg[i]
  elseif not path_b then
    path_b = arg[i]
  else
    io.stderr:write('Unexpected argument: ' .. arg[i] .. '\n')
    os.exit(1)
  end
  i = i + 1
end

if not path_a or not path_b then
  io.stderr:write('Usage: compare-timing.lua [--pct N] [--ms N] <before.jsonl> <after.jsonl>\n')
  io.stderr:write('\nFlags:\n')
  io.stderr:write('  --pct N   minimum percent slower to flag (default 20)\n')
  io.stderr:write('  --ms  N   minimum absolute ms increase to flag (default 50)\n')
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

local snap_a = load_snapshot(path_a)
local snap_b = load_snapshot(path_b)

-- Only compare queries present in both snapshots with valid timings
local regressions = {}

for query, rec_a in pairs(snap_a) do
  local rec_b = snap_b[query]
  if rec_b and rec_a.elapsed_ms and rec_b.elapsed_ms then
    local ms_a = rec_a.elapsed_ms
    local ms_b = rec_b.elapsed_ms
    local abs_diff = ms_b - ms_a
    local pct_diff = ms_a > 0 and (abs_diff / ms_a * 100) or (ms_b > 0 and math.huge or 0)

    if abs_diff > threshold_ms and pct_diff > threshold_pct then
      regressions[#regressions + 1] = {
        query = query,
        ms_a = ms_a,
        ms_b = ms_b,
        abs_diff = abs_diff,
        pct_diff = pct_diff,
      }
    end
  end
end

-- Sort by absolute regression, worst first
table.sort(regressions, function(a, b) return a.abs_diff > b.abs_diff end)

io.stderr:write(string.format('Thresholds: >%d%% AND >%dms\n', threshold_pct, threshold_ms))
io.stderr:write(string.format('Queries compared: %d\n', (function()
  local n = 0
  for q in pairs(snap_a) do if snap_b[q] then n = n + 1 end end
  return n
end)()))

if #regressions == 0 then
  io.stderr:write('No regressions found.\n')
else
  io.stderr:write(string.format('%d regression(s) found:\n\n', #regressions))
  for i, r in ipairs(regressions) do
    print(string.format('[%d] %s', i, r.query))
    print(string.format('  %dms -> %dms  (+%dms, +%.0f%%)', r.ms_a, r.ms_b, r.abs_diff, r.pct_diff))
    print()
  end
end
