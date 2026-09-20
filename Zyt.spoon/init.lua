--- === Zyt ===
---
--- Work or private: a menu-bar clock that knows which one is running. Every
--- half minute, and whenever another application comes to the front, it looks
--- at the frontmost window, asks the rules, and keeps the answer as a segment.
--- Locks, sleep and idle time end a segment; the rows go to a CSV that
--- `zyt week` turns into a booking proposal.
---
--- Everything that decides anything lives in `zyt/` and is tested there. This
--- file is the adapter: Hammerspoon on one side, those modules on the other.

local obj = {}
obj.__index = obj

obj.name = "Zyt"
obj.version = "0.1.0"
obj.author = "Sebastian Winterberger"
obj.license = "MIT"
obj.homepage = "https://github.com/sapn95/zyt"

obj.spoonPath = debug.getinfo(1, "S").source:match("^@(.*/)")
package.path = obj.spoonPath .. "?.lua;" .. obj.spoonPath .. "?/init.lua;" .. package.path

local rules = require("zyt.rules")
local classify = require("zyt.classify")
local repo = require("zyt.repo")
local tracker = require("zyt.tracker")
local totals = require("zyt.totals")
local learned = require("zyt.learned")

local HOME = os.getenv("HOME")

local function xdg(variable, fallback)
  local value = os.getenv(variable)
  if value and value ~= "" then
    return value
  end
  return HOME .. fallback
end

--- Zyt.configPath
--- Variable
--- The rules file. Set it before `:start()` to move it.
obj.configPath = xdg("XDG_CONFIG_HOME", "/.config") .. "/zyt/rules.json"

--- Zyt.statePath
--- Variable
--- Where the rows, the open segment and the tools' context notes live.
obj.statePath = xdg("XDG_STATE_HOME", "/.local/state") .. "/zyt"

--- Zyt.cli
--- Variable
--- The command the menu runs for the report: the checkout's own script when
--- the Spoon is linked from one, otherwise whatever `zyt` is on the PATH.
obj.cli = "zyt"

--- Zyt.cwdOf
--- Variable
--- Per application, a function that returns its working directory, for the
--- terminals whose title does not say. iTerm2 is answered over AppleScript.
obj.cwdOf = nil

obj.logger = hs.logger.new("zyt", "info")
obj.running = false
obj.override = nil
obj.locked = false
obj.asleep = false

-- ---------------------------------------------------------------------------
-- Files

