local sqlite3 = require 'lsqlite3'
local match_timestamps = require 'match_timestamps'

local session_id

do
  local this_pid = 'self'
  while this_pid ~= '1' do
    local proc_stat = assert(io.open('/proc/' .. this_pid .. '/stat', 'r'))
    local line = proc_stat:read '*l'
    proc_stat:close()

    local pid, comm, parent_pid = string.match(line, "^(%d+)%s+%(([^)]+)%)%s+%S%s+(%d+)")

    if comm ~= 'histdb' and comm ~= 'sqlite3' then
      session_id = tonumber(pid)
      break
    end

    this_pid = parent_pid
  end
end

local mod = {
  name = 'h',
  disconnect = function() end,
  destroy = function() end,
}

local COLUMNS = {
  [0] = 'hostname',
  'session_id',
  'timestamp',
  'history_id',
  'cwd',
  'entry',
  'duration',
  'exit_status',
  'yesterday',
  'today',
}

function mod.connect(db, args)
  local debug = false

  for i = 4, #args do
    if args[i] == 'debug' then
      debug = true
    end
  end

  db:declare_vtab [[CREATE TABLE _ (
    hostname HIDDEN,
    session_id TEXT, -- shell PID
    timestamp text not null,
    history_id HIDDEN, -- $HISTCMD
    cwd,
    entry,
    duration HIDDEN,
    exit_status HIDDEN,

    yesterday hidden,
    today hidden
  )
  ]]

  return {
    db = sqlite3.open_ptr(db:get_ptr()),
    debug = debug,
  }
end

mod.create = mod.connect

function mod.best_index(vtab, info)
  if vtab.debug then
    local pretty = require 'pretty'
    pretty.print(info)
  end

  local constraint_usage = {}
  local index_str
  local next_argv = 1

  for i = 1, #info.constraints do
    local c = info.constraints[i]
    local cu = {}

    if c.usable and c.op == 'match' then
      -- XXX make sure c.column is a matchable column
      index_str = index_str or {}
      index_str[#index_str + 1] = string.format('%s-%d', COLUMNS[c.column], next_argv)

      cu.argv_index = next_argv
      next_argv = next_argv + 1
      cu.omit = true
    end

    constraint_usage[i] = cu
  end

  if index_str then
    index_str = table.concat(index_str, ':')
  end

  return {
    constraint_usage = constraint_usage,
    index_str = index_str,
  }
end

function mod.open(vtab)
  return {
    vtab = vtab,
    debug = vtab.debug,
    last_status = sqlite3.ROW,
  }
end

function mod.close(cursor)
  cursor.stmt:finalize()
end

local function timestamp_match_expr(expr)
  -- MATCH 'since yesterday'
  -- MATCH 'since last week'
  -- MATCH 'on 2022-03-01'
  -- MATCH 'between 2022-03-01 and 2022-03-02'
  -- XXX is "last week" one week ago today, or last Sunday, etc?
  -- XXX does "yesterday" include an event from 00:15:00 this morning?
  -- searching by a specific time
  local start_time, end_time = assert(match_timestamps.resolve({}, expr))
  return string.format("timestamp BETWEEN %d AND %d", start_time, end_time)
end

local function entry_match_expr(expr)
  local conditions = {}
  for token in string.gmatch(expr, '(%S+)') do
    conditions[#conditions+1] = "entry LIKE '%" .. token .. "%'"
  end
  return '(' .. table.concat(conditions, ' AND ') .. ')'
end

function mod.filter(cursor, index_num, index_name, args)
  if cursor.debug then
    local pretty = require 'pretty'

    io.stderr:write(string.format('index num:  %d\n', index_num))
    io.stderr:write(string.format('index name: %s\n', index_name))
    pretty.print(args)
  end

  local where_clause = ''
  if index_name then
    local conditions = {}

    for column, arg_pos in string.gmatch(index_name, '([^:]+)-(%d+)') do
      arg_pos = tonumber(arg_pos)

      if column == 'timestamp' then
        conditions[#conditions + 1] = timestamp_match_expr(args[arg_pos])
      elseif column == 'cwd' then
        error 'nyi'
      elseif column == 'entry' then
        conditions[#conditions + 1] = entry_match_expr(args[arg_pos])
      end
    end

    if #conditions > 0 then
      where_clause = 'AND ' .. table.concat(conditions, ' AND ')
    end
  end

  local stmt = cursor.vtab.db:prepare([[
    SELECT
      rowid,
      hostname,
      session_id,
      DATETIME(timestamp, 'unixepoch', 'localtime') AS timestamp,
      history_id,
      cwd,
      entry,
      duration,
      exit_status,
      DATE(timestamp, 'unixepoch', 'localtime') = DATE('now', '-1 days', 'localtime') AS yesterday,
      DATE(timestamp, 'unixepoch', 'localtime') = DATE('now', 'localtime') AS today
    FROM history
    WHERE session_id <> ?
  ]] .. where_clause)

  if not stmt then
    return nil, cursor.vtab.db:errmsg()
  end

  stmt:bind_values(tostring(session_id))

  cursor.stmt = stmt

  return mod.next(cursor)
end

function mod.eof(cursor)
  if cursor.debug then
    return true
  end

  return cursor.last_status ~= sqlite3.ROW and cursor.last_status ~= sqlite3.BUSY
end

function mod.column(cursor, n)
  return cursor.stmt:get_value(n + 1)
end

function mod.next(cursor)
  local status = cursor.stmt:step()
  cursor.last_status = status
  if status == sqlite3.ERROR or status == sqlite3.MISUSE then
    return nil, 'error stepping'
  end
end

function mod.rowid(cursor)
  return cursor.stmt:get_value(0)
end

return mod
