-- Tesy BelliSlimo QuickApp (HC3L) - RAW TCP / HTTP 1.0 reader
-- Reads /status JSON reliably (works around HTTPClient EOF)

-- ===== Helpers =====
local function toNum(x) return tonumber(x) end

-- Extract JSON from an HTTP response, regardless of newline style (\n or \r\n)
function QuickApp:extractJsonFromHttp(raw)
  if not raw or raw == "" then return nil, "Empty raw response" end

  local jStart = raw:find("{", 1, true)
  if not jStart then
    return nil, "No '{' found in response"
  end

  local body = raw:sub(jStart)
  body = body:gsub("^%s+", ""):gsub("%s+$", "")

  local ok, j = pcall(function() return json.decode(body) end)
  if not ok then
    return nil, "JSON decode failed. Body head: " .. body:sub(1, 200)
  end

  return j, nil
end

-- ===== RAW TCP HTTP/1.0 GET =====
function QuickApp:rawHttpGet(path, onOk, onErr)
  local sock = net.TCPSocket()
  local ip = tostring(self.ip):gsub("%s+", "")
  local port = 80
  local buf = {}

  local function safeClose()
    pcall(function() sock:close() end)
  end

  local function fail(msg)
    safeClose()
    if onErr then onErr(msg) end
  end

  local function readMore()
    sock:read({
      success = function(data)
        if data and #data > 0 then
          table.insert(buf, tostring(data))
          readMore()
        else
          safeClose()
          if onOk then onOk(table.concat(buf)) end
        end
      end,
      error = function(e)
        -- Many stacks signal remote close as "error". If we already have data, treat as done.
        local msg = tostring(e or "")
        safeClose()
        if #buf > 0 then
          if onOk then onOk(table.concat(buf)) end
        else
          if onErr then onErr("read error: " .. msg) end
        end
      end
    })
  end

  local ok, err = pcall(function()
    sock:connect(ip, port, {
      success = function()
        local req =
          "GET " .. path .. " HTTP/1.0\n" ..
          "Host: appliance.lan\n" ..
          "Connection: close\n" ..
          "\n"

        sock:write(req, {
          success = function()
            readMore()
          end,
          error = function(e)
            self:setErrorState("Write error: " .. tostring(e))
            fail("write error: " .. tostring(e))
          end
        })
      end,
      error = function(e)
        self:setErrorState("Connect error: " .. tostring(e))
        fail("connect error: " .. tostring(e))
      end
    })
  end)

  if not ok then
    self:setErrorState("net.TCPSocket crashed: " .. tostring(err))
    fail("net.TCPSocket crashed: " .. tostring(err))
  end
end

function QuickApp:formatCountdown(min)
  min = tonumber(min) or 0
  if min <= 0 then
    return "Ready"
  end

  local h = math.floor(min / 60)
  local m = min % 60

  if h > 0 then
    return string.format("%dh %02dm", h, m)
  else
    return string.format("%dm", m)
  end
end

-- ===== QuickApp lifecycle =====
function QuickApp:onInit()
  self:debug("Tesy BelliSlimo QA starting (RAW TCP)...")
  self:updateProperty("unit", "🚿")

  self.errorState = nil
  self:updateView("lblErr", "visible", false)

  self.ip = tostring(self:getVariable("TESY_IP") or ""):gsub("%s+", "")
  self.pollSec = tonumber(self:getVariable("POLL_SEC") or "30") or 30
  self.statusPath = self:getVariable("STATUS_PATH") or "/status"

  if self.ip == "" then
    self:error("Set QuickApp variable TESY_IP first.")
    return
  end

  -- Start polling
  self:poll()
end

