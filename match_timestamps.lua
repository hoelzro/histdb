local lpeg = require 'lpeg'
local mod = {}

local ws = lpeg.S(' \t')^1

local NORMALIZED_UNITS = {
  d     = 'day',
  days  = 'day',
  w     = 'week',
  weeks = 'week',
}

local UNIT_TO_SECONDS = {
  day  = 60 * 60 * 24,
  week = 60 * 60 * 24 * 7,
}

local function relative_date(values)
  local unit = NORMALIZED_UNITS[values.unit] or values.unit
  return {
    type      = 'relative',
    unit      = unit,
    magnitude = values.magnitude,
  }
end

local function compose(f, g)
  return function(...)
    return f(g(...))
  end
end

local function mult_neg1(n)
  return n * -1
end

-- XXX handle case sensitivity
-- XXX how do we handle remaining input if we're capturing? (lpeg.Cp, * -1)
local grammar = lpeg.P {
  'top',

  top = lpeg.Ct(lpeg.V 'unary_expr' + lpeg.V 'between_expr'),

  unary_expr = (lpeg.Cg(lpeg.V('unary_operator'), 'operator') * ws)^-1 * lpeg.Cg(lpeg.Ct(lpeg.V 'datetime'), 'operand'),
  between_expr = lpeg.Cg(lpeg.P 'between', 'operator') * ws * lpeg.Cg(lpeg.Ct(lpeg.V 'datetime'), 'lhs') * ws * lpeg.P 'and' * ws * lpeg.Cg(lpeg.Ct(lpeg.V 'datetime'), 'rhs'),

  unary_operator = lpeg.P 'since' + lpeg.P 'on',

  datetime = (lpeg.V 'date' * (ws * lpeg.V('time'))^-1) + lpeg.V 'time',
  date = lpeg.Cg(lpeg.P 'yesterday' * lpeg.Cc(relative_date{unit = 'day', magnitude = -1}) + lpeg.P 'today' * lpeg.Cc(relative_date{unit = 'day', magnitude = 0}) + lpeg.V 'relative_date' + lpeg.V 'absolute_date', 'date'),
  relative_date = lpeg.Ct(lpeg.Cg(lpeg.V 'positive_number' / compose(mult_neg1, tonumber), 'magnitude') * ws * lpeg.Cg(lpeg.V 'date_unit', 'unit') * ws * lpeg.P 'ago') / relative_date +
             lpeg.Ct(lpeg.Cg(lpeg.V 'positive_number' / compose(mult_neg1, tonumber), 'magnitude') * lpeg.Cg(lpeg.S 'dw', 'unit') * ws * lpeg.P 'ago') / relative_date +
             lpeg.Ct(lpeg.Cg(lpeg.V 'negative_number' / tonumber, 'magnitude') * ws * lpeg.Cg(lpeg.V 'date_unit', 'unit')) / relative_date,
             (lpeg.V 'negative_number' * lpeg.S 'dw'),
  absolute_date = lpeg.Ct(lpeg.Cg(lpeg.R('09')^4 / tonumber, 'year') * lpeg.P '-' * lpeg.Cg(lpeg.R('09')^2 / tonumber, 'month') * lpeg.P '-' * lpeg.Cg(lpeg.R('09')^2 / tonumber, 'day') * lpeg.Cg(lpeg.Cc 'absolute', 'type')) +
                  lpeg.Ct(lpeg.Cg(lpeg.R('09')^2 / tonumber, 'month') * lpeg.P '-' * lpeg.Cg(lpeg.R('09')^2 / tonumber, 'day') * lpeg.Cg(lpeg.Cc 'absolute', 'type')),
  positive_number = lpeg.R('09')^1,
  negative_number = lpeg.P '-' * lpeg.R('09')^1,
  date_unit = lpeg.P 'days' + lpeg.P 'day' + lpeg.P 'weeks' + lpeg.P 'week',
  time = lpeg.P 'now', -- XXX placeholder
}

-- @param expr RHS of MATCH
function mod.parse(expr)
  local captures = grammar:match(expr)
  if captures then
    captures.operator = captures.operator or 'on'
  end

  return captures
end

-- @param config specifies things like current timezone, timezone overrides, beginning of week, end of subjective day
-- @return a pair of timestamps, or nil and an error
function mod.resolve(config, expr, relative_to)
  local ast, err = mod.parse(expr)
  if not ast then
    return nil, err
  end

  relative_to = relative_to or os.time()

  if ast.operator == 'on' then
    -- XXX how am I going to handle timezones?
    local operand = ast.operand
    assert(not operand.time, 'nyi')

    if operand.date.type == 'relative' then
      local adjusted_time = relative_to + operand.date.magnitude * UNIT_TO_SECONDS[operand.date.unit]
      local resolution = operand.date.unit -- XXX is this right?

      local start_time

      if resolution == 'day' then
        -- XXX how do I handle isdst?
        local d = os.date('*t', adjusted_time)

        start_time = os.time {
          year   = d.year,
          month  = d.month,
          day    = d.day,
          hour   = 0,
          minute = 0,
          second = 0,
        }
      elseif resolution == 'week' then
        local d = os.date('*t', adjusted_time)

        start_time = os.time {
          year   = d.year,
          month  = d.month,
          day    = d.day,
          hour   = 0,
          minute = 0,
          second = 0,
        }

        start_time = start_time - 86400 * (d.wday - 1)
      else
        error(string.format('invalid resolution %q', resolution))
      end

      return start_time, start_time + UNIT_TO_SECONDS[resolution]
    elseif operand.date.type == 'absolute' then
      local now = os.date('*t', relative_to)

      local start_time = os.time {
        year   = operand.date.year or now.year,
        month  = operand.date.month,
        day    = operand.date.day,
        hour   = 0,
        minute = 0,
        second = 0,
      }

      return start_time, start_time + UNIT_TO_SECONDS.day
    else
      error(string.format('invalid date type %q', operand.date.type))
    end
  else
    error(string.format('invalid operator %q', ast.operator))
  end
end

return mod
