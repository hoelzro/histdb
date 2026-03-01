#!/usr/bin/env lua5.4

-- snapshot-queries.lua: run each query from a JSONL query file against a
-- histdb database and produce a JSONL snapshot of results with timing.

local has_cjson, json = pcall(require, 'cjson')
if not has_cjson then
  json = require 'dkjson'
end

local ptime = require 'posix.time'
local pstdlib = require 'posix.stdlib'
local sqlite3 = require 'lsqlite3'

local QUERY_TIMEOUT_SECONDS = 60

local function monotime()
  local ts = ptime.clock_gettime(ptime.CLOCK_MONOTONIC)
  return ts.tv_sec + ts.tv_nsec * 1e-9
end

local db_path = arg[1]
local query_file = arg[2]

if not db_path or not query_file then
  io.stderr:write('Usage: snapshot-queries.lua <db-path> <query-file.jsonl>\n')
  os.exit(1)
end

-- file:// URI requires an absolute path
db_path = assert(pstdlib.realpath(db_path))

-- Open DB and set up virtual table
local db = sqlite3.open('file://' .. db_path .. '?immutable=true', sqlite3.OPEN_READONLY + sqlite3.OPEN_URI)
assert(db, 'failed to open database: ' .. db_path)
db:load_extension('./lua-vtable.so')
db:exec("SELECT lua_create_module_from_file('histdb.lua')")
db:exec('CREATE VIRTUAL TABLE temp.h USING h')

local start_time = nil
db:progress_handler(1000000, function()
  if monotime() - start_time > QUERY_TIMEOUT_SECONDS then
    db:interrupt()
  end
end)

local function get_query_results(sql)
  local rows = {}
  start_time = monotime()
  local stmt = db:prepare(sql)
  if not stmt then
    return nil, db:errmsg()
  end

  local names = stmt:get_names()
  while stmt:step() == sqlite3.ROW do
    local row = stmt:get_named_values()
    for i = 1, #names do
      if row[names[i]] == nil then
        row[names[i]] = json.null
      end
    end
    rows[#rows + 1] = row
  end
  stmt:finalize()

  if db:errcode() ~= sqlite3.OK and db:errcode() ~= sqlite3.DONE then
    return nil, db:errmsg()
  end
  return rows
end

-- Read queries from JSONL file
local queries = {}
local f = assert(io.open(query_file, 'r'))
for line in f:lines() do
  local sql = json.decode(line)
  if sql then
    queries[#queries + 1] = sql
  end
end
f:close()

if #queries == 0 then
  io.stderr:write('No queries found in query file\n')
  os.exit(1)
end

io.stderr:write(string.format('Running %d queries...\n', #queries))

for i, sql in ipairs(queries) do
  local t0 = monotime()
  local results, err = get_query_results(sql)
  local t1 = monotime()
  local elapsed_ms = (t1 - t0) * 1000

  local record
  if results then
    record = {
      query = sql,
      results = results,
      elapsed_ms = math.floor(elapsed_ms + 0.5),
    }
  else
    record = {
      query = sql,
      error = err,
      elapsed_ms = math.floor(elapsed_ms + 0.5),
    }
  end

  print(json.encode(record))
  io.stderr:write(string.format('  [%d/%d] %.0fms %s\n',
                                i, #queries, elapsed_ms,
                                results and string.format('(%d rows)', #results) or 'ERROR'))
end

db:close()
