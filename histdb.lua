local mod = { name = 'h' }

function mod.connect(db, args)
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

  return {}
end

function mod.best_index()
  return {
    constraint_usage = {},
  }
end

function mod.open(vtab)
  return {}
end

function mod.close(cursor)
end

function mod.filter(cursor)
end

function mod.eof(cursor)
end

function mod.column(cursor, n)
end

function mod.next(cursor)
end

function mod.rowid(cursor)
end

return mod
