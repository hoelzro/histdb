local function slurp_file(filename)
  local f, err = io.open(filename, 'r')
  if not f then
    return nil, err
  end

  local contents, err = f:read '*a'
  f:close()

  if not contents then
    return nil, err
  end

  return contents
end

local function process_cli_args(args)
  local options = {}
  local i = 1

  while i <= #args do
    local arg = args[i]

    if arg == '--module-prefix' then
      i = i + 1
      options.module_prefix = args[i]
    elseif arg == '--output' then
      i = i + 1
      options.output_filename = args[i]
    elseif arg == '--entrypoint' then
      i = i + 1
      options.entrypoint = args[i]
    elseif string.sub(arg, 1, 3) == '--' then
      error('unknown option: ' .. arg)
    else
      options[#options+1] = arg
    end

    i = i + 1
  end

  return options
end

local function write_module(output, module_prefix, module_path, module_name)

  local module_src = assert(slurp_file(module_path))

  local delim_level
  for level = 1, 6 do
    local open_delim = '[' .. string.rep('=', level) .. '['
    local close_delim = ']' .. string.rep('=', level) .. ']'

    if not string.find(module_src, open_delim, 1, true) and not string.find(module_src, close_delim, 1, true) then
      delim_level = level
      break
    end
  end

  assert(delim_level, 'unable to determine safe delimiter level')

  output:write(string.format('package.preload[%q] = function()\n', (module_prefix and module_prefix .. '.' or '') .. module_name))
  output:write('  local src = [' .. string.rep('=', delim_level) .. '[\n')
  output:write(module_src)
  output:write('  ]' .. string.rep('=', delim_level) .. ']\n\n')
  output:write(string.format('  local loader, err = load(src, %q)\n', module_path))
  output:write '  if not loader then\n'
  output:write '    return nil, err\n'
  output:write '  end\n'
  output:write '  return loader()\n'
  output:write 'end\n\n'
end

local options = process_cli_args(arg)

for i_mod = 1, #options do
  local module_path = options[i_mod]
  local ok = os.execute(string.format('luac -p %q', module_path))
  if not ok then
    os.exit(1)
  end
end

if options.entrypoint then
  local ok = os.execute(string.format('luac -p %q', options.entrypoint))
  if not ok then
    os.exit(1)
  end
end

local output = io.stdout

if options.output_filename then
  output = assert(io.open(options.output_filename, 'w'))
end

output:write '-- This file is generated via build.lua - do not edit by hand!\n\n'

for i_mod = 1, #options do
  local module_path = options[i_mod]
  local module_name = string.match(module_path, '(.*)[.]lua$')
  write_module(output, options.module_prefix, module_path, module_name)
end

if options.entrypoint then
  write_module(output, options.module_prefix, options.entrypoint, '.entrypoint')
  output:write 'local m = require ".entrypoint"\n'
  output:write 'return m\n'
end

if output ~= io.stdout then
  output:close()
end
