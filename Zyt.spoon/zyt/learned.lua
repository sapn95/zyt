--- Answers the person gave when the rules had none: one per repository or
--- per application, kept so the same question is never asked twice.
local M = {}

local ANSWERS = { work = true, private = true, inherit = true }

--- The key a question is filed under: the repository when one was found,
--- the application otherwise. Nil when there is nothing to ask about.
function M.key(remote, app)
  if type(remote) == "string" and remote ~= "" then
    return "remote:" .. remote
  end
  if type(app) == "string" and app ~= "" then
    return "app:" .. app
  end
  return nil
end

--- What was answered for `key`: "work", "private", "inherit" (do not ask
--- again, keep whatever is running) or nil.
function M.lookup(store, key)
  local answer = key and store[key]
  if ANSWERS[answer] then
    return answer
  end
  return nil
end

--- Record an answer. Anything that is not one of the three is ignored.
function M.remember(store, key, answer)
  if key and ANSWERS[answer] then
    store[key] = answer
  end
  return store
end

--- Whether `key` may be asked about at `now`: never asked, or asked longer
--- than `cooldown` seconds ago and left unanswered.
function M.due(asked, key, now, cooldown)
  local last = asked[key]
  return last == nil or now - last >= cooldown
end

return M
