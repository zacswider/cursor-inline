local M = {}
local config = require("cursor-inline.config")
local prompts = require("cursor-inline.prompts")
local state = require("cursor-inline.state")
local ui = require("cursor-inline.ui")

---@param output string
---@return boolean, any
local function decode_opencode_response(output)
  local ok, data = pcall(vim.json.decode, output)
  if ok then
    return true, data
  end

  local brace_start = output:find("{", 1, true)
  local brace_end = output:match(".*()}")
  if brace_start and brace_end and brace_end >= brace_start then
    local chunk = output:sub(brace_start, brace_end)
    ok, data = pcall(vim.json.decode, chunk)
    if ok then
      return true, data
    end
  end

  local bracket_start = output:find("[", 1, true)
  local bracket_end = output:match(".*()]")
  if bracket_start and bracket_end and bracket_end >= bracket_start then
    local chunk = output:sub(bracket_start, bracket_end)
    ok, data = pcall(vim.json.decode, chunk)
    if ok then
      return true, data
    end
  end

  return false, nil
end

---@param model any
---@return table|nil
local function normalize_opencode_model(model)
  if type(model) == "table" then
    return model
  end
  if type(model) ~= "string" or model == "" then
    return nil
  end
  local provider_id, model_id = model:match("^([^/]+)/(.+)$")
  if not provider_id or not model_id then
    return nil
  end
  return {
    providerID = provider_id,
    modelID = model_id,
  }
end

---@param message string
local function debug_log(message)
  if config.provider.debug ~= true then
    return
  end
  vim.schedule(function()
    vim.notify(message, vim.log.levels.DEBUG)
  end)
end

---@param ok boolean
---@param message string|nil
local function flush_opencode_server_queue(ok, message)
  local pending = state.opencode_server_pending or {}
  state.opencode_server_pending = nil
  state.opencode_server_starting = false
  for _, callback in ipairs(pending) do
    callback(ok, message)
  end
end

---@param on_ready fun(ok: boolean, message: string|nil)
local function start_opencode_server(on_ready)
  state.opencode_server_pending = state.opencode_server_pending or {}
  table.insert(state.opencode_server_pending, on_ready)

  if state.opencode_server_starting then
    return
  end
  if state.opencode_server_job then
    flush_opencode_server_queue(true)
    return
  end

  state.opencode_server_starting = true
  local command = config.provider.start_command
  if not command or command == "" then
    flush_opencode_server_queue(false, "OpenCode start command is not configured")
    return
  end

  local cmd_list = type(command) == "table" and command or vim.fn.split(command)
  local job_id = vim.fn.jobstart(cmd_list, { detach = true })
  if job_id <= 0 then
    flush_opencode_server_queue(false, "Failed to start OpenCode server")
    return
  end

  state.opencode_server_job = job_id
  local delay = config.provider.startup_delay_ms or 1500
  vim.defer_fn(function()
    flush_opencode_server_queue(true)
  end, delay)
end

---@param path string
---@return string
local function opencode_url(path)
  local base = config.provider.server_url or "http://127.0.0.1:4096"
  base = base:gsub("/+$", "")
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  return base .. path
end

---@param method string
---@param path string
---@param body table|nil
---@param on_success fun(response: table)
---@param on_error fun(message: string)|nil
---@param opts table|nil
local function opencode_request(method, path, body, on_success, on_error, opts)
  local command = {
    "curl",
    "-s",
    "-X",
    method,
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: application/json",
  }

  debug_log("[opencode] request " .. method .. " " .. opencode_url(path))
  if body then
    debug_log("[opencode] request body: " .. vim.inspect(body))
  end

  if body then
    table.insert(command, "-d")
    table.insert(command, vim.json.encode(body))
  end

  table.insert(command, opencode_url(path))

  vim.schedule(function()
    ui.start_spinner()
  end)

  vim.system(command, { text = true }, function(res)
    vim.schedule(function()
      ui.stop_spinner()
    end)

    if res.code ~= 0 then
      debug_log("[opencode] request failed (exit " .. tostring(res.code) .. ")")
      if res.stderr and res.stderr ~= "" then
        debug_log("[opencode] stderr: " .. res.stderr)
      end
      local allow_autostart = config.provider.autostart == true
      local should_retry = allow_autostart and res.code == 7 and not (opts and opts.retried)
      if should_retry then
        start_opencode_server(function(ok, message)
          if not ok then
            vim.schedule(function()
              vim.notify(message or "Failed to start OpenCode server", vim.log.levels.ERROR)
            end)
            return
          end
          opencode_request(method, path, body, on_success, on_error, { retried = true })
        end)
        return
      end

      local message = res.stderr or "OpenCode request failed"
      vim.schedule(function()
        if on_error then
          on_error(message)
        else
          vim.notify(message, vim.log.levels.ERROR)
        end
      end)
      return
    end

    local ok, data = decode_opencode_response(res.stdout)
    if not ok then
      debug_log("[opencode] response decode failed: " .. tostring(res.stdout))
      local message = "Failed to parse OpenCode response"
      if on_error then
        vim.schedule(function()
          on_error(message)
        end)
      else
        vim.schedule(function()
          vim.notify(message, vim.log.levels.ERROR)
        end)
      end
      return
    end

    debug_log("[opencode] response: " .. vim.inspect(data))
    vim.schedule(function()
      on_success(data)
    end)
  end)
