---START INJECT hlq.lua

local M = {}
local api, fn = vim.api, vim.fn, vim.uv

local ns = api.nvim_create_namespace('u.hlq')
---@class hlq.item: BqfQfItem
---@field id0? integer
---@field id1? integer

---@param buf integer
---@param line string
---@param lnum integer
---@param item hlq.item
local hlitem = function(buf, line, lnum, item)
  local path, dir, basename = line:match('^((.-/)([^/%s]+))%s-│')
  if not path or not dir or not basename then return end
  local _, hl = require('mini.icons').get('file', path)
  local hl_dir = 'Directory'
  if not hl or not hl_dir then return end
  item.id0, item.id1 = vim.F.npcall(function()
    return api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
      id = item.id0,
      end_col = dir:len(),
      hl_group = hl_dir,
    }),
      ---@diagnostic disable-next-line: redundant-return-value
      api.nvim_buf_set_extmark(buf, ns, lnum - 1, dir:len(), {
        id = item.id1,
        end_col = path:len(),
        hl_group = hl,
      })
  end)
end

---@param win integer
---@param buf integer
local hlq = function(win, buf)
  if not api.nvim_win_is_valid(win) then return end
  local qfs = require('bqf.qfwin.session')
  local info = fn.getwininfo(win)[1]
  if not info then return end
  local items = qfs:get(win):list():items()
  for i = info.topline, info.botline do
    local v = items[i]
    if v and v.valid == 1 then
      local line = api.nvim_buf_get_lines(buf, i - 1, i, false)[1]
      if line then hlitem(buf, line, i, v) end
    end
  end
end

function M.enable()
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
