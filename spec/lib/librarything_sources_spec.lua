-- Books that aren't a LibraryThing work yet: "Link book" falls back to the
-- chosen book source (its "Add books" search), and picking an edition adds
-- it the way that page does, which creates the work.

local mocks = require("spec.support.koreader_mocks")
local dkjson = require("dkjson")
local json = require("json")

local Api = require("shelfsync/lib/librarything/api")
local LibraryThing = require("shelfsync/lib/librarything/provider")
local LIBRARYTHING = require("shelfsync/lib/librarything/constants")
local SETTING = require("shelfsync/lib/common/constants/settings")

local parse = Api._parse

-- A record as the Vlaamse Centrale Catalogus returns it (trimmed).
local RECORD = {
  books_title = "Lang leve de chaos",
  books_author = "Brennan, Sarah Rees",
  books_otherauthors = { { text = "Vertaler, Een", role = "" } },
  books_otherauthors_roles = {},
  books_ISBN = "9789021059143",
  books_date = "2026",
  books_publication = "Amsterdam : Van Goor, 2026",
  books_pages = "352",
  books_lang = { "dut" },
  isbnA = { "9789021059143" },
  books_UPC = dkjson.null,
  subjects = { { order = 0, tag = "650", subfields = { "a", "Fantasy" } } },
  format_toplevelN = 1,
  books_source = "Vlaamse Centrale Catalogus",
}

