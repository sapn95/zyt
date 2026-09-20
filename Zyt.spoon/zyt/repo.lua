--- Which remote a directory belongs to, read from the repository's own config
--- file. No git process is started: a title can name a directory thirty times
--- a minute, and this has to stay cheap enough for that.
local M = {}

local function parent(path)
  local up = path:match("^(.*)/[^/]+$")
  if up == nil or up == "" then
    return "/"
  end
  return up
end

--- The config file of the repository `path` is inside of, or nil. A worktree
--- and a submodule keep a `gitdir:` pointer where the directory would be; a
--- worktree's config is the main repository's.
function M.configPath(path, fs)
  local dir = path
  for _ = 1, 64 do
    local dotgit = dir .. "/.git"
    if fs.read(dotgit .. "/config") then
      return dotgit .. "/config"
    end
    local pointer = fs.read(dotgit)
    if pointer then
      local gitdir = pointer:match("gitdir:%s*([^\r\n]+)")
      if gitdir then
        if gitdir:sub(1, 1) ~= "/" then
          gitdir = dir .. "/" .. gitdir
        end
        local common = gitdir:match("^(.*/%.git)/worktrees/")
        return (common or gitdir) .. "/config"
      end
    end
    if dir == "/" then
      return nil
    end
    dir = parent(dir)
  end
  return nil
end

--- The URL of the named remote (origin unless told otherwise), or nil.
function M.remote(path, fs, name)
  local config = M.configPath(path, fs)
  local text = config and fs.read(config)
  if not text then
    return nil
  end
  local section = text:match('%[remote "' .. (name or "origin") .. '"%]([^%[]*)')
  return section and section:match("url%s*=%s*(%S+)") or nil
end

--- A resolver that remembers its answers, misses included, for `ttl` seconds.
function M.resolver(fs, ttl, clock)
  local cache = {}
  return function(path)
    path = path:gsub("/+$", "")
    if path == "" then
      path = "/"
    end
    local now = clock()
    local hit = cache[path]
    if hit and now - hit.at < ttl then
      return hit.remote
    end
    local remote = M.remote(path, fs)
    cache[path] = { at = now, remote = remote }
    return remote
  end
end

--- The real file system. A directory reads as nil, which is what the walk
--- above relies on to tell `.git/` from a `.git` pointer file.
M.fs = {
  read = function(path)
    local file = io.open(path, "r")
    if not file then
      return nil
    end
    local text = file:read("a")
    file:close()
    return text
  end,
}

return M
