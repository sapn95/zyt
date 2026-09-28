local transcript = require("zyt.transcript")

local function jsonl(...)
  return table.concat({ ... }, "\n") .. "\n"
end

describe("transcript.newest", function()
  it("picks the newest name and the newest prompt", function()
    local text = jsonl(
      '{"type":"ai-title","aiTitle":"An older name"}',
      '{"type":"user","message":{"content":"hello"}}',
      '{"type":"last-prompt","lastPrompt":"one"}',
      '{"type":"ai-title","aiTitle":"The name it goes by"}',
      '{"type":"last-prompt","lastPrompt":"two"}'
    )
    local title, prompt = transcript.newest(text)
    assert.equal('{"type":"ai-title","aiTitle":"The name it goes by"}', title)
    assert.equal('{"type":"last-prompt","lastPrompt":"two"}', prompt)
  end)

  it("says nothing about a transcript that names nothing", function()
    assert.same({}, { transcript.newest(jsonl('{"type":"user"}', '{"type":"assistant"}')) })
    assert.same({}, { transcript.newest("") })
    assert.same({}, { transcript.newest(nil) })
  end)

  it("offers each on its own", function()
    local title, prompt = transcript.newest(jsonl('{"type":"ai-title","aiTitle":"Alone"}'))
    assert.is_string(title)
    assert.is_nil(prompt)
    title, prompt = transcript.newest(jsonl('{"type":"last-prompt","lastPrompt":"Alone"}'))
    assert.is_nil(title)
    assert.is_string(prompt)
  end)

  it("does not mind whitespace the writer might put in", function()
    local title = transcript.newest(jsonl('{ "type": "ai-title", "aiTitle": "Spaced out" }'))
    assert.equal('{ "type": "ai-title", "aiTitle": "Spaced out" }', title)
  end)

  it("leaves the half line a slice starts with where it is", function()
    -- A slice taken from the end of a long file starts in the middle of a line.
    -- Most of the time it no longer looks like anything and is passed over.
    local text = jsonl('le":"Half a line"}', '{"type":"ai-title","aiTitle":"Whole"}')
    assert.equal('{"type":"ai-title","aiTitle":"Whole"}', (transcript.newest(text)))
  end)

  it("hands back a line that looks the part, for the adapter to decode", function()
    -- And when the cut leaves enough of one to look like an entry, it comes
    -- back as it is: json is what says it is no line, one step further on.
    local title = transcript.newest(jsonl('ing","type":"ai-title","aiTitle":"Half"}'))
    assert.equal('ing","type":"ai-title","aiTitle":"Half"}', title)
  end)
end)
