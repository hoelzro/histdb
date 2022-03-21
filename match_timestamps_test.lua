local assert = require 'smart_assert'
local pretty = require 'pretty'
local parse = require('match_timestamps').parse
local resolve = require('match_timestamps').resolve

local function append(t, v)
  local copy = {}

  for i = 1, #t do
    copy[i] = t[i]
  end
  copy[#copy + 1] = v

  return copy
end

-- XXX what if there are multiple mismatches?
local function deep_equal(got, expected, path)
  path = path or {}

  if type(got) ~= type(expected) then
    return false, string.format('types for got and expected differ at %s: %s vs %s', table.concat(path, '.'), type(got), type(expected))
  end

  if type(got) == 'table' then
    for k in pairs(got) do
      if expected[k] == nil then
        return false, string.format("expected is missing key/value pair at %s.%s", table.concat(path, '.'), tostring(k))
      end

      local equal, reason = deep_equal(got[k], expected[k], append(path, k))
      if not equal then
        return false, reason
      end
    end

    for k in pairs(expected) do
      if got[k] == nil then
        return false, string.format("got is missing key/value pair at %s.%s", table.concat(path, '.'), tostring(k))
      end
    end
  elseif type(got) == 'string' then
    if got ~= expected then
      return false, string.format('got and expected differ at %s: %q vs %q', table.concat(path, '.'), got, expected)
    end
  elseif type(got) == 'number' then
    -- XXX slop for floats?
    if got ~= expected then
      -- XXX %d or %f?
      return false, string.format('got and expected differ at %s: %d vs %d', table.concat(path, '.'), got, expected)
    end
  else
    error(string.format("I don't know how to deeply compare values of type %s", type(got)))
  end

  return true
end

local TEST_TIMESTAMP = os.time {
  year   = 2022,
  month  = 3,
  day    = 18,
  hour   = 14,
  minute = 0,
  second = 0,
}

local tests = {
  {
    expr = 'yesterday',
    expected = {
      operator = 'on',
      operand  = {
        date = {
          type      = 'relative',
          unit      = 'day',
          magnitude = -1,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 17,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 18,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
  {
    expr = 'today',
    expected = {
      operator = 'on',
      operand  = {
        date = {
          type      = 'relative',
          unit      = 'day',
          magnitude = 0,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 18,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 19,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
  {
    expr = '1 day ago',
    expected = {
      operator = 'on',
      operand  = {
        date = {
          type      = 'relative',
          unit      = 'day',
          magnitude = -1,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 17,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 18,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
  {
    expr = '3 days ago',
    expected = {
      operator = 'on',
      operand  = {
        date = {
          type      = 'relative',
          unit      = 'day',
          magnitude = -3,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 15,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 16,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
  {
    expr = '1 week ago',
    expected = {
      operator = 'on',
      operand  = {
        date = {
          type      = 'relative',
          unit      = 'week',
          magnitude = -1,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 6,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 13,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
  {
    expr = '1d ago',
    expected = {
      operator = 'on',
      operand  = {
        date = {
          type      = 'relative',
          unit      = 'day',
          magnitude = -1,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 17,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 18,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
  {
    expr = '-1 days',
    expected = {
      operator = 'on',
      operand  = {
        date = {
          type      = 'relative',
          unit      = 'day',
          magnitude = -1,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 17,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 18,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
  {
    expr = '2022-03-01',
    expected = {
      operator = 'on',
      operand  = {
        date = {
          type  = 'absolute',
          year  = 2022,
          month = 3,
          day   = 1,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 1,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 2,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
  {
    expr = '03-01',
    expected = {
      operator = 'on',
      operand  = {
        date = {
          type  = 'absolute',
          month = 3,
          day   = 1,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 1,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 2,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
  {
    expr = 'since 03-01',
    expected = {
      operator = 'since',
      operand  = {
        date = {
          type  = 'absolute',
          month = 3,
          day   = 1,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 1,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = TEST_TIMESTAMP,
  },
  {
    expr = 'between 03-01 and 03-10',
    expected = {
      operator = 'between',
      lhs  = {
        date = {
          type  = 'absolute',
          month = 3,
          day   = 1,
        },
      },
      rhs  = {
        date = {
          type  = 'absolute',
          month = 3,
          day   = 10,
        },
      },
    },
    expected_min_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 1,
      hour   = 0,
      minute = 0,
      second = 0,
    },
    expected_max_timestamp = os.time {
      year   = 2022,
      month  = 3,
      day    = 11,
      hour   = 0,
      minute = 0,
      second = 0,
    },
  },
}

local success = true

for i = 1, #tests do
  local t = tests[i]
  local expr = t.expr
  local got = assert(parse(expr))
  local ok, reason = deep_equal(got, t.expected)
  if not ok then
    print(string.format('Output for test %d (%q) differs: %s', i, expr, reason))
    print('Got:')
    pretty.print(got)
    print('Expected:')
    pretty.print(t.expected)
    success = false
  end

  local got_min_timestamp, got_max_timestamp = assert(resolve({}, expr, TEST_TIMESTAMP))
  assert(got_min_timestamp == t.expected_min_timestamp, string.format('Test #%d - %q', i, expr))
  assert(got_max_timestamp == t.expected_max_timestamp, string.format('Test #%d - %q', i, expr))
end

if not success then
  os.exit(1)
end
