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

local function byRepository(rules, obs)
  if obs.cwd then
    local class = M.remoteClass(rules, obs.resolve(obs.cwd))
    if class then
      return class, "cwd"
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
  if signal and type(signal.age) == "number" and signal.age <= rules.signalSeconds then
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
---   obs.title    the focused window's title
---   obs.cwd      the working directory the application reported, if it can
---   obs.signal   { age = seconds, remote = url } left behind by a tool's hook
---   obs.resolve  function(path) -> remote url or nil
--- Returns class, source — or nil when nothing here has an opinion.
function M.decide(rules, obs)
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
