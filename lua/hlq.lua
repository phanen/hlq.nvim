local u = {
  lscolors = require('hlq.lscolors'),
}
---START INJECT hlq.lua

local M = {}
local api, fn = vim.api, vim.fn

local ns = api.nvim_create_namespace('u.hlq')

local qftf = function(info)
  local items
  local ret = {}
  if info.quickfix == 1 then
    items = fn.getqflist({ id = info.id, items = 0 }).items
  else
    items = fn.getloclist(info.winid, { id = info.id, items = 0 }).items
  end
  local limit = 31
  local fnameFmt1, fnameFmt2 = '%-' .. limit .. 's', '…%.' .. (limit - 1) .. 's'
  local validFmt = '%s │%5d:%-3d│%s %s'
  for i = info.start_idx, info.end_idx do
    local e = items[i]
    local fname = ''
    local str
    if e.valid == 1 then
      if e.bufnr > 0 then
        fname = fn.bufname(e.bufnr)
        if fname == '' then
          fname = '[No Name]'
        else
          fname = fname:gsub('^' .. vim.env.HOME, '~')
        end
        if #fname <= limit then
          fname = fnameFmt1:format(fname)
        else
          fname = fnameFmt2:format(fname:sub(1 - limit))
        end
      end
      local lnum = e.lnum > 99999 and -1 or e.lnum
      local col = e.col > 999 and -1 or e.col
      local qtype = e.type == '' and '' or ' ' .. e.type:sub(1, 1):upper()
      str = validFmt:format(fname, lnum, col, qtype, e.text)
    else
      str = e.text
    end
    table.insert(ret, str)
  end
  return ret
end

local tmpbuf ---@type integer?
local filetype_match = function(filename)
  tmpbuf = tmpbuf and api.nvim_buf_is_valid(tmpbuf) and api.nvim_create_buf(false, true) or tmpbuf
  return vim.filetype.match({ filename = filename, buf = tmpbuf })
end

local set_extmarks = vim.F.nil_wrap(api.nvim_buf_set_extmark)

---@param title string
---@return boolean
local can_hl = function(title)
  return not (
    title:match('diagnostic')
    or title:match('symbols')
    or title:match('outline')
    or title:match('^:G')
  )
end

---@param item hlq.item
---@param buf integer quickfix buf
---@param lnum integer quickfix lnum 0-index
---@return string?, integer?, string?, integer?
local parse_item = function(item, buf, lnum)
  local line = api.nvim_buf_get_lines(buf, lnum, lnum + 1, false)[1]
  if not line then return end
  if item.user_data and item.user_data.diff then
    local path, dir = line:match('^%S%s((.+/)[^/]+)$')
    return path, 2, dir, nil
  end
  local codeoff, path, dir = line:match('^(((.-/)([^/│]-))%s-│%s*(%d+):(%d+)%s*│ )(.*)$')
  return path, 0, dir, codeoff and codeoff:len() or nil
end

---@param item hlq.item
---@param buf integer quickfix buf
---@param lnum integer quickfix lnum 0-index
---@param code string
---@param codehl boolean
local hlitem = function(item, buf, lnum, code, codehl)
  local path, off, dir, codeoff = parse_item(item, buf, lnum)
  if not path or not dir or not off then return end
  set_extmarks(buf, ns, lnum, off, { end_col = off + dir:len(), hl_group = 'Directory' })
  local hl = u.lscolors.get_hl(item.filename or api.nvim_buf_get_name(item.bufnr) or path)
  if hl then
    set_extmarks(buf, ns, lnum, off + dir:len(), { end_col = off + path:len(), hl_group = hl })
  end
  if not codehl or not codeoff or code:match('^%s+$') then return end -- TODO: diagnostic/symbols
  local ft = filetype_match(path)
  if not ft then return end
  local highlight = vim.F.npcall(require, 'snacks.picker.util.highlight')
  if not highlight then return end
  local marks = highlight.get_highlights({ code = code, ft = ft }) ---@type table
  if not marks or not marks[1] or not marks[1][1] then return end
  for _, mark in ipairs(marks[1]) do
    set_extmarks(buf, ns, lnum, mark.col + codeoff, {
      end_col = mark.end_col + codeoff,
      hl_group = mark.hl_group,
    })
  end
end

---@class hlq.item: BqfQfItem, vim.quickfix.entry
---@field color? boolean

---@class hlq.list: BqfQfList
---@field _changedtick integer
---@field items fun(self: hlq.list): hlq.item[]

---@param win integer
---@return hlq.list?
local getlist = function(win)
  return vim.F.npcall(function() return require('bqf.qfwin.session'):get(win):list() end)
end

---@param win integer
---@param buf? integer
---@param list? hlq.list
local hlq = function(win, buf, list)
  if not api.nvim_win_is_valid(win) then return end
  buf = buf or api.nvim_win_get_buf(win)
  list = list or getlist(win)
  if not list then return end
  local items = list:items()
  local codehl = can_hl((vim.w[win].quickfix_title or ''):lower())
  for i = fn.line('w0', win), fn.line('w$', win) do
    local item = items[i]
    if item and not item.color then
      hlitem(item, buf, i - 1, item.text, codehl)
      item.color = true
    end
  end
end

M.enable = function()
  filetype_match = vim.func._memoize(1, filetype_match)
  _G.qftf = qftf
  vim.o.qftf = '{info -> v:lua._G.qftf(info)}'
  local group = api.nvim_create_augroup('u.hlq', {})
  api.nvim_create_autocmd('WinScrolled', {
    group = group,
    callback = function()
      for winstr, change in pairs(vim.v.event) do
        if winstr ~= 'all' and change.topline ~= 0 then
          local win = tonumber(winstr) ---@as integer
          local ty = fn.win_gettype(win)
          if ty == 'quickfix' or ty == 'loclist' then hlq(win) end
        end
      end
    end,
  })
  api.nvim_create_autocmd('BufReadPost', {
    group = group,
    pattern = 'quickfix',
    callback = function(ev)
      local buf = ev.buf
      local win = fn.bufwinid(buf)
      local refresh = function()
        local list = getlist(win)
        if not list then return end
        local savetick = list._changedtick
        if not api.nvim_buf_is_valid(buf) then return end
        list._changedtick = api.nvim_buf_get_changedtick(buf) -- buftick must >= qftick
        api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        hlq(win, buf, list)
        list._changedtick = savetick
      end
      vim.schedule(refresh)
    end,
  })
end

return M