local function readFile(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local text = file:read("a")
  file:close()
  return text
end

local function ensureDirectory(path)
  local built = ""
  for part in path:gmatch("[^/]+") do
    built = built .. "/" .. part
    if not hs.fs.attributes(built, "mode") then
      hs.fs.mkdir(built)
    end
  end
end

local function writeAtomically(path, contents)
  local temporary = path .. ".tmp"
  local file, err = io.open(temporary, "w")
  if not file then
    return nil, err
  end
  file:write(contents)
  file:close()
  return os.rename(temporary, path)
end

local function appendLine(path, line, header)
  local size = hs.fs.attributes(path, "size") or 0
  local file, err = io.open(path, "a")
  if not file then
    return nil, err
  end
  if size == 0 then
    file:write(header, "\n")
  end
  file:write(line, "\n")
  file:close()
  return true
end

local function isoLocal(t)
  local zone = os.date("%z", t)
  return os.date("%Y-%m-%dT%H:%M:%S", t) .. zone:sub(1, 3) .. ":" .. zone:sub(4, 5)
end

local clock = { iso = isoLocal }

function obj:complain(message)
  self.logger.e(message)
  hs.alert.show("zyt: " .. message, 4)
end

-- ---------------------------------------------------------------------------
-- Rules

function obj:loadRules()
  local raw = {}
  local text = readFile(self.configPath)
  if text then
    local ok, decoded = pcall(hs.json.decode, text)
    if ok and type(decoded) == "table" then
      raw = decoded
    else
      self:complain("the rules file is not valid JSON: " .. self.configPath)
    end
  end
  local normalised, err = rules.normalise(raw, HOME)
  if not normalised then
    self:complain(err)
    normalised = rules.normalise({}, HOME)
  end
  self.rules = normalised
  if self.state then
    self.state.rules = normalised
  end
  if self.running then
    self:armTimer()
  end
end

function obj:armTimer()
  if self.timer then
    self.timer:stop()
  end
  self.timer = hs.timer.doEvery(self.rules.tickSeconds, function()
    self:tick()
  end)
end

-- ---------------------------------------------------------------------------
-- Observing

local function focused()
  local window = hs.window.focusedWindow()
  local app = window and window:application() or hs.application.frontmostApplication()
  return app and app:name() or "", window and window:title() or "", app and app:bundleID() or nil
end

local function idleIsShort(idle)
  return type(idle) == "number" and idle < 120
end

local function iterm2Path()
  local ok, out = hs.osascript.applescript(
    'tell application "iTerm2" to tell current session of current window to get variable named "session.path"'
  )
  if ok and type(out) == "string" and out ~= "" then
    return out
  end
  return nil
end

function obj:signal()
  local text = readFile(self.statePath .. "/context.json")
  if not text then
    return nil
  end
  local ok, decoded = pcall(hs.json.decode, text)
  if not ok or type(decoded) ~= "table" or type(decoded.at) ~= "number" then
    return nil
  end
  return { age = os.time() - decoded.at, remote = decoded.remote, source = decoded.source, bundle = decoded.bundle }
end

function obj:observe(now)
  local app, title, bundle = focused()
  local idle = hs.host.idleTime()
  local signal = self:signal()
  local away, awaySince = tracker.presence(self.state, now, {
    idle = idle,
    app = app,
    locked = self.locked,
    asleep = self.asleep,
    working = signal ~= nil and signal.age <= self.rules.signalSeconds,
  })
  if away then
    return { away = true, awaySince = awaySince, app = app }
  end
  if self.override then
    return { class = self.override, source = "manual", app = app }
  end
  local cwdOf = self.cwdOf[app]
  local obs = {
    app = app,
    bundle = bundle,
    title = title,
    idle = idle,
    cwd = cwdOf and cwdOf() or nil,
    signal = signal,
    resolve = self.resolve,
  }
  local class, source = classify.decide(self.rules, obs)
  if not class then
    class, source = self:recall(now, obs)
  end
  return { class = class, source = source, app = app }
end

--- What the person answered the last time this window came up, or a fresh
--- question when nothing is known yet. Nil while the answer is pending: the
--- tracker keeps whatever was running (ADR 0002).
function obj:recall(now, obs)
  local remote
  if self.rules.apps[obs.app or ""] == "repo" then
    remote = classify.repositoryOf(self.rules, obs)
  end
  local key = learned.key(remote, obs.app)
  local answer = learned.lookup(self.learned, key)
  if answer == "work" or answer == "private" then
    return answer, "learned"
  end
  if answer == nil and key and self.rules.prompt.enabled and idleIsShort(obs.idle) then
    if learned.due(self.asked, key, now, self.rules.prompt.cooldownSeconds) then
      self.asked[key] = now
      self:ask(key, remote and remote:match("([^/:]+/[^/]+)%.git$") or remote or obs.app)
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Answers

function obj:loadLearned()
  self.learned = {}
  self.asked = {}
  local text = readFile(self.statePath .. "/learned.json")
  if text then
    local ok, decoded = pcall(hs.json.decode, text)
    if ok and type(decoded) == "table" then
      self.learned = decoded
    end
  end
end

function obj:saveLearned()
  writeAtomically(self.statePath .. "/learned.json", hs.json.encode(self.learned, true))
end

function obj:forget()
  self.learned = {}
  self.asked = {}
  os.remove(self.statePath .. "/learned.json")
  self:tick()
end

--- Zyt:ask(key, what)
--- Method
--- A small panel under the menu bar: Work, Private, or Don't ask. It goes
--- away by itself after `prompt.seconds`, and the class stays what it was
--- until it is answered.
function obj:ask(key, what)
  if self.prompt then
    return
  end
  local screen = hs.screen.mainScreen():frame()
  local w, h = 380, 92
  local canvas = hs.canvas.new({ x = screen.x + screen.w - w - 12, y = screen.y + 6, w = w, h = h })
  local function button(id, x, width, label, color)
    return {
      {
        id = id,
        type = "rectangle",
        action = "fill",
        frame = { x = x, y = 54, w = width, h = 28 },
        fillColor = color,
        roundedRectRadii = { xRadius = 6, yRadius = 6 },
        trackMouseUp = true,
      },
      {
        type = "text",
        text = label,
        textSize = 13,
        textColor = { white = 1 },
        textAlignment = "center",
        frame = { x = x, y = 58, w = width, h = 22 },
      },
    }
  end
  canvas:appendElements({
    type = "rectangle",
    action = "fill",
    fillColor = { red = 0.13, green = 0.13, blue = 0.15, alpha = 0.96 },
    roundedRectRadii = { xRadius = 10, yRadius = 10 },
  }, {
    type = "text",
    text = "zyt · whose time is this?",
    textSize = 12,
    textColor = { white = 0.7 },
    frame = { x = 14, y = 8, w = w - 28, h = 18 },
  }, {
    type = "text",
    text = what or "",
    textSize = 14,
    textColor = { white = 1 },
    frame = { x = 14, y = 26, w = w - 28, h = 22 },
  })
  for _, element in ipairs(button("work", 14, 100, "Work", { red = 0.20, green = 0.45, blue = 0.85 })) do
    canvas:appendElements(element)
  end
  for _, element in ipairs(button("private", 124, 100, "Private", { red = 0.55, green = 0.35, blue = 0.75 })) do
    canvas:appendElements(element)
  end
  for _, element in ipairs(button("inherit", 234, 132, "Don't ask", { red = 0.35, green = 0.35, blue = 0.38 })) do
    canvas:appendElements(element)
  end
  canvas:mouseCallback(function(_, event, id)
    if event == "mouseUp" then
      self:answer(key, id)
    end
  end)
  canvas:clickActivating(false)
  canvas:level(hs.canvas.windowLevels.floating)
  canvas:show()
  self.prompt = {
    canvas = canvas,
    key = key,
    timer = hs.timer.doAfter(self.rules.prompt.seconds, function()
      self:dismiss()
    end),
  }
end

function obj:dismiss()
  local prompt = self.prompt
  if not prompt then
    return
  end
  self.prompt = nil
  if prompt.timer then
    prompt.timer:stop()
  end
  prompt.canvas:delete()
end

function obj:answer(key, answer)
  learned.remember(self.learned, key, answer)
  self:saveLearned()
  self:dismiss()
  self:tick()
end

-- ---------------------------------------------------------------------------
-- Segments

function obj:append(row)
  local ok, err = appendLine(self.statePath .. "/intervals.csv", tracker.csv(row), tracker.header)
  if not ok then
    self:complain("could not write a row: " .. tostring(err))
  end
  self.rows = nil
end

function obj:persistOpen()
  local path = self.statePath .. "/open.json"
  if self.state.open then
    writeAtomically(path, hs.json.encode(self.state.open))
  else
    os.remove(path)
  end
end

function obj:readOpen()
  local text = readFile(self.statePath .. "/open.json")
  if not text then
    return nil
  end
  local ok, decoded = pcall(hs.json.decode, text)
  return ok and decoded or nil
end

function obj:closeNow()
  local closed = tracker.close(self.state, os.time())
  if closed then
    self:append(closed)
  end
  self:persistOpen()
  self:refresh({ away = true })
end

function obj:tick()
  local now = os.time()
  local obs = self:observe(now)
  local closed = tracker.observe(self.state, now, obs)
  if closed then
    self:append(closed)
  end
  self:persistOpen()
  self:refresh(obs)
end

--- Zyt:setOverride(class)
--- Method
--- Pin the class to "work" or "private" until the next lock, or pass nil to
--- let the rules decide again. Returns the status line.
function obj:setOverride(class)
  if class ~= "work" and class ~= "private" then
    class = nil
  end
  if class ~= self.override then
    -- The pin, and its end, are boundaries: what came before was decided
    -- one way, what follows is decided another, and the rows say which.
    self.override = class
    local closed = tracker.close(self.state, os.time())
    if closed then
      self:append(closed)
    end
  end
  self:tick()
  return self:statusJSON()
end

-- ---------------------------------------------------------------------------
-- Reading back

function obj:today()
  if not self.rows then
    self.rows = totals.parse(readFile(self.statePath .. "/intervals.csv"))
  end
  local now = os.time()
  local day = os.date("%Y-%m-%d", now)
  local sums = totals.forDay(self.rows, day)
  local open = self.state and self.state.open
  if open then
    local midnight = os.time({
      year = tonumber(day:sub(1, 4)),
      month = tonumber(day:sub(6, 7)),
      day = tonumber(day:sub(9, 10)),
      hour = 0,
    })
    local from = math.max(open.start, midnight)
    if now > from then
      sums[open.class] = sums[open.class] + (now - from)
    end
  end
  return sums
end

--- Zyt:status()
--- Method
--- What is running now and what today adds up to, as a table.
function obj:status()
  local open = self.state and self.state.open
  return {
    running = self.running,
    class = open and open.class or nil,
    source = open and open.source or nil,
    since = open and isoLocal(open.start) or nil,
    override = self.override,
    away = open == nil,
    today = self:today(),
    configPath = self.configPath,
    statePath = self.statePath,
  }
end

function obj:statusJSON()
  return hs.json.encode(self:status())
end

-- ---------------------------------------------------------------------------
-- Menu

function obj:copyReport()
  local out, ok = hs.execute(("%q week 2>&1"):format(self.cli), true)
  if ok then
    hs.pasteboard.setContents(out)
    hs.alert.show("zyt: this week's report is on the clipboard", 2)
  else
    self:complain("the report failed: " .. tostring(out))
  end
end

function obj:openRules()
  ensureDirectory(self.configPath:match("^(.*)/[^/]+$"))
  if not hs.fs.attributes(self.configPath, "mode") then
    writeAtomically(self.configPath, "{\n}\n")
  end
  hs.execute(("open %q"):format(self.configPath))
end

function obj:menu()
  local today = self:today()
  local function choice(title, class)
    return {
      title = title,
      checked = self.override == class,
      fn = function()
        self:setOverride(class)
      end,
    }
  end
  return {
    choice("Work", "work"),
    choice("Private", "private"),
    choice("Auto", nil),
    { title = "-" },
    {
      title = ("Today  %s work · %s private"):format(totals.format(today.work), totals.format(today.private)),
      disabled = true,
    },
    {
      title = "Copy this week's report",
      fn = function()
        self:copyReport()
      end,
    },
    { title = "-" },
    {
      title = "Open the rules file",
      fn = function()
        self:openRules()
      end,
    },
    {
      title = "Reload the rules",
      fn = function()
        self:loadRules()
        self:tick()
      end,
    },
    {
      title = "Forget the answers, ask again",
      fn = function()
        self:forget()
      end,
    },
    { title = "-" },
    {
      title = "Quit zyt",
      fn = function()
        self:stop()
      end,
    },
  }
end

function obj:refresh(obs)
  if not self.menubar then
    return
  end
  local labels = self.rules.labels
  local open = self.state.open
  local title = open and labels[open.class] or labels.away
  if self.override then
    title = "[" .. title .. "]"
  end
  self.menubar:setTitle(title)
  local what = open and (open.class .. " since " .. os.date("%H:%M", open.start) .. " (" .. open.source .. ")")
    or "away"
  if obs and obs.app and obs.app ~= "" then
    what = what .. " · " .. obs.app
  end
  self.menubar:setTooltip("zyt: " .. what)
end

-- ---------------------------------------------------------------------------
-- Lifecycle

function obj:watch()
  -- A switch to another application is looked at at once, so the menu-bar
  -- item changes when the window does and not up to a tick later.
  local A = hs.application.watcher
  self.appWatcher = A.new(function(_, event)
    if event == A.activated and self.running then
      self:tick()
    end
  end)
  self.appWatcher:start()

  local W = hs.caffeinate.watcher
  self.watcher = W.new(function(event)
    if event == W.screensDidLock or event == W.sessionDidResignActive then
      self.locked = true
      self:dismiss()
      self:closeNow()
    elseif event == W.screensDidUnlock or event == W.sessionDidBecomeActive then
      self.locked = false
      self.override = nil
      self:tick()
    elseif event == W.systemWillSleep then
      self.asleep = true
      self:closeNow()
    elseif event == W.systemDidWake then
      self.asleep = false
      self:tick()
    end
  end)
  self.watcher:start()
end

--- Zyt:start()
--- Method
--- Load the rules, pick up what a previous run left open, and start ticking.
function obj:start()
  if self.running then
    return self
  end
  ensureDirectory(self.statePath)
  self:loadRules()
  self:loadLearned()
  self.resolve = repo.resolver(repo.fs, 600, os.time)
  self.cwdOf = self.cwdOf or { iTerm2 = iterm2Path }
  local checkout = self.spoonPath .. "../scripts/zyt"
  if self.cli == "zyt" and hs.fs.attributes(checkout, "mode") then
    self.cli = checkout
  end

  self.state = tracker.new(self.rules, clock)
  local leftover = tracker.recover(self.state, self:readOpen())
  if leftover then
    self:append(leftover)
  end

  self.menubar = hs.menubar.new(true, "zyt")
  self.menubar:setMenu(function()
    return self:menu()
  end)
  self:watch()
  self:armTimer()
  local previousShutdown = hs.shutdownCallback
  hs.shutdownCallback = function()
    if self.running then
      self:closeNow()
    end
    if previousShutdown then
      previousShutdown()
    end
  end

  self.running = true
  _G.zyt = self
  self:tick()
  return self
end

--- Zyt:stop()
--- Method
--- Close the open segment, stop the timer and the watcher, take the item out
--- of the menu bar.
function obj:stop()
  if not self.running then
    return self
  end
  self:closeNow()
  self:dismiss()
  if self.timer then
    self.timer:stop()
    self.timer = nil
  end
  for _, key in ipairs({ "watcher", "appWatcher" }) do
    if self[key] then
      self[key]:stop()
      self[key] = nil
    end
  end
  if self.menubar then
    self.menubar:delete()
    self.menubar = nil
  end
  self.running = false
  return self
end

--- Zyt:bindHotkeys(mapping)
--- Method
--- Keys for `work`, `private` and `auto`, in the usual Spoon shape.
function obj:bindHotkeys(mapping)
  local actions = {
    work = function()
      self:setOverride("work")
    end,
    private = function()
      self:setOverride("private")
    end,
    auto = function()
      self:setOverride(nil)
    end,
  }
  hs.spoons.bindHotkeysToSpec(actions, mapping)
  return self
end

return obj
