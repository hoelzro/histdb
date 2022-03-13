local sqlite3 = require 'lsqlite3'

local mod = {
  name = 'h',
  disconnect = function() end,
  destroy = function() end,
}

function mod.connect(db, args)
  local debug = false

  for i = 4, #args do
    if args[i] == 'debug' then
      debug = true
    end
  end

  db:declare_vtab [[CREATE TABLE _ (
    hostname,
    session_id, -- shell PID
    timestamp integer not null,
    history_id, -- $HISTCMD
    cwd,
    entry,
    duration,
    exit_status
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

  return {
    constraint_usage = {},
  }
end

function mod.open(vtab)
  -- XXX shouldn't this be in filter?
  local stmt = vtab.db:prepare 'SELECT rowid, * FROM history'
  return {
    debug = vtab.debug,
    stmt = stmt,
    last_status = sqlite3.ROW,
  }
end

function mod.close(cursor)
  cursor.stmt:finalize()
end

function mod.filter(cursor, index_num, index_name, args)
  if cursor.debug then
    local pretty = require 'pretty'

    io.stderr:write(string.format('index num:  %d\n', index_num))
    io.stderr:write(string.format('index name: %s\n', index_name))
    pretty.print(args)
  end

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

function mod.find_function(vtab, argc, name)
  io.stderr:write(string.format('find function: %s/%d', name, argc))
end

return mod
