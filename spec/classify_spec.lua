local classify = require("zyt.classify")
local rules = require("zyt.rules")

local R = assert(rules.normalise({
  apps = { Mail = "work", Spotify = "private", iTerm2 = "repo", Code = "repo", Kiro = "repo" },
  titles = { { contains = "jira", class = "work" }, { contains = "GitHub", class = "private" } },
  remotes = { { match = "git.example.com", class = "work" }, { match = "github.com", class = "private" } },
  repoRoots = { "~/git" },
  signalSeconds = 300,
}, "/Users/me"))

local remotes = {
  ["/Users/me/git/infra"] = "ssh://git@git.example.com:7999/team/infra.git",
  ["/Users/me/git/budget"] = "git@github.com:me/budget.git",
}
-- Like repo.resolver: any path inside a repository answers with its remote.
local function resolve(path)
  for prefix, remote in pairs(remotes) do
    if path == prefix or path:sub(1, #prefix + 1) == prefix .. "/" then
      return remote
    end
  end
  return nil
end

local function decide(obs)
  obs.resolve = obs.resolve or resolve
  return classify.decide(R, obs)
end

describe("classify.decide", function()
  it("takes the application's word first", function()
    assert.same({ "work", "app" }, { decide({ app = "Mail", title = "GitHub notifications" }) })
    assert.same({ "private", "app" }, { decide({ app = "Spotify", title = "" }) })
  end)

  it("reads titles without caring about case", function()
    assert.same({ "work", "title" }, { decide({ app = "firefox", title = "SIG-1 · JIRA" }) })
    assert.same({ "private", "title" }, { decide({ app = "firefox", title = "Pull requests · GitHub" }) })
  end)

  it("has no opinion on a window it does not know", function()
    assert.is_nil(decide({ app = "Finder", title = "Downloads" }))
    assert.is_nil(decide({ app = nil, title = nil }))
  end)

  describe("for a repository application", function()
    it("asks the working directory first", function()
      assert.same({ "work", "cwd" }, { decide({ app = "iTerm2", title = "GitHub", cwd = "/Users/me/git/infra" }) })
    end)

    it("finds the repository in the title when there is no working directory", function()
      assert.same(
        { "private", "repo" },
        { decide({ app = "Code", title = "● main.go — budget — Visual Studio Code" }) }
      )
      -- a path in the title is read as a path, before any word is tried as a name
      assert.same({ "work", "path" }, { decide({ app = "iTerm2", title = "me@mac: ~/git/infra" }) })
      assert.same({ "work", "repo" }, { decide({ app = "iTerm2", title = "me@mac: infra (zsh)" }) })
    end)

    it("reads an absolute path out of the title, with ~ expanded", function()
      assert.same(
        { "work", "path" },
        { decide({ app = "Code", title = "● main.tf — git — /Users/me/git/infra/stacks/prod" }) }
      )
      assert.same({ "private", "path" }, { decide({ app = "Kiro", title = "notes.md — ~/git/budget/docs" }) })
      assert.is_nil(decide({ app = "Code", title = "readme — /Users/me/elsewhere/file" }))
    end)

    it("falls back to a recent note from a tool", function()
      local signal = { age = 60, remote = "git@github.com:me/budget.git" }
      assert.same({ "private", "llm" }, { decide({ app = "Code", title = "git", signal = signal }) })
    end)

    it("ignores a stale note", function()
      local signal = { age = 301, remote = "git@github.com:me/budget.git" }
      assert.is_nil(decide({ app = "Code", title = "git", signal = signal }))
    end)

    it("lets the tool's repository decide while nobody is typing", function()
      local signal = { age = 30, remote = "ssh://git@git.example.com:7999/team/infra.git" }
      -- Spotify is private by its own rule, but nobody has touched the machine
      -- for a while and a session is working in the work repository.
      assert.same({ "work", "llm" }, { decide({ app = "Spotify", title = "", idle = 900, signal = signal }) })
      -- typing again: the window in front decides
      assert.same({ "private", "app" }, { decide({ app = "Spotify", title = "", idle = 3, signal = signal }) })
      -- a stale note, or one without a known remote, changes nothing
      assert.same(
        { "private", "app" },
        { decide({ app = "Spotify", title = "", idle = 900, signal = { age = 999, remote = signal.remote } }) }
      )
      assert.same(
        { "private", "app" },
        { decide({ app = "Spotify", title = "", idle = 900, signal = { age = 30, remote = nil } }) }
      )
    end)

    it("still reads the title rules when no repository is found", function()
      assert.same({ "work", "title" }, { decide({ app = "iTerm2", title = "jira export" }) })
    end)
  end)
end)

describe("classify.tokens", function()
  it("splits on whitespace and path separators and strips decoration", function()
    assert.same(
      { "main.go", "budget", "Visual", "Studio", "Code" },
      classify.tokens("● main.go — budget — Visual Studio Code")
    )
    assert.same({ "me@mac", "git", "infra" }, classify.tokens("me@mac: ~/git/infra"))
    assert.same({}, classify.tokens(nil))
  end)
end)

describe("classify.paths", function()
  it("finds every absolute path and expands the home directory", function()
    assert.same(
      { "/Users/me/git/infra/stacks", "/Users/me/git/budget" },
      classify.paths("a — /Users/me/git/infra/stacks — ~/git/budget", "/Users/me")
    )
    assert.same({}, classify.paths("no path here", "/Users/me"))
    assert.same({}, classify.paths(nil, "/Users/me"))
  end)
end)

describe("classify.remoteClass", function()
  it("matches the first rule whose text is in the URL", function()
    assert.equals("work", classify.remoteClass(R, "https://git.example.com/scm/x/y.git"))
    assert.is_nil(classify.remoteClass(R, "https://gitlab.com/x/y.git"))
    assert.is_nil(classify.remoteClass(R, nil))
  end)
end)
