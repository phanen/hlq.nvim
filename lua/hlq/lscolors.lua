---START INJECT lscolors.lua

local M = {}

local cache = {
  parsed = false,
  mode_map = {},
  ext_map = {},
  glob_map = {},
  default_hl = nil,
  needs_metadata = false,
  overrides = {},
}

local MODE_KEYS = {
  bd = 'block_device',
  ca = 'file_w_capacity',
  cd = 'char_device',
  di = 'directory',
  ['do'] = 'door',
  ex = 'executable',
  ln = 'link',
  mh = 'multi_hardlink',
  ['or'] = 'orphan_link',
  ow = 'other_writable',
  pi = 'pipe',
  sg = 'set_gid',
  so = 'socket',
  st = 'sticky',
  su = 'set_uid',
  tw = 'sticky_other_writable',
  fi = 'file',
  no = 'normal',
}

local STYLE_MAP = {
  [0] = 'NONE',
  [1] = 'bold',
  [2] = 'dim',
  [3] = 'italic',
  [4] = 'underline',
  [5] = 'blink',
  [7] = 'reverse',
  [8] = 'hidden',
  [9] = 'strikethrough',
}

local ANSI_COLORS = {
  [30] = 'Black',
  [31] = 'Red',
  [32] = 'Green',
  [33] = 'Yellow',
  [34] = 'Blue',
  [35] = 'Magenta',
  [36] = 'Cyan',
  [37] = 'White',
  [90] = 'DarkGray',
  [91] = 'LightRed',
  [92] = 'LightGreen',
  [93] = 'LightYellow',
  [94] = 'LightBlue',
  [95] = 'LightMagenta',
  [96] = 'LightCyan',
  [97] = 'LightGray',
}

local parse_ansi_code = function(code)
  local parts = vim.split(code, ';', { plain = true })
  local styles = {}
  local fg, bg
  local i = 1

  while i <= #parts do
    local p = tonumber(parts[i])
    if p then
      local style = STYLE_MAP[p]
      if style then
        styles[style] = true
      elseif p >= 30 and p <= 37 or p >= 90 and p <= 97 then
        fg = ANSI_COLORS[p]
      elseif p >= 40 and p <= 47 or p >= 100 and p <= 107 then
        bg = ANSI_COLORS[p - 10]
      elseif p == 38 or p == 48 then
        local is_fg = p == 38
        local next_p = tonumber(parts[i + 1])
        if next_p == 5 and parts[i + 2] then
          local color_idx = tonumber(parts[i + 2])
          if color_idx then
            local color = color_idx < 8 and ANSI_COLORS[30 + color_idx]
              or color_idx < 16 and ANSI_COLORS[82 + color_idx]
              or nil
            if is_fg then
              fg = color
            else
              bg = color
            end
          end
          i = i + 2
        elseif next_p == 2 and parts[i + 2] and parts[i + 3] and parts[i + 4] then
          local r, g, b = tonumber(parts[i + 2]), tonumber(parts[i + 3]), tonumber(parts[i + 4])
          if r and g and b then
            local hex = string.format('#%02x%02x%02x', r, g, b)
            if is_fg then
              fg = hex
            else
              bg = hex
            end
          end
          i = i + 4
        end
      end
    end
    i = i + 1
  end

  return { styles = styles, fg = fg, bg = bg }
end

local create_hlgroup = function(name, opts)
  local ns = 'u.lscolors'
  local clean_name = name:gsub('[^%w_]', '_')
  local hl_name = ns .. '.' .. clean_name

  local hl_opts = {}
  if opts.styles then
    hl_opts.bold = opts.styles.bold
    hl_opts.italic = opts.styles.italic
    hl_opts.underline = opts.styles.underline
    hl_opts.reverse = opts.styles.reverse
    hl_opts.strikethrough = opts.styles.strikethrough
  end
  hl_opts.fg = opts.fg
  hl_opts.bg = opts.bg

  if next(hl_opts) then
    vim.api.nvim_set_hl(0, hl_name, hl_opts)
    return hl_name
  end
end

