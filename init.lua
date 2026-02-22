local sqlite3 = require 'lsqlite3'
local match_timestamps = require 'match_timestamps'

local session_id = os.getenv 'HISTDB_SESSION_ID'

local mod = {
  name = 'h',
  disconnect = function() end,
  destroy = function() end,
}

local function add_param(params, value)
  params[#params + 1] = value
  return ':param' .. tostring(#params)
end

local function timestamp_match_expr(context, op, params, expr)
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

local function entry_match_expr(context, op, params, expr)
  local conditions = {}
  for token in string.gmatch(expr, '(%S+)') do
    local placeholder = add_param(params, '%' .. token .. '%')
    conditions[#conditions+1] = 'entry LIKE ' .. placeholder
  end

  if #conditions > 0 then
    return '(' .. table.concat(conditions, ' AND ') .. ')'
  end
end

local function cwd_match_expr(context, op, params, expr)
  -- XXX more powerful match language
  return 'cwd LIKE ' .. add_param(params, '%' .. expr .. '%')
end

-- `h MATCH 'foo bar'` means that "foo" must be found between (entry, cwd) and "bar" must be found between (entry, cwd) - but they don't necessarily need to be in both
local function all_match_expr(context, op, params, expr)
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

local function simple_expr(expr)
  return function(context, op, params, arg)
    if context == 'select' then
      return expr
    elseif context == 'where' then
      if arg then
        return string.format('%s %s %s', expr, op, add_param(params, arg))
      else
        return string.format('%s %s', expr, op)
      end
    end
  end
end

local function with_match(wrapped_fn, match_fn)
  return function(...)
    local context, op = ...
    if context == 'where' and op == 'match' then
      return match_fn(...)
    else
      return wrapped_fn(...)
    end
  end
end

local SCHEMA = {
  {
    name   = 'hostname',
    hidden = true,
  },
  {
    name = 'session_id',
    type = 'TEXT',
    expr = simple_expr 'CAST(session_id AS TEXT)',
  },
  {
    name = 'timestamp',
    type = 'TEXT NOT NULL',
    expr = with_match(simple_expr "DATETIME(timestamp, 'unixepoch', 'localtime')", timestamp_match_expr),
  },
  {
    name   = 'raw_timestamp',
    type   = 'INTEGER NOT NULL',
    hidden = true,
    expr   = simple_expr 'timestamp',
  },
  {
    name   = 'history_id',
    hidden = true,
  },
  {
    name = 'cwd',
    expr = with_match(simple_expr 'cwd', cwd_match_expr),
  },
  {
    name = 'entry',
    expr = with_match(simple_expr 'entry', entry_match_expr),
  },
  {
    name   = 'duration',
    hidden = true,
  },
  {
    name   = 'exit_status',
    hidden = true,
  },
  {
    name   = 'yesterday',
    hidden = true,
    expr   = simple_expr "DATE(timestamp, 'unixepoch', 'localtime') = DATE('now', '-1 days', 'localtime')",
  },
  {
    name   = 'today',
    hidden = true,
    expr   = simple_expr "DATE(timestamp, 'unixepoch', 'localtime') = DATE('now', 'localtime')",
  },
  {
    name   = 'h',
    hidden = true,
    expr   = function(context, op, params, arg)
      if context == 'select' then
        return '1'
      elseif context == 'where' then
        if op == 'match' then
          return all_match_expr(context, op, params, arg)
        end

        if arg then
          local param = add_param(params, arg)
          return string.format('(entry %s %s OR cwd %s %s)', op, param, op, param)
        else
          return string.format('(entry %s OR cwd %s)', op, op)
        end
      end
    end,
  },
}

for i = 1, #SCHEMA do
  local column = SCHEMA[i]

  -- build a reverse mapping, so we can address columns by index or by name
  SCHEMA[column.name] = column

  -- default expr to just use the underlying column of the same name
  if not column.expr then
    column.expr = simple_expr(column.name)
  end
end

function mod.connect(db, args)
  local debug = false

  for i = 4, #args do
    if args[i] == 'debug' then
      debug = true
    end
  end

  local columns = {}
  for i = 1, #SCHEMA do
    local column = SCHEMA[i]
    columns[#columns + 1] = string.format('%s %s %s', column.name, column.hidden and 'HIDDEN' or '', column.type)
  end

  local create_table = 'CREATE TABLE _ (\n' .. table.concat(columns, ',\n') .. '\n)'
  assert(db:declare_vtab(create_table))

  return {
    db = sqlite3.open_ptr(db:get_ptr()),
    debug = debug,
  }
end

mod.create = mod.connect

local COMPARISON_OPERATOR_ARITY = {
  ['=']           = 'binary',
  ['<>']          = 'binary',
  ['>']           = 'binary',
  ['>=']          = 'binary',
  ['<']           = 'binary',
  ['<=']          = 'binary',
  ['is']          = 'binary',
  ['is not']      = 'binary',
  ['is null']     = 'unary',
  ['is not null'] = 'unary',
  ['like']        = 'binary',
  ['match']       = 'binary',
}

-- this builds up a serialized list of hints to be used by the filter method below - more details there
function mod.best_index(vtab, info)
  if vtab.debug then
    local pretty = require 'pretty'
    pretty.print(info)
  end

  local constraint_usage = {}
  local index_str_pieces = {}
  local _next_argv = 1
  local order_by_consumed

  local function next_argv(cu)
    cu.argv_index = _next_argv
    _next_argv = _next_argv + 1
    return cu.argv_index
  end

  for i = 1, #info.constraints do
    local c = info.constraints[i]
    local cu = { omit = true }

    if not c.usable then
      goto continue
    end

    if COMPARISON_OPERATOR_ARITY[c.op] == 'unary' then
      -- XXX make sure c.column is a comparable column
      index_str_pieces[#index_str_pieces + 1] = string.format('constraint:%s:%s:%d', c.op, SCHEMA[c.column + 1].name, 0)
    elseif COMPARISON_OPERATOR_ARITY[c.op] == 'binary' then
      -- XXX make sure c.column is a comparable column
      index_str_pieces[#index_str_pieces + 1] = string.format('constraint:%s:%s:%d', c.op, SCHEMA[c.column + 1].name, next_argv(cu))
    elseif c.op == 'limit' or c.op == 'offset' then
      index_str_pieces[#index_str_pieces + 1] = string.format('%s:%d', c.op, next_argv(cu))
    else
      goto continue
    end

    constraint_usage[i] = cu

    ::continue::
  end


  if #info.order_by > 0 then
    order_by_consumed = true

    for i = 1, #info.order_by do
      local o = info.order_by[i]
      index_str_pieces[#index_str_pieces + 1] = string.format('order:%s:%s', SCHEMA[o.column + 1].name, o.desc and 'DESC' or 'ASC')
    end
  end

  return {
    constraint_usage = constraint_usage,
    index_str = #index_str_pieces > 0 and table.concat(index_str_pieces, ';') or nil,
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
  local limit_clause = ''
  local offset_clause = ''
  local params = {}

  if index_name then
    --  index_name is built up within best_index above, and is composed of semicolon-separated hints.  Each hint is composed of a hint type and that hint's arguments, separated by colons
    local where_pieces = {}
    local order_by_pieces = {}

    for hint in string.gmatch(index_name, '[^;]+') do
      local hint_type, hint_args = string.match(hint, '(%a+):(.*)')
      if hint_type == 'constraint' then
        local constraint_op, column, arg_pos = string.match(hint_args, '(.+):(.+):(%d+)')
        arg_pos = tonumber(arg_pos)

        if COMPARISON_OPERATOR_ARITY[constraint_op] then
          if arg_pos ~= 0 then
            where_pieces[#where_pieces + 1] = SCHEMA[column].expr('where', constraint_op, params, args[arg_pos])
          else
            where_pieces[#where_pieces + 1] = SCHEMA[column].expr('where', constraint_op)
          end
        else
          error(string.format('constraint op %q NYI (hint = %q)', constraint_op, hint))
        end
      elseif hint_type == 'order' then
        local column, dir = string.match(hint_args, '(.+):(.+)')

        order_by_pieces[#order_by_pieces + 1] = string.format('history.%s %s', column, dir)
      elseif hint_type == 'limit' then
        local arg_pos = tonumber(hint_args)

        limit_clause = 'LIMIT ' .. args[arg_pos]
      elseif hint_type == 'offset' then
        local arg_pos = tonumber(hint_args)

        offset_clause = 'OFFSET ' .. args[arg_pos]
      else
        error(string.format('unrecognized hint type %q', hint_type))
      end
    end

    if #where_pieces > 0 then
      where_clause = 'AND ' .. table.concat(where_pieces, ' AND ')
    end

    if #order_by_pieces > 0 then
      order_by_clause = 'ORDER BY ' .. table.concat(order_by_pieces, ', ')
    end
  end

  local fields = {'rowid'}

  for i = 1, #SCHEMA do
    local column = SCHEMA[i]
    local select_expr = column.expr 'select'

    if select_expr ~= column.name then
      fields[#fields + 1] = string.format('%s AS %s', select_expr, SCHEMA[i].name)
    else
      fields[#fields + 1] = SCHEMA[i].name
    end
  end

  local template_sql = 'SELECT\n' .. table.concat(fields, ',\n') .. [[
    FROM history
    WHERE session_id <> :session_id AND timestamp IS NOT NULL AND TYPEOF(timestamp) = 'integer'
    «where_clause»
    «order_by_clause»
    «limit_clause»
    «offset_clause»
  ]]

  local sql = template(template_sql, {
    where_clause    = where_clause,
    order_by_clause = order_by_clause,
    limit_clause    = limit_clause,
    offset_clause   = offset_clause,
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
