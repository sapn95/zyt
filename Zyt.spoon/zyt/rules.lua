--- The rules file, with its defaults and the checks that turn a decoded JSON
--- object into a table the rest of the core can trust without looking twice.
local M = {}

local CLASSES = { work = true, private = true }
M.CLASSES = CLASSES

M.defaults = {
  defaultClass = "work",
  labels = { work = "W", private = "P", away = "·" },
  tickSeconds = 30,
  idleSeconds = 600,
  signalSeconds = 300,
  chatSeconds = 14400,
  typingSeconds = 120,
  noIdleApps = {},
  repoRoots = { "~/git" },
  remotes = {},
  apps = {},
  titles = {},
  prompt = { enabled = true, seconds = 0, cooldownSeconds = 1800 },
  -- What the calendar is allowed to fill in. The command line holds the rest of
  -- this block, the tenant and the app it signs in to; nothing here needs them.
  meetings = {
    enabled = false,
    class = "work",
    statuses = { "busy", "oof", "tentative" },
    minimumSeconds = 300,
    lookbackHours = 24,
    -- How far the sync reaches and how often it runs. Forward as well as back,
    -- because a meeting that moved into next week has to be recognised there
    -- before the row it left behind can go.
    lookbackDays = 30,
    lookaheadDays = 60,
    syncHours = 6,
  },
}

-- Zero seconds is the panel waiting for an answer rather than going away by
-- itself, so it is a setting and not a missing one. Every other number in the
-- block is a length of time and has to be one.
local PROMPT_ZERO_OK = { seconds = true }

local function fail(format, ...)
  return nil, ("rules: " .. format):format(...)
end

local function pairsOf(list, key, name)
  local out = {}
  for i, rule in ipairs(list) do
    if type(rule) ~= "table" or type(rule[key]) ~= "string" or rule[key] == "" or not CLASSES[rule.class] then
      return fail("%s[%d] needs a non-empty %s and a class of work or private", name, i, key)
    end
    out[i] = { [key] = rule[key], class = rule.class }
  end
  return out
end

--- Merge a decoded rules file over the defaults and check every field.
--- Returns the rules, or nil and a message that names the field.
function M.normalise(raw, home)
  raw = raw or {}
  if type(raw) ~= "table" then
    return fail("the file has to hold a JSON object")
  end
  local rules = {}
  for key, default in pairs(M.defaults) do
    local value = raw[key]
    if value == nil then
      value = default
    end
    rules[key] = value
  end

  if not CLASSES[rules.defaultClass] then
    return fail("defaultClass has to be work or private, not %q", tostring(rules.defaultClass))
  end
  for _, key in ipairs({ "tickSeconds", "idleSeconds", "signalSeconds", "chatSeconds", "typingSeconds" }) do
    if type(rules[key]) ~= "number" or rules[key] <= 0 then
      return fail("%s has to be a positive number", key)
    end
  end
  for _, key in ipairs({ "labels", "apps", "titles", "remotes", "repoRoots", "noIdleApps" }) do
    if type(rules[key]) ~= "table" then
      return fail("%s has to be a JSON object or array", key)
    end
  end

  local labels = {}
  for key, default in pairs(M.defaults.labels) do
    labels[key] = rules.labels[key] or default
  end
  rules.labels = labels

  if type(rules.prompt) ~= "table" then
    return fail("prompt has to be a JSON object")
  end
  local prompt = {}
  for key, default in pairs(M.defaults.prompt) do
    local value = rules.prompt[key]
    if value == nil then
      value = default
    end
    if type(value) ~= type(default) then
      return fail("prompt.%s has to be a %s like %s", key, type(default), tostring(default))
    end
    local least = PROMPT_ZERO_OK[key] and 0 or 1
    if type(value) == "number" and value < least then
      return fail("prompt.%s has to be %d or more", key, least)
    end
    prompt[key] = value
  end
  rules.prompt = prompt

  if type(rules.meetings) ~= "table" then
    return fail("meetings has to be a JSON object")
  end
  local meetings = {}
  for key, default in pairs(M.defaults.meetings) do
    local value = rules.meetings[key]
    if value == nil then
      value = default
    end
    if type(value) ~= type(default) then
      return fail("meetings.%s has to be a %s like %s", key, type(default), tostring(default))
    end
    if type(value) == "number" and value < 0 then
      return fail("meetings.%s has to be 0 or more", key)
    end
    meetings[key] = value
  end
  -- A timer asked to fire every zero seconds fires without stopping, and every
  -- firing asks the calendar again.
  if meetings.syncHours <= 0 then
    return fail("meetings.syncHours has to be more than 0")
  end
  if not CLASSES[meetings.class] then
    return fail("meetings.class has to be work or private, not %q", tostring(meetings.class))
  end
  for index, status in ipairs(meetings.statuses) do
    if type(status) ~= "string" or status == "" then
      return fail("meetings.statuses[%d] has to be a non-empty string", index)
    end
  end
  rules.meetings = meetings

  for app, class in pairs(rules.apps) do
    if not (CLASSES[class] or class == "repo") then
      return fail("apps[%q] has to be work, private or repo, not %q", app, tostring(class))
    end
  end

  local titles, err = pairsOf(rules.titles, "contains", "titles")
  if not titles then
    return nil, err
  end
  rules.titles = titles
  local remotes
  remotes, err = pairsOf(rules.remotes, "match", "remotes")
  if not remotes then
    return nil, err
  end
  rules.remotes = remotes

  local roots = {}
  for i, root in ipairs(rules.repoRoots) do
    if type(root) ~= "string" or root == "" then
      return fail("repoRoots[%d] has to be a non-empty string", i)
    end
    root = root:gsub("^~", function()
      return home or ""
    end)
    roots[i] = (root:gsub("/+$", ""))
  end
  rules.repoRoots = roots

  local noIdle = {}
  for _, app in ipairs(rules.noIdleApps) do
    noIdle[app] = true
  end
  rules.noIdleApps = noIdle
  rules.home = home or ""

  return rules
end

return M