-- ===== Polling =====
function QuickApp:poll()
  self:rawHttpGet(self.statusPath,
    function(raw)
      local s, err = self:extractJsonFromHttp(raw)
      if not s then
        self:error(err)
        self:setErrorState("Data parse error")
        self:debug("RAW head:\n" .. tostring(raw):sub(1, 350))
        return
      end

      -- Map BelliSlimo values (showers)
      local cur = toNum(s.cur_shower)
      local ref = toNum(s.ref_shower)
      local mx  = toNum(s.max_shower)

      self:debug(string.format(
        "cur=%s ref=%s max=%s heater=%s watts=%s mode=%s power=%s boost=%s inet=%s err=%s count_down_timer=%s",
        tostring(cur), tostring(ref), tostring(mx),
        tostring(s.heater_state), tostring(s.watts), tostring(s.mode),
        tostring(s.power_sw), tostring(s.boost), tostring(s.inet), tostring(s.err_flag), tostring(s.count_down_timer)
      ))

      -- Make current showers the main QA value
      self:updateProperty("value", cur or 0)

      -- If you add UI labels in QA editor, you can update them here:
      local manual = (s.mode == "1")
      local boostString = (s.boost == tostring(1) and "on" or "off")
      local timerOn = (s.heater_state ~= "READY")

      self:updateView("lblCur", "text", "Current: " .. tostring(cur) .. " showers")
      self:updateView("lblTgt", "text", "Target: " .. tostring(ref) .. " showers")
      self:updateView("lblState", "text", "State: " .. tostring(s.heater_state))
      self:updateView("lblPwr", "text", "Power: " .. tostring(s.power_sw))
      self:updateView("lblBoost", "text", "Boost: " .. boostString)
      self:updateView("ddMode", "selectedItem", s.mode)

      local manual = (s.mode == "1")
      local timerOn = (s.heater_state ~= "READY")

      self:updateView("oneBtn",   "visible", manual)
      self:updateView("twoBtn",   "visible", manual)
      self:updateView("threeBtn", "visible", manual)
      self:updateView("fourBtn",  "visible", manual)
      self:updateView("lblTimer",  "visible", timerOn)
      local timerText = self:formatCountdown(s.count_down_timer)
      self:updateView("lblTimer", "text", "Heating time: " .. timerText)

      if tostring(s.err_flag) ~= "0" then
        self:setErrorState("Boiler error code: " .. tostring(s.err_flag))
      else
        self:setErrorState(nil)
      end
    end,
    function(e)
      self:error("RAW poll error: " .. tostring(e))
      self:setErrorState("RAW poll error: " .. tostring(e))
    end
  )

  fibaro.setTimeout(self.pollSec * 1000, function()
    self:poll()
  end)
end

-- ===== Generic command helper (use once you know the setter paths) =====
function QuickApp:rawGetCommand(path)
  self:debug("CMD GET " .. path)
  self:rawHttpGet(path,
    function(raw)
      local j, err = self:extractJsonFromHttp(raw)
      if j then
        self:debug("CMD resp JSON: " .. json.encode(j))
      else
        -- Some setters respond non-JSON; show first part
        self:debug("CMD resp raw head:\n" .. tostring(raw):sub(1, 250))
      end
      -- refresh state
      self:poll()
    end,
    function(e)
      self:setErrorState("CMD error: " .. tostring(e))
      self:error("CMD error: " .. tostring(e))
    end
  )
end

-- Example placeholders (NOT guaranteed; depends on your firmware)
-- Once you sniff UI network calls, we’ll set the real ones:
function QuickApp:setTargetShowers(t)
  local path = "/setTemp?val=" .. tostring(t)
  self:rawGetCommand(path)
  self:debug("Set target showers to " .. t)
end

function QuickApp:setBoost(on)
  local v = (on and 1 or 0)
  local path = "/boostSW?mode=" .. tostring(v)
  self:rawGetCommand(path)
end

function QuickApp:setPower(on)
  local path = "/power?val=" .. (on and "on" or "off")
  self:rawGetCommand(path)
end

function QuickApp:setMode(m)
  local path = "/modeSW?mode=" .. tostring(m)
  self:rawGetCommand(path)
  self:debug("Set mode to " .. m)
end

function QuickApp:ddModeChanged(event)
  -- event.value usually contains the label
  local v = event.values[1]

  -- Replace this path with the real setter once we confirm it
  -- For now, just log what we'd do:
  self:setMode(v)
end

function QuickApp:onBtnPressed(event)
  self:setPower(true)
end

function QuickApp:offBtnPressed(event)
  self:setPower(false)
end

function QuickApp:oneBtnPressed(event)
  self:setTargetShowers(1)
end

function QuickApp:twoBtnPressed(event)
  self:setTargetShowers(2)
end

function QuickApp:threeBtnPressed(event)
  self:setTargetShowers(3)
end

function QuickApp:fourBtnPressed(event)
  self:setTargetShowers(4)
end

function QuickApp:bstOnPressed(event)
  self:setBoost(true)
end

function QuickApp:bstOffPressed(event)
  self:setBoost(false)
end

function QuickApp:setErrorState(msg)
  self.errorState = msg

  if msg == nil then
    -- Hide error label
    self:updateView("lblErr", "visible", false)
  else
    -- Show error label + set text
    self:updateView("lblErr", "text", msg)
    self:updateView("lblErr", "visible", true)
  end
end