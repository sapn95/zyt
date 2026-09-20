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
  noIdleApps = {},
  repoRoots = { "~/git" },
  remotes = {},
  apps = {},
  titles = {},
}

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
  for _, key in ipairs({ "tickSeconds", "idleSeconds", "signalSeconds" }) do
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
    root = root:gsub("^~", home or "")
    roots[i] = (root:gsub("/+$", ""))
  end
  rules.repoRoots = roots

  local noIdle = {}
  for _, app in ipairs(rules.noIdleApps) do
    noIdle[app] = true
  end
  rules.noIdleApps = noIdle

  return rules
end

return M
