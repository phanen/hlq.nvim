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

---@param buf integer
---@param line string
---@param lnum integer 0-index
---@param codehl boolean
local hlitem = function(buf, line, lnum, codehl)
  local offset, path, dir, _, _, _, qcode =
    line:match('^(((.-/)([^/│%s]+))%s-│%s*(%d+):(%d+)%s*│ )(.*)$')
  if not path or not dir then return end
  local _, hl = require('mini.icons').get('file', path)
  if not hl then return end
  set_extmarks(buf, ns, lnum, 0, { end_col = dir:len(), hl_group = 'Directory' })
  set_extmarks(buf, ns, lnum, dir:len(), { end_col = path:len(), hl_group = hl })
  if not codehl or not offset or not qcode or qcode:match('^%s+$') then return end -- TODO: diagnostic/symbols
  local ft = filetype_match(path) -- TODO: maybe already matched in mini.icons?
  if not ft then return end
  local marks = require('snacks.picker.util.highlight').get_highlights({ code = qcode, ft = ft }) ---@type table
  if not marks or not marks[1] or not marks[1][1] then return end
  local off = offset:len()
  for _, mark in ipairs(marks[1]) do
    set_extmarks(buf, ns, lnum, mark.col + off, {
      end_col = mark.end_col + off,
      hl_group = mark.hl_group,
    })
  end
end

---@param win integer
---@param buf integer
local hlq = function(win, buf)
  if not api.nvim_win_is_valid(win) then return end
  local qfs = require('bqf.qfwin.session')
  local info = fn.getwininfo(win)[1]
  if not info then return end
  local items = vim.F.npcall(function() return qfs:get(win):list():items() end)
  if not items then return end
  local codehl = can_hl((vim.w[win].quickfix_title or ''):lower())
  for i = info.topline, info.botline do
    local v = items[i]
    if v and v.valid == 1 then
      local line = api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
      if line then hlitem(buf, line, i - 1, codehl) end
    end
  end
end

function M.enable()
  filetype_match = vim.func._memoize(1, filetype_match)
  _G.qftf = qftf
  vim.o.qftf = '{info -> v:lua._G.qftf(info)}'
  api.nvim_create_autocmd('BufReadPost', {
    pattern = 'quickfix',
    callback = function(ev)
      local buf = ev.buf
      vim.schedule_wrap(hlq)(fn.bufwinid(buf), buf)
      api.nvim_create_autocmd({ 'WinScrolled' }, {
        buffer = buf,
        callback = function(ev0)
          hlq(tonumber(ev0.match) --[[@as integer]], buf)
        end,
      })
    end,
  })
end

return M
