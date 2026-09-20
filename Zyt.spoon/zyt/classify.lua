--- Which class a moment belongs to, from what is on screen and what the tools
--- have said about themselves. Pure: it is handed the rules, an observation and
--- a resolver, and it answers with a class and where the answer came from, or
--- with nothing when it does not know.
local M = {}

local function lower(text)
  return (text or ""):lower()
end

--- The class a git remote belongs to, by the first `remotes` rule whose
--- `match` is a substring of the URL.
function M.remoteClass(rules, remote)
  if type(remote) ~= "string" then
    return nil
  end
  for _, rule in ipairs(rules.remotes) do
    if remote:find(rule.match, 1, true) then
      return rule.class
    end
  end
  return nil
end

--- The words in a window title that could be a directory name: split on
--- whitespace and on path separators, with the decoration taken off the ends.
--- Lua patterns see bytes, so `%p` would leave a bullet or a dash alone; the
--- ends are trimmed to letters, digits and underscores instead.
function M.tokens(title)
  local out = {}
  for word in (title or ""):gmatch("%S+") do
    for part in word:gmatch("[^/:]+") do
      local trimmed = part:gsub("^[^%w_]+", "")
      trimmed = trimmed:gsub("[^%w_]+$", "")
      if #trimmed >= 2 then
        out[#out + 1] = trimmed
      end
    end
  end
  return out
end

local function fresh(rules, signal)
  return signal ~= nil and type(signal.age) == "number" and signal.age <= rules.signalSeconds
end

--- Absolute paths in a window title, `~` expanded. An editor whose title is
--- set to name the active file's folder is classified from that folder.
function M.paths(title, home)
  local out = {}
  for path in (title or ""):gmatch("~?/%S+") do
    if path:sub(1, 1) == "~" then
      path = (home or "") .. path:sub(2)
    end
    out[#out + 1] = path
  end
  return out
end

local function byRepository(rules, obs)
  if obs.cwd then
    local class = M.remoteClass(rules, obs.resolve(obs.cwd))
    if class then
      return class, "cwd"
    end
  end
  for _, path in ipairs(M.paths(obs.title, rules.home)) do
    local class = M.remoteClass(rules, obs.resolve(path))
    if class then
      return class, "path"
    end
  end
  for _, token in ipairs(M.tokens(obs.title)) do
    for _, root in ipairs(rules.repoRoots) do
      local class = M.remoteClass(rules, obs.resolve(root .. "/" .. token))
      if class then
        return class, "repo"
      end
    end
  end
  local signal = obs.signal
  if fresh(rules, signal) and (signal.bundle == nil or signal.bundle == obs.bundle) then
    local class = M.remoteClass(rules, signal.remote)
    if class then
      return class, "llm"
    end
  end
  return nil
end

local function byTitle(rules, title)
  title = lower(title)
  for _, rule in ipairs(rules.titles) do
    if title:find(lower(rule.contains), 1, true) then
      return rule.class, "title"
    end
  end
  return nil
end

--- Decide for one observation:
---   obs.app      the frontmost application's name
---   obs.bundle   its bundle id, matched against the one a tool's note names
---   obs.title    the focused window's title
---   obs.cwd      the working directory the application reported, if it can
---   obs.idle     seconds since the last input
---   obs.signal   { age = seconds, remote = url } left behind by a tool's hook
---   obs.resolve  function(path) -> remote url or nil
--- Returns class, source — or nil when nothing here has an opinion.
---
--- While nobody has typed for `idleSeconds` and a coding tool has reported in
--- recently, the tool's repository decides: the window in front is whatever
--- was left there, and the work is happening in the session. While somebody
--- is typing, the note only speaks for the application hosting the tool: a
--- second editor open on another repository is not the session's business.
function M.decide(rules, obs)
  if type(obs.idle) == "number" and obs.idle >= rules.idleSeconds and fresh(rules, obs.signal) then
    local class = M.remoteClass(rules, obs.signal.remote)
    if class then
      return class, "llm"
    end
  end
  local byApp = rules.apps[obs.app or ""]
  if rules.CLASSES and rules.CLASSES[byApp] or byApp == "work" or byApp == "private" then
    return byApp, "app"
  end
  if byApp == "repo" then
    local class, source = byRepository(rules, obs)
    if class then
      return class, source
    end
  end
  return byTitle(rules, obs.title)
end

return M