local function escape_attr(text)
  return (text:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function results_page(records)
  local rows = {}
  for i, record in ipairs(records) do
    table.insert(rows, ('<div class="book addbooks_book_row" data-record="%s" data-outputnum="%d"><a>Add Book</a></div>')
      :format(escape_attr(dkjson.encode(record)), i - 1))
  end
  return '<div class="booklist">' .. table.concat(rows) .. "</div>"
end

describe("LibraryThing book sources", function()
  local api, values, calls, works_found

  before_each(function()
    mocks.reset()
    stub(json, "decode", function(text) return dkjson.decode(text) end)
    values = { [SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc" }
    calls, works_found = {}, {}
    api = setmetatable({
      settings = {
        readSetting = function(_, key) return values[key] end,
        updateSetting = function(_, key, value) values[key] = value end,
        debugLog = function() end,
        debugWarn = function() end,
      },
      searchWorks = function() return works_found end,
      request = function(_, path, opts)
        local form = {}
        for _, field in ipairs(opts and opts.form or {}) do form[field[1]] = field[2] end
        table.insert(calls, { path = path, form = form, fields = opts and opts.form, opts = opts })
        local function reply(body) return 200, opts.extract and opts.extract(body) or body end
        if path == "/response_search_beta_lt2.php" then
          return reply(results_page({ RECORD, { books_title = "Something else", books_author = "Other, An" } }))
        elseif path == "/addbook_regular.php" then
          -- Newest first, as LibraryThing lists recently added books.
          return reply('<a href="/work/37461411/book/325758846">x</a><a href="/work/8556314/book/325473821">y</a>')
        end
        error("unexpected request " .. path)
      end,
    }, { __index = Api })
  end)

  it("reads each result's record, even with a > in it", function()
    local record = { books_title = "A > B", books_author = "Writer, A" }
    local raw = parse.extract_source_records(results_page({ record, RECORD }))
    local lines = {}
    for line in raw:gmatch("[^\n]+") do table.insert(lines, (dkjson.decode(parse.decode_entities(line)))) end
    assert.equals(2, #lines)
    assert.equals("A > B", lines[1].books_title)
    assert.equals("9789021059143", lines[2].books_ISBN)
  end)

  it("encodes a record as LibraryThing's page posts it", function()
    local fields = {}
    parse.append_record_fields(fields, nil, RECORD)
    local text = {}
    for _, field in ipairs(fields) do table.insert(text, field[1] .. "=" .. field[2]) end
    assert.same({
      "books_ISBN=9789021059143",
      "books_author=Brennan, Sarah Rees",
      "books_date=2026",
      "books_lang[]=dut",
      "books_otherauthors[0][role]=",
      "books_otherauthors[0][text]=Vertaler, Een",
      "books_pages=352",
      "books_publication=Amsterdam : Van Goor, 2026",
      "books_source=Vlaamse Centrale Catalogus",
      "books_title=Lang leve de chaos",
      "format_toplevelN=1",
      "isbnA[]=9789021059143",
      "subjects[0][order]=0",
      "subjects[0][subfields][]=a",
      "subjects[0][subfields][]=Fantasy",
      "subjects[0][tag]=650",
    }, text)
  end)

  it("searches the chosen book source when no work matches, as editions to pick", function()
    values[SETTING.LIBRARYTHING.ADD_SOURCE] = { id = 1065, name = "Vlaamse Centrale Catalogus" }
    local books = api:findBooks("Lang leve de chaos", "Brennan, Sarah Rees")

    assert.equals(2, #books)
    assert.equals("Lang leve de chaos", books[1].title)
    assert.equals("Sarah Rees Brennan", books[1].contributions[1].author.name)
    assert.equals("9789021059143", books[1].isbn)
    assert.equals("Vlaamse Centrale Catalogus", books[1].edition_format)
    assert.equals(352, books[1].pages)
    assert.is_true(api:isSourceEdition(books[1].book_id))
    assert.equals(1065, calls[1].form.libraryChoice)
    assert.equals("Lang leve de chaos Brennan Sarah Rees", calls[1].form.form_find)
  end)

  it("uses Amazon.com by default, and searches no source when that's turned off", function()
    assert.equals(1197, api:addSource().id)
    api:setAddSource(false)
    assert.same({}, api:findBooks("Lang leve de chaos", "Brennan, Sarah Rees"))
    assert.equals(0, #calls)
  end)

  it("never offers a source edition to automatic linking", function()
    assert.same({}, api:findBooks("Lang leve de chaos", "Brennan, Sarah Rees", 1, { autolink = true }))
    assert.equals(0, #calls)
  end)

  it("doesn't search a source when there's a work", function()
    works_found = { { book_id = "37461411", title = "Lang leve de chaos" } }
    assert.equals("37461411", api:findBooks("Lang leve de chaos", "Brennan, Sarah Rees")[1].book_id)
    assert.equals(0, #calls)
  end)

  it("adds the picked edition once, and returns the work it made", function()
    local books = api:findBooks("Lang leve de chaos", "Brennan, Sarah Rees")
    local work_id, copy_id = api:addSourceEdition(books[1].book_id, { 1 })

    assert.equals("37461411", work_id)
    assert.equals("325758846", copy_id)
    local add = calls[#calls]
    assert.equals("/addbook_regular.php", add.path)
    assert.is_true(add.opts.no_retry)
    assert.equals("Lang leve de chaos", add.form.books_title)
    assert.equals(1, add.form["books_collections[]"])
    assert.equals("325758846", values[SETTING.LIBRARYTHING.WORKS]["37461411"].copy)
    -- Picked again (e.g. a double tap), it isn't added twice.
    assert.is_nil(api:addSourceEdition(books[1].book_id, { 1 }))
  end)

  it("links the book to the work adding the edition made", function()
    local books = api:findBooks("Lang leve de chaos", "Brennan, Sarah Rees")
    local linked, updated = {}, {}
    api.findUserBook = function(_, work_id) return { book_id = work_id, id = "325758846", collections = {} } end
    api.updateUserBook = function(_, work_id, status_id)
      table.insert(updated, { work_id, status_id })
      return { book_id = work_id, id = "325758846", status_id = status_id }
    end
    local provider = LibraryThing:new {
      api = api,
      ui = { document = { file = "/books/chaos.epub" } },
      state = {},
      settings = { updateBookSetting = function(_, _, setting) linked = setting end },
    }

    assert.is_true(provider:linkBook({ book_id = books[1].book_id, title = books[1].title, pages = 352 }, "manual"))
    assert.equals("37461411", linked.book_id)
    assert.same({ { "37461411", LIBRARYTHING.STATUS.READING } }, updated)
  end)
end)
