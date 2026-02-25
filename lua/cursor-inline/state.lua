local api = vim.api

local M = {
  highlight = {
    old_code = {
      start_row = nil,
      end_row = nil,
      hl_group = "OldCode",
      ns = api.nvim_create_namespace("OldCodeHighlight"),
      id = nil
    },
    new_code = {
      start_row = nil,
      end_row = nil,
      hl_group = "NewCode",
      ns = api.nvim_create_namespace("NewCodeHighlight"),
      id = nil
    }
  },
  wins = {
    accept = nil,
    deny = nil
  },
  bufs = {
    accept = nil,
    deny = nil,
    input = nil
  },
  selected_text = "",
  main_bufnr = nil,
  opencode_session_id = nil,
  opencode_server_job = nil,
  opencode_server_starting = false,
  opencode_server_pending = nil,
}
return M
