local transcript = require("zyt.transcript")

local function jsonl(...)
  return table.concat({ ... }, "\n") .. "\n"
end

local function keys(candidates)
  local out = {}
  for _, candidate in ipairs(candidates) do
    out[#out + 1] = candidate.key
  end
  return out
end

describe("transcript.naming", function()
  it("offers the name the person typed in before the one the tool made up", function()
    local text = jsonl(
      '{"type":"ai-title","aiTitle":"Whatever it is about"}',
      '{"type":"custom-title","customTitle":"massy-ux"}',
      '{"type":"last-prompt","lastPrompt":"and then"}'
    )
    local candidates = transcript.naming(text, 3)
    assert.same({ "customTitle", "aiTitle", "lastPrompt" }, keys(candidates))
    assert.equal('{"type":"custom-title","customTitle":"massy-ux"}', candidates[1].line)
  end)

  it("takes the newest of each kind", function()
    local text = jsonl(
      '{"type":"ai-title","aiTitle":"An older name"}',
      '{"type":"last-prompt","lastPrompt":"one"}',
      '{"type":"ai-title","aiTitle":"The name it goes by"}',
      '{"type":"last-prompt","lastPrompt":"two"}'
    )
    local candidates = transcript.naming(text, 1)
    assert.same({ "aiTitle", "lastPrompt" }, keys(candidates))
    assert.equal('{"type":"ai-title","aiTitle":"The name it goes by"}', candidates[1].line)
    assert.equal('{"type":"last-prompt","lastPrompt":"two"}', candidates[2].line)
  end)

  it("keeps the one before it, for a line that was half written", function()
    -- The file is appended to while it is read, and a slice taken from the end
    -- of a long one starts in the middle of a line: either way the newest line
    -- can be half of one, and only the decoder can tell.
    local text = jsonl('{"type":"ai-title","aiTitle":"Whole"}', '{"type":"ai-title","aiTitle":"Half of')
    local candidates = transcript.naming(text, 3)
    assert.equal(2, #candidates)
    assert.equal('{"type":"ai-title","aiTitle":"Half of', candidates[1].line)
    assert.equal('{"type":"ai-title","aiTitle":"Whole"}', candidates[2].line)
  end)

  it("keeps no more of a kind than it was asked for", function()
    local lines = {}
    for index = 1, 6 do
      lines[index] = ('{"type":"ai-title","aiTitle":"name %d"}'):format(index)
    end
    local candidates = transcript.naming(jsonl(table.unpack(lines)), 2)
    assert.equal(2, #candidates)
    assert.equal('{"type":"ai-title","aiTitle":"name 6"}', candidates[1].line)
    assert.equal('{"type":"ai-title","aiTitle":"name 5"}', candidates[2].line)
  end)

  it("says nothing about a transcript that names nothing", function()
    assert.same({}, transcript.naming(jsonl('{"type":"user"}', '{"type":"assistant"}'), 3))
    assert.same({}, transcript.naming("", 3))
    assert.same({}, transcript.naming(nil, 3))
  end)

  it("does not mind whitespace the writer might put in", function()
    local candidates = transcript.naming(jsonl('{ "type": "ai-title", "aiTitle": "Spaced out" }'), 3)
    assert.equal(1, #candidates)
    assert.equal("aiTitle", candidates[1].key)
  end)
end)