end

---@param input string
---@param on_response function(text string)
local function openai_curl_command(input, on_response)
  local api_key = config.provider.name == "openai" and vim.fn.getenv("OPENAI_API_KEY")
  local payload = vim.json.encode({
    model = config.provider.model or "gpt-4.1-mini",
    input = {
      { role = "system", content = prompts.system_prompt },
      { role = "user",   content = input },
    },
  })
  local command = {
    "curl",
    "-s",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Authorization: Bearer " .. api_key,
    "-d",
    payload,
    "https://api.openai.com/v1/responses"
  }
  vim.schedule(function()
    ui.start_spinner()
  end)
  vim.system(command, {
    text = true,
  }, function(res)
    vim.schedule(function()
      ui.stop_spinner()
    end)
    local data = vim.json.decode(res.stdout)
    local response_code = data.output and data.output[1] and data.output[1].content and data.output[1].content[1] and
        data.output[1].content[1].text
    if not response_code then
      vim.schedule(function()
        vim.notify("Failed to parse OpenAI response", vim.log.levels.ERROR)
      end)
      return
    end
    vim.schedule(function()
      on_response(response_code)
    end)
  end
  )
end

---@param input string
---@param on_response function(text string)
local function anthropic_curl_command(input, on_response)
  local api_key = config.provider.name == "anthropic" and vim.fn.getenv("ANTHROPIC_API_KEY")
  local payload = vim.json.encode({
    model = config.provider.model or "claude-sonnet-4-5-20250929",
    max_tokens = 1024,
    system = prompts.system_prompt,
    messages = {
      { role = "user", content = input },
    },
  })
  local command = {
    "curl",
    "-s",
    "-X",
    "POST",
    "-H",
    "x-api-key: " .. api_key,
    "-H",
    "anthropic-version: 2023-06-01",
    "-H",
    "Content-Type: application/json",
    "-d",
    payload,
    "https://api.anthropic.com/v1/messages"
  }
  vim.schedule(function()
    ui.start_spinner()
  end)
  vim.system(command, {
    text = true,
  }, function(res)
    vim.schedule(function()
      ui.stop_spinner()
    end)
    local data = vim.json.decode(res.stdout)
    local response_code = data.content and data.content[1] and data.content[1].text
    if not response_code then
      vim.schedule(function()
        vim.notify("Failed to parse Anthropic response", vim.log.levels.ERROR)
      end)
      return
    end
    vim.schedule(function()
      on_response(response_code)
    end)
  end
  )
end

---@param input string
---@param on_response function(text string)
local function opencode_curl_command(input, on_response)
  local instruction = input
  local selected_text = state.selected_text
  local prompt_text = instruction .. "\n below is the selected code, \n```" .. selected_text .. "```"

  local function send_message(session_id)
    local body = {
      system = prompts.system_prompt,
      parts = {
        {
          type = "text",
          text = prompt_text,
        },
      },
    }
    local model = normalize_opencode_model(config.provider.model)
    if model then
      body.model = model
    end
    if config.provider.agent and config.provider.agent ~= "" then
      body.agent = config.provider.agent
    end

    opencode_request("POST", "/session/" .. session_id .. "/message", body, function(response)
      if response and response.success == false and response.error then
        local err = response.error[1]
        local err_message = "OpenCode request failed"
        if err and err.message then
          err_message = err.message
        end
        vim.notify(err_message, vim.log.levels.ERROR)
        return
      end
      if response and response.info and response.info.error then
        local err = response.info.error
        local err_message = "OpenCode error"
        if err.data and err.data.message then
          err_message = err.data.message
        elseif err.name then
          err_message = err.name
        end
        vim.notify(err_message, vim.log.levels.ERROR)
        return
      end
      local parts = response.parts or {}
      local text_chunks = {}
      for _, part in ipairs(parts) do
        if part.type == "text" and part.text then
          table.insert(text_chunks, part.text)
        elseif part.text then
          table.insert(text_chunks, part.text)
        end
      end
      local response_text = table.concat(text_chunks, "")
      if response_text == "" then
        vim.notify("OpenCode returned an empty response", vim.log.levels.ERROR)
        return
      end
      on_response(response_text)
    end, function(message)
      vim.notify(message, vim.log.levels.ERROR)
    end)
  end

  if state.opencode_session_id then
    send_message(state.opencode_session_id)
    return
  end

  opencode_request("POST", "/session", { title = "cursor-inline" }, function(response)
    if not response or not response.id then
      vim.notify("Failed to create OpenCode session", vim.log.levels.ERROR)
      return
    end
    state.opencode_session_id = response.id
    send_message(response.id)
  end, function(message)
    vim.notify(message, vim.log.levels.ERROR)
  end)
end

---@param input string
---@param on_response function(text string)
function M.get_current_provider_response(input, on_response)
  local provider = config.provider.name
  local instruction = input
  local selected_text = state.selected_text
  local prompt_text = instruction .. "\n below is the selected code, \n```" .. selected_text .. "```"
  if provider == "openai" then
    openai_curl_command(prompt_text, on_response)
  end
  if provider == "anthropic" then
    anthropic_curl_command(prompt_text, on_response)
  end
  if provider == "opencode" then
    opencode_curl_command(instruction, on_response)
  end
end

return M
