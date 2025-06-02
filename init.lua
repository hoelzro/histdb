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
  'raw_timestamp',
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

  -- XXX inspect the schema for main.history and use that?
  db:declare_vtab [[CREATE TABLE _ (
    hostname HIDDEN,
    session_id TEXT, -- shell PID
    timestamp text not null,
    raw_timestamp HIDDEN integer not null,
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
    order_by_consumed = true

    local order_by_pieces = {}

    for i = 1, #info.order_by do
      local o = info.order_by[i]
      order_by_pieces[#order_by_pieces + 1] = string.format('%s-%s', COLUMNS[o.column], o.desc and 'DESC' or 'ASC')
    end
    index_str = (index_str or '') .. '::' .. table.concat(order_by_pieces, ':')
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

local function add_param(params, value)
  params[#params + 1] = value
  return ':param' .. tostring(#params)
end

local function timestamp_match_expr(expr, params)
  -- MATCH 'since yesterday'
  -- MATCH 'since last week'
  -- MATCH 'on 2022-03-01'
  -- MATCH 'between 2022-03-01 and 2022-03-02'
  -- XXX is "last week" one week ago today, or last Sunday, etc?
  -- XXX does "yesterday" include an event from 00:15:00 this morning?
  -- searching by a specific time
  local start_time, end_time = assert(match_timestamps.resolve({}, expr))
  return string.format("timestamp BETWEEN %s AND %s", add_param(params, start_time), add_param(params, end_time))
end

local function entry_match_expr(expr, params)
  local conditions = {}
  for token in string.gmatch(expr, '(%S+)') do
    local placeholder = add_param(params, '%' .. token .. '%')
    conditions[#conditions+1] = 'entry LIKE ' .. placeholder
  end

  if #conditions > 0 then
    return '(' .. table.concat(conditions, ' AND ') .. ')'
  end
end

local function cwd_match_expr(expr, params)
  -- XXX more powerful match language
  return 'cwd LIKE ' .. add_param(params, '%' .. expr .. '%')
end

-- `h MATCH 'foo bar'` means that "foo" must be found between (entry, cwd) and "bar" must be found between (entry, cwd) - but they don't necessarily need to be in both
local function all_match_expr(expr, params)
  local conditions = {}
  for token in string.gmatch(expr, '(%S+)') do
    local placeholder = add_param(params, '%' .. token .. '%')
    -- XXX duplication of entry_match_expr and cwd_match_expr logic :(
    conditions[#conditions+1] = string.format('(entry LIKE %s OR cwd LIKE %s)', placeholder, placeholder)
  end

  if #conditions > 0 then
    return '(' .. table.concat(conditions, ' AND ') .. ')'
  end
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

  local where_clause = ''
  local order_by_clause = ''
  local params = {}

  if index_name then
    -- index_name is built up within best_index above, and takes the form of ((column .. '-' .. position) .. ':')* .. ('::' order_column .. '-' .. order_direction)?
    local conditions = {}

    local constraints, ordering = string.match(index_name, '(.*)::(.*)')
    constraints = constraints or index_name

    for column, arg_pos in string.gmatch(constraints, '([^:]+)-(%d+)') do
      arg_pos = tonumber(arg_pos)

      if column == 'timestamp' then
        conditions[#conditions + 1] = timestamp_match_expr(args[arg_pos], params)
      elseif column == 'cwd' then
        conditions[#conditions + 1] = cwd_match_expr(args[arg_pos], params)
      elseif column == 'entry' then
        conditions[#conditions + 1] = entry_match_expr(args[arg_pos], params)
      elseif column == 'h' then
        conditions[#conditions + 1] = all_match_expr(args[arg_pos], params)
      end
    end

    if #conditions > 0 then
      where_clause = 'AND ' .. table.concat(conditions, ' AND ')
    end

    if ordering then
      local order_by_pieces = {}
      for column, dir in string.gmatch(ordering, '([^:]+)-([^:]+)') do
        order_by_pieces[#order_by_pieces + 1] = string.format('history.%s %s', column, dir)
      end
      order_by_clause = 'ORDER BY ' .. table.concat(order_by_pieces, ', ')
    end
  end

  local sql = template([[
    SELECT
      rowid,
      hostname,
      session_id,
      DATETIME(timestamp, 'unixepoch', 'localtime') AS timestamp,
      timestamp AS raw_timestamp,
      history_id,
      cwd,
      entry,
      duration,
      exit_status,
      DATE(timestamp, 'unixepoch', 'localtime') = DATE('now', '-1 days', 'localtime') AS yesterday,
      DATE(timestamp, 'unixepoch', 'localtime') = DATE('now', 'localtime') AS today,
      1 AS h
    FROM history
    WHERE session_id <> :session_id AND timestamp IS NOT NULL AND TYPEOF(timestamp) = 'integer'
    «where_clause»
    «order_by_clause»
  ]], {
    where_clause    = where_clause,
    order_by_clause = order_by_clause,
  })

  if cursor.debug then
    io.stderr:write(sql .. '\n')
  end

  local stmt = cursor.vtab.db:prepare(sql)

  if not stmt then
    return nil, cursor.vtab.db:errmsg()
  end

  local bindings = {
    session_id = tostring(session_id),
  }

  for i = 1, #params do
    bindings['param' .. tostring(i)] = params[i]
  end

  stmt:bind_names(bindings)

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