---@param force? boolean
M.parse = function(force)
  if cache.parsed and not force then return end

  local ls_colors = os.getenv('LS_COLORS')
  if not ls_colors or ls_colors == '' then
    cache.parsed = true
    return
  end

  cache.mode_map = {}
  cache.ext_map = {}
  cache.glob_map = {}
  cache.needs_metadata = false

  for segment in vim.gsplit(ls_colors, ':', { plain = true }) do
    local key, code = segment:match('^([^=]+)=(.+)$')
    if key and code then
      local opts = parse_ansi_code(code)
      local mode_name = MODE_KEYS[key]

      if mode_name then
        cache.mode_map[mode_name] = create_hlgroup(mode_name, opts)
        cache.needs_metadata = key == 'ex' or key == 'su' or key == 'sg' or key == 'mh'
      elseif key:match('^%*%.') then
        local ext = key:sub(3)
        cache.ext_map[ext] = create_hlgroup('ext_' .. ext:gsub('%.', '_'), opts)
      elseif key ~= 'rs' and key ~= 'lc' and key ~= 'rc' and key ~= 'ec' then
        cache.glob_map[#cache.glob_map + 1] =
          { key, vim.regex(vim.fn.glob2regpat(key)), create_hlgroup('glob_' .. key, opts) }
      end
    end
  end

  cache.default_hl = 'Normal' or cache.mode_map.normal or cache.mode_map.file
  cache.parsed = true
end

---@param overrides table<string, string> map of keys to highlight groups
M.set_overrides = function(overrides) cache.overrides = overrides or {} end

---@param filepath string
---@param stat uv.fs_stat.result?
M.get_mode_from_stat = function(filepath, stat)
  stat = stat or vim.uv.fs_stat(filepath)
  if not stat then return end

  if stat.type == 'directory' then
    if cache.mode_map.sticky_other_writable then
      local mode = stat.mode
      if bit.band(mode, 0x1002) == 0x1002 then return 'sticky_other_writable' end
    end
    if cache.mode_map.other_writable then
      local mode = stat.mode
      if bit.band(mode, 0x0002) ~= 0 then return 'other_writable' end
    end
    if cache.mode_map.sticky then
      local mode = stat.mode
      if bit.band(mode, 0x1000) ~= 0 then return 'sticky' end
    end
    return 'directory'
  elseif stat.type == 'file' then
    if cache.mode_map.set_uid then
      local mode = stat.mode
      if bit.band(mode, 0x800) ~= 0 then return 'set_uid' end
    end
    if cache.mode_map.set_gid then
      local mode = stat.mode
      if bit.band(mode, 0x400) ~= 0 then return 'set_gid' end
    end
    if cache.mode_map.executable then
      local mode = stat.mode
      if bit.band(mode, 0x49) ~= 0 then return 'executable' end
    end
    if cache.mode_map.multi_hardlink and stat.nlink > 1 then return 'multi_hardlink' end
    return 'file'
  elseif stat.type == 'link' then
    return 'link'
  elseif stat.type == 'fifo' then
    return 'pipe'
  elseif stat.type == 'socket' then
    return 'socket'
  elseif stat.type == 'char' then
    return 'char_device'
  elseif stat.type == 'block' then
    return 'block_device'
  end
end

---@param filename string
---@param mode? string
---@return string?
M.get_hl = function(filename, mode)
  M.parse()

  mode = mode or M.get_mode_from_stat(filename)
  if mode and cache.mode_map[mode] then return cache.mode_map[mode] end

  for _, ctx in ipairs(cache.glob_map) do
    local pattern, regex, hl = unpack(ctx)
    if regex:match_str(filename) then return cache.overrides[pattern] or hl end
  end

  local parts = vim.split(vim.fs.basename(filename), '%.')
  local ext = parts[#parts]
  local hl = cache.ext_map[ext]
  if hl then return hl end
  if #parts > 2 then
    for i = #parts - 1, 1 do
      ext = parts[i] .. '.' .. ext
      local hl0 = cache.ext_map[ext]
      if hl0 then return hl0 end
    end
  end

  return cache.default_hl
end

return M
