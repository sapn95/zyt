local classify = require("zyt.classify")
local rules = require("zyt.rules")

local R = assert(rules.normalise({
  apps = { Mail = "work", Spotify = "private", iTerm2 = "repo", Code = "repo" },
  titles = { { contains = "jira", class = "work" }, { contains = "GitHub", class = "private" } },
  remotes = { { match = "git.example.com", class = "work" }, { match = "github.com", class = "private" } },
  repoRoots = { "~/git" },
  signalSeconds = 300,
}, "/Users/me"))

local remotes = {
  ["/Users/me/git/infra"] = "ssh://git@git.example.com:7999/team/infra.git",
  ["/Users/me/git/budget"] = "git@github.com:me/budget.git",
}
local function resolve(path)
  return remotes[path]
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
    assert.same({ "work", "title" }, { decide({ app = "firefox", title = "ABC-1 · JIRA" }) })
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
      assert.same({ "work", "repo" }, { decide({ app = "iTerm2", title = "me@mac: ~/git/infra" }) })
    end)

    it("falls back to a recent note from a tool", function()
      local signal = { age = 60, remote = "git@github.com:me/budget.git" }
      assert.same({ "private", "llm" }, { decide({ app = "Code", title = "git", signal = signal }) })
    end)

    it("ignores a stale note", function()
      local signal = { age = 301, remote = "git@github.com:me/budget.git" }
      assert.is_nil(decide({ app = "Code", title = "git", signal = signal }))
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

describe("classify.remoteClass", function()
  it("matches the first rule whose text is in the URL", function()
    assert.equals("work", classify.remoteClass(R, "https://git.example.com/scm/x/y.git"))
    assert.is_nil(classify.remoteClass(R, "https://gitlab.com/x/y.git"))
    assert.is_nil(classify.remoteClass(R, nil))
  end)
end)
