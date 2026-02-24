local M = {}
local config = require("cursor-inline.config")
local prompts = require("cursor-inline.prompts")
local state = require("cursor-inline.state")
local ui = require("cursor-inline.ui")

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
local function opencode_request(method, path, body, on_success, on_error)
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
      local message = res.stderr or "OpenCode request failed"
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

    local ok, data = pcall(vim.json.decode, res.stdout)
    if not ok then
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
    if config.provider.model and config.provider.model ~= "" then
      body.model = config.provider.model
    end
    if config.provider.agent and config.provider.agent ~= "" then
      body.agent = config.provider.agent
    end

    opencode_request("POST", "/session/" .. session_id .. "/message", body, function(response)
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
