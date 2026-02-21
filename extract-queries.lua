#!/usr/bin/env lua5.4

-- extract-queries.lua: scan histdb history for histdb invocations
-- and extract the SQL queries from them.

local json = require 'dkjson'
local sqlite3 = require 'lsqlite3'

local db_path = os.getenv('HISTDB_PATH') or (os.getenv('HOME') .. '/.zsh_history.db')

local function parse_sql_from_histdb_command(entry)
  local sql = entry:match('"([^"]+)"%s*$') or entry:match("'([^']+)'%s*$")
  if not sql then return nil end
  if not sql:lower():match('^%s*select') then return nil end
  return sql
end

local function extract_queries()
  local db = sqlite3.open('file://' .. db_path .. '?immutable=true', sqlite3.OPEN_READONLY + sqlite3.OPEN_URI)
  assert(db, 'failed to open database: ' .. db_path)

  local queries = {}
  local seen = {}

  for row in db:nrows("SELECT entry FROM history WHERE entry LIKE 'histdb %'") do
    local sql = parse_sql_from_histdb_command(row.entry)
    if sql and not seen[sql] then
      seen[sql] = true
      queries[#queries + 1] = sql
    end
  end

  db:close()

  table.sort(queries)
  return queries
end

-- Main
local queries = extract_queries()

if #queries == 0 then
  io.stderr:write('No histdb queries found\n')
  os.exit(1)
end

io.stderr:write(string.format('Found %d distinct queries\n', #queries))

for _, sql in ipairs(queries) do
  print(json.encode(sql))
end
