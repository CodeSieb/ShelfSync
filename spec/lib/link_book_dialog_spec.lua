-- "Link book" searches the provider; when that fails (offline, or the
-- provider blocks the search), the reason is shown instead of nothing.

local mocks = require("spec.support.koreader_mocks")
local UIManager = mocks.UIManager

local BaseProvider = require("shelfsync/lib/common/base_provider")

describe("BaseProvider:showLinkBookDialog", function()
  local shown, dialogs, provider, original_show

  before_each(function()
    mocks.reset()
    shown, dialogs = {}, {}
    original_show = UIManager.show
    UIManager.show = function(_, widget) table.insert(shown, widget) end

    provider = BaseProvider:new {
      label = "Goodreads",
      ui = {
        document = {
          file = "/books/test.epub",
          getProps = function() return { title = "Oathbringer", authors = "Brandon Sanderson" } end,
        },
      },
      user = { getId = function() return 1 end },
      settings = { getLinkedBookId = function() return nil end },
      dialog_manager = {
        buildSearchDialog = function(_, title, books) table.insert(dialogs, { title = title, books = books }) end,
      },
      api = {
        findBookByIdentifiers = function() return nil end,
        findBooks = function() return {}, "Network not connected" end,
      },
    }
  end)

  after_each(function()
    UIManager.show = original_show
  end)

  it("shows why the search failed", function()
    provider:showLinkBookDialog(false)
    UIManager:_runUntilIdle()

    assert.equals(0, #dialogs)
    assert.equals(1, #shown)
    assert.equals("Couldn't search Goodreads: Network not connected", shown[1].text)
  end)

  it("opens the results when the search works", function()
    provider.api.findBooks = function() return { { book_id = "1", title = "Oathbringer" } } end
    provider:showLinkBookDialog(false)
    UIManager:_runUntilIdle()

    assert.equals(0, #shown)
    assert.equals(1, #dialogs)
    assert.equals("Oathbringer", dialogs[1].books[1].title)
  end)
end)
