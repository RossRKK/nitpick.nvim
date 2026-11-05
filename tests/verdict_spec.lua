-- The submit box lets the reviewer override the inferred verdict: <C-e> cycles
-- it, and the title shows what will go out and what was inferred.

local assert = require("luassert")
local nitpick = require("nitpick")

describe("nitpick._next_verdict", function()
  it("cycles comment, approve, request changes, and back", function()
    assert.equals("APPROVE", nitpick._next_verdict("COMMENT"))
    assert.equals("REQUEST_CHANGES", nitpick._next_verdict("APPROVE"))
    assert.equals("COMMENT", nitpick._next_verdict("REQUEST_CHANGES"))
  end)
end)

describe("nitpick._submit_title", function()
  it("names only the verdict while it matches the inferred one", function()
    assert.equals(
      "Submit as APPROVE · <C-e> change · 2 inline + 1 folded · summary optional",
      nitpick._submit_title("APPROVE", "APPROVE", 2, 1)
    )
  end)

  it("names the inferred verdict once it's overridden", function()
    assert.equals(
      "Submit as APPROVE (inferred COMMENT) · <C-e> change · 0 inline + 0 folded · summary optional",
      nitpick._submit_title("APPROVE", "COMMENT", 0, 0)
    )
  end)

  it("has nothing to override when no source inferred one", function()
    assert.equals(
      "Submit as REQUEST_CHANGES · <C-e> change · 1 inline + 0 folded · summary optional",
      nitpick._submit_title("REQUEST_CHANGES", nil, 1, 0)
    )
  end)
end)
