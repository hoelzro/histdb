local sqlite3 = require 'lsqlite3'
local match_timestamps = require 'match_timestamps'

local session_id = os.getenv 'HISTDB_SESSION_ID'

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
  'h',
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
    today HIDDEN,
    h HIDDEN
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
  local order_by_consumed

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

  if #info.order_by > 0 then
    index_str = (index_str or '') .. '::'

    -- XXX guardrail - mostly in place to make sure I'm not being dumb about order_by_consumed, but also to make sure that my use of the columns over in the filter method is correct
    assert(#info.order_by == 1 and COLUMNS[info.order_by[1].column] == 'timestamp', 'ordering by more than one column, or a non-timestamp column, has yet to be implemented')
    order_by_consumed = true

    for i = 1, #info.order_by do
      local o = info.order_by[i]
      index_str = index_str .. string.format('%s-%s', COLUMNS[o.column], o.desc and 'desc' or 'asc')
    end
  end

  return {
    constraint_usage = constraint_usage,
    index_str = index_str,
    order_by_consumed = order_by_consumed,
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

local function cwd_match_expr(expr)
  -- XXX more powerful match language
  -- XXX string escaping
  return string.format("cwd LIKE '%%%s%%'", expr)
end

-- `h MATCH 'foo bar'` means that "foo" must be found between (entry, cwd) and "bar" must be found between (entry, cwd) - but they don't necessarily need to be in both
local function all_match_expr(expr)
  local conditions = {}
  for token in string.gmatch(expr, '(%S+)') do
    -- XXX duplication of entry_match_expr and cwd_match_expr logic :(
    conditions[#conditions+1] = "(entry LIKE '%" .. token .. "%' OR cwd LIKE '%" .. token .. "%')"
  end
  return '(' .. table.concat(conditions, ' AND ') .. ')'
end

local function template(tmpl, tmpl_vars)
  return string.gsub(tmpl, '«(.-)»', function(var)
    return assert(tmpl_vars[var], string.format('missing template variable %q', var))
  end)
end

function mod.filter(cursor, index_num, index_name, args)
  if cursor.debug then
    local pretty = require 'pretty'

    io.stderr:write(string.format('index num:  %d\n', index_num))
    io.stderr:write(string.format('index name: %s\n', index_name))
    pretty.print(args)
  end

  local first_table = 'history_before_today'
  local second_table = 'today_db.history'

  local where_clause = ''
  local order_by_clause = ''
  if index_name then
    -- index_name is built up within best_index above, and takes the form of ((column .. '-' .. position) .. ':')* .. ('::' order_column .. '-' .. order_direction)?
    local conditions = {}

    local constraints, ordering = string.match(index_name, '(.*)::(.*)')
    constraints = constraints or index_name

    for column, arg_pos in string.gmatch(constraints, '([^:]+)-(%d+)') do
      arg_pos = tonumber(arg_pos)

      if column == 'timestamp' then
        conditions[#conditions + 1] = timestamp_match_expr(args[arg_pos])
      elseif column == 'cwd' then
        conditions[#conditions + 1] = cwd_match_expr(args[arg_pos])
      elseif column == 'entry' then
        conditions[#conditions + 1] = entry_match_expr(args[arg_pos])
      elseif column == 'h' then
        conditions[#conditions + 1] = all_match_expr(args[arg_pos])
      end
    end

    if #conditions > 0 then
      where_clause = 'AND ' .. table.concat(conditions, ' AND ')
    end

    if ordering then
      if ordering == 'timestamp-asc' then
        order_by_clause = 'ORDER BY history.timestamp ASC'
      elseif ordering == 'timestamp-desc' then
        order_by_clause = 'ORDER BY history.timestamp DESC'

        -- XXX explain
        first_table = 'today_db.history'
        second_table = 'history_before_today'
      else
        error 'non-timestamp ordering not yet implemented - see guardrail in best_index method'
      end
    end
  end

  local max_before_today_rowid
  do
    local db = cursor.vtab.db
    local stmt = db:prepare 'SELECT MAX(rowid) FROM history_before_today'
    if not stmt then
      return nil, db:errmsg()
    end

    local status = stmt:step()
    if status ~= sqlite3.ROW then
      return nil, db:errmsg()
    end

    max_before_today_rowid = stmt:get_value(0)
    if stmt:finalize() ~= sqlite3.OK then
      return nil, db:errmsg()
    end
  end

  local sql = template([[
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
      DATE(timestamp, 'unixepoch', 'localtime') = DATE('now', 'localtime') AS today,
      1 AS h
    FROM (
      SELECT * FROM (SELECT «first_table_rowid», * FROM «first_table» AS history WHERE session_id <> :session_id «where_clause» «order_by_clause»)
      UNION ALL
      SELECT * FROM (SELECT «second_table_rowid», * FROM «second_table» AS history WHERE session_id <> :session_id «where_clause» «order_by_clause»)
    ) AS history
    WHERE timestamp IS NOT NULL AND TYPEOF(timestamp) = 'integer'
  ]], {
    first_table     = first_table,
    second_table    = second_table,
    where_clause    = where_clause,
    order_by_clause = order_by_clause,

    first_table_rowid  = first_table == 'history_before_today' and 'rowid' or string.format('rowid + %d AS rowid', max_before_today_rowid),
    second_table_rowid = second_table == 'history_before_today' and 'rowid' or string.format('rowid + %d AS rowid', max_before_today_rowid),
  })

  if cursor.debug then
    io.stderr:write(sql .. '\n')
  end

  local stmt = cursor.vtab.db:prepare(sql)

  if not stmt then
    return nil, cursor.vtab.db:errmsg()
  end

  stmt:bind_names {
    session_id = tostring(session_id),
  }

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
