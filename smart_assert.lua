-- sentinel value so we can distinguish between finding a variable with a nil
-- value and not finding anything
local NOT_FOUND = {}

local function resolve_expr(expr)
  -- split up expr into fields and determine the name of the "root" variable
  -- plus the full path for the rest of the expression
  local field_path = {}
  for field in string.gmatch(expr, '[^.]+') do
    field_path[#field_path+1] = field
  end

  local root_var_name = field_path[1]
  table.remove(field_path, 1)

  local expr_value = NOT_FOUND

  -- try finding a local with the given name
  local which_local = 1
  while true do
    local name, value = debug.getlocal(3, which_local)
    if not name then
      break
    end

    if name == root_var_name then
      expr_value = value
      -- explicitly do NOT break here - there may be multiple locals with the same
      -- name and it's the latest one we want
    end

    which_local = which_local + 1
  end

  -- if we weren't able to find the root name among the local variables,
  -- fall back to upvalues
  if expr_value == NOT_FOUND then
    local f = debug.getinfo(3, 'f').func

    local which_upvalue = 1
    while true do
      local name, value = debug.getupvalue(f, which_upvalue)
      if not name then
        break
      end

      if name == root_var_name then
        expr_value = value
        -- we can break here - unlike locals, there's at most one upvalue with a given name
        break
      end

      which_upvalue = which_upvalue + 1
    end
  end

  -- XXX if we weren't able to find the root name among either the locals or the upvalues,
  -- try the function's environment
  if expr_value == NOT_FOUND then
    local f = debug.getinfo(3, 'f').func

    -- get the _ENV upvalue
    local func_env
    local which_upvalue = 1
    while true do
      local name, value = debug.getupvalue(f, which_upvalue)
      if not name then
        break
      end

      if name == '_ENV' then
        func_env = value
        break
      end

      which_upvalue = which_upvalue + 1
    end

    -- if we found the function environment, look up the expression inside of it
    -- in this case, there's no meaningful distinction between nil for "not found"
    -- and an explicit nil value - Lua treats them the same semantically
    if func_env then
      local ok, value_or_error = pcall(function() return func_env[root_var_name] end)
      if ok then
        expr_value = value_or_error
      end
      -- XXX if not ok, should I be throwing away the error?
    end
  end

  -- if we can't find the root name among the locals, or the upvalues, OR the
  -- function's environment…I'm pretty sure that's all of the places it could be,
  -- so just report it as unable to be found
  if expr_value == NOT_FOUND then
    return false, 'not found'
  end

  -- traverse the root structure we found to get to the final value
  for i = 1, #field_path do
    local field = field_path[i]
    local ok, value_or_error = pcall(function() return expr_value[field] end)

    -- if a table lookup threw an error, just accept it and report we weren't able to resolve
    if not ok then
      return false, value_or_error
    end

    expr_value = value_or_error
  end

  return true, expr_value
end

local function smart_assert(v, ...)
  if v then
    return v, ...
  end

  local message = ...

  local our_name = debug.getinfo(1, 'n').name
  local caller = debug.getinfo(2, 'Sl')

  -- if the source isn't a file, just skip it over
  if string.sub(caller.source, 1, 1) ~= '@' then
    error(message, 2)
  end

  -- if we can't open the source file, just skip it over
  local f = io.open(string.sub(caller.source, 2), 'r')
  if not f then
    error(message, 2)
  end

  -- try to locate the line that called us
  local assertion_line
  local line_no = 1
  for line in f:lines() do
    if line_no == caller.currentline then
      assertion_line = line
      break
    end

    line_no = line_no + 1
  end
  f:close()

  -- …if you can't, just skip it over
  if not assertion_line then
    error(message, 2)
  end

  -- attempt some simple parses
  local full_expr, lhs_name, rhs_name = string.match(assertion_line, '^%s*' .. our_name .. '%s*%(%s*(([%w._]+)%s*==%s*([%w._]+))%s*[,)]')

  -- if we weren't able to parse anything, just skip it over
  if not lhs_name or not rhs_name then
    error(message, 2)
  end

  -- determine values for LHS and RHS, skipping over if we can't figure it out
  local lhs_found, lhs_value = resolve_expr(lhs_name)
  local rhs_found, rhs_value = resolve_expr(rhs_name)

  if not lhs_found or not rhs_found then
    error(message, 2)
  end

  message = message or ''
  message = message .. ' assertion ' .. full_expr .. ' failed!'
  local name_width = math.max(string.len(lhs_name), string.len(rhs_name))
  message = message .. string.format('\n%' .. tostring(name_width) .. 's: %q\n%' .. tostring(name_width) .. 's: %q', lhs_name, lhs_value, rhs_name, rhs_value)

  error(message, 2)
end

return smart_assert
