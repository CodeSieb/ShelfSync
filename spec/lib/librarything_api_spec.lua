local mocks = require("spec.support.koreader_mocks")

local Api = require("shelfsync/lib/librarything/api")
local Book = require("shelfsync/lib/common/book")
local LIBRARYTHING = require("shelfsync/lib/librarything/constants")
local SETTING = require("shelfsync/lib/common/constants/settings")
local json = require("json")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")

local parse = Api._parse
local STATUS = LIBRARYTHING.STATUS

local function base64(data)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  return ((data:gsub(".", function(c)
    local byte, bits = c:byte(), ""
    for i = 8, 1, -1 do bits = bits .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0") end
    return bits
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(bits)
    if #bits < 6 then return "" end
    local n = 0
    for i = 1, 6 do n = n + (bits:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
    return alphabet:sub(n + 1, n + 1)
  end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

-- A work page's "Your Book Information" panel, as librarything.com renders
-- it for a copy in the user's library (spacing inside tags included).
local function work_page(opts)
  opts = opts or {}
  local collections = {}
  for _, c in ipairs(opts.collections or {}) do
    table.insert(collections, ('<a class="coll_%d" href="/catalog/Reader/x">%s</a>'):format(c[1], c[2]))
  end
  local dates = {}
  for _, read in ipairs(opts.reads or {}) do
    local parts = {}
    if read[1] then table.insert(parts, 'Started: <span class="form_hint_dateformat">' .. read[1] .. '</span>') end
    if read[2] then table.insert(parts, 'Finished: <span class="form_hint_dateformat">' .. read[2] .. '</span>') end
    table.insert(dates, '<div title="19 days" class="" >' .. table.concat(parts, " &ndash; ") .. "</div>")
  end
  local panel = ""
  if opts.copy_id then
    panel = '<div class="book_info_area yourbook"><h2>Your Book Information</h2><dl>'
      .. '<dt >Publication</dt><dd  class="edit_field_pub_basic" >Tor Books (2017), 1,220 pages</dd>'
      .. '<dt >Reading Dates</dt><dd  class="edit_field_reading_dates" >' .. table.concat(dates) .. '</dd>'
      .. '<dt >Collections</dt><dd  class="edit_field_collections" ><button    value="" class="btn"   '
      .. 'onclick="lt.collections.open_collection_popup(1234567, {\'bookid\':'
      .. opts.copy_id .. ",'target':'u_1'});return false;\"        ></button>"
      .. '<span id="u_1" data-uitype="horizontalList" class="collection_list_1234567">'
      .. table.concat(collections, ", ") .. '</span></dd>'
      .. '<dt >Rating</dt><dd  class="edit_field_rating" ><span class="rw"><input type="hidden" value="'
      .. (opts.rating or 0) .. '" name="form_rating" id="rating_u_1"></span></dd></dl></div>'
  end
  return "<html><head><title>" .. (opts.title or "Oathbringer by Brandon Sanderson") .. " | LibraryThing</title></head>"
    .. "<script>LibraryThing.is_signed_in = " .. (opts.signed_out and 0 or 1234567) .. ";\nbookID = 99;</script>"
    .. string.rep("x", 1000) .. panel .. "</html>"
end

describe("LibraryThing parsing", function()
  it("decodes base64, including multi-byte text", function()
    local text = "Café – Oathbringer"
    assert.equals(text, parse.base64_decode(base64(text)))
    assert.equals("ab", parse.base64_decode(base64("ab")))
  end)

  it("decodes named and numeric entities to UTF-8", function()
    assert.equals("Tom & Jerry’s “café” é", parse.decode_entities("Tom &amp; Jerry&rsquo;s &#8220;caf&#xe9;&#8221; &#233;"))
  end)

  it("reads search results from ajax_newsearch.php's HTML", function()
    local html = '<table><tr><td valign="top" class="i"><a data-workid="16471009" href="/work/16471009/t/Oathbringer">'
      .. '<img src="https://ecx.images-amazon.com/images/P/076532637X.01._SX50_.jpg" class="cover"></a></td>'
      .. '<td valign="top"><p class="item"><a data-workid="16471009" href="/work/16471009/t/Oathbringer">Oathbringer</a>'
      .. ' by <a href="/a/6065/Brandon-Sanderson">Brandon Sanderson</a></p>'
      .. '<p class="si"><a href="/work/16471009/members">5,930 members</a>, 109 reviews</p></td></tr>'
      .. '<tr><td><a data-workid="21994115" href="/work/21994115/t/x"></a></td><td><p class="item">'
      .. '<a data-workid="21994115" href="/work/21994115/t/x">Oathbringer Part One</a> by <a href="/a/6065/x">Brandon Sanderson</a></p></td></tr></table>'
    local books = parse.parse_search_results(html)
    assert.equals(2, #books)
    assert.equals("16471009", books[1].book_id)
    assert.equals("Oathbringer", books[1].title)
    assert.equals("Brandon Sanderson", books[1].contributions[1].author.name)
    assert.equals(5930, books[1].users_count)
    assert.matches("076532637X", books[1].cached_image.url, 1, true)
    assert.equals("Oathbringer Part One", books[2].title)
  end)

  it("reads a copy being read from the work page", function()
    local html = parse.extract_work_page(work_page({
      title = "Killed by Death by Some Author",
      copy_id = 900001,
      collections = { { 1, "Your library" }, { 7, "Currently reading" } },
      reads = { { "2026-09-01", "2026-09-20" }, { "2026-10-13" } },
      rating = 7,
    }))
    local status = parse.parse_user_book(html, 16471009)
    assert.equals("900001", status.id)
    assert.equals("16471009", status.book_id)
    assert.equals("1234567", status.usernum)
    assert.equals("Killed by Death", status.title)
    assert.equals(STATUS.READING, status.status_id)
    assert.equals(7, status.rating)
    assert.equals(1220, status.page_count)
    assert.same({ { started = "2026-09-01", finished = "2026-09-20" }, { started = "2026-10-13" } }, status.reading_dates)
  end)

  it("derives Read from a finished read, and To read from its collection", function()
    local finished = parse.parse_user_book(work_page({
      copy_id = 1, collections = { { 1, "Your library" } }, reads = { { "2026-09-01", "2026-09-20" } },
    }), 5)
    assert.equals(STATUS.FINISHED, finished.status_id)

    local unowned = parse.parse_user_book(work_page({ copy_id = 1, collections = { { 5, "Read but unowned" } } }), 5)
    assert.equals(STATUS.FINISHED, unowned.status_id)

    local to_read = parse.parse_user_book(work_page({
      copy_id = 1, collections = { { 3, "To read" } }, reads = { { "2026-09-01", "2026-09-20" } },
    }), 5)
    assert.equals(STATUS.TO_READ, to_read.status_id)

    local shelved = parse.parse_user_book(work_page({ copy_id = 1, collections = { { 1, "Your library" } } }), 5)
    assert.equals("1", shelved.id)
    assert.is_nil(shelved.status_id)
  end)

  it("matches renamed collections by the ids learned for the account", function()
    local status = parse.parse_user_book(work_page({
      copy_id = 1, collections = { { 1, "Meine Bibliothek" }, { 7, "Lese ich gerade" } },
    }), 5, { library = 1, reading = 7 })
    assert.equals(STATUS.READING, status.status_id)
  end)

  it("has no copy for a work that isn't in the library, despite the page's bookID", function()
    local status = parse.parse_user_book(parse.extract_work_page(work_page()), 16471009)
    assert.is_nil(status.id)
    assert.is_nil(status.status_id)
    assert.equals("Oathbringer", status.title)
  end)

  it("reports a signed-out page as unauthorized", function()
    local status, err = parse.parse_user_book(work_page({ signed_out = true, copy_id = 1 }), 5)
    assert.is_nil(status)
    assert.equals("Unauthorized", err)
  end)

  it("keeps only the session cookies", function()
    local jar = parse.session_cookies("cookie_userid=Reader; expires=Wed, 13-Oct-2027 17:00:00 GMT; path=/, "
      .. "cookie_usernum=1234567; path=/, cookie_userchecksum=abc123; path=/, cf_clearance=xyz; PHPSESSID=s1")
    assert.same({ cookie_userid = "Reader", cookie_usernum = "1234567", cookie_userchecksum = "abc123" }, jar)
    assert.same({}, parse.session_cookies("cookie_userid=deleted; cookie_userchecksum=; path=/"))
  end)

  it("reads the account's collections from the add form, custom ones included", function()
    local html = '<input type="checkbox" name="books_collections[]" value="500001" class="chkbox"> <span>Read</span>'
      .. '<input type="checkbox" name="books_collections[]" value="1" checked="checked" class="chkbox"> <span>Your library</span>'
      .. '<input type="checkbox" name="books_collections[]" value="7" class="chkbox"> <span>Currently reading</span>'
      .. '<input type="checkbox" name="books_collections[]" value="4" class="chkbox"> <span>Wishlist</span>'
    assert.same({
      { id = 500001, name = "Read" },
      { id = 1, name = "Your library", key = "library" },
      { id = 7, name = "Currently reading", key = "reading" },
      { id = 4, name = "Wishlist" },
    }, parse.parse_collection_checkboxes(html))
  end)

  it("round-trips a response through the subprocess encoding", function()
    local content = parse.encode_response(302, { location = "/home", ["set-cookie"] = "a=1\r\nb=2" }, "body\nwith|lines")
    local code, headers, body = parse.decode_response(content)
    assert.equals(302, code)
    assert.equals("/home", headers.location)
    assert.equals("a=1  b=2", headers["set-cookie"])
    assert.equals("body\nwith|lines", body)
  end)

  it("parses librarything: identifiers without mistaking them for ISBNs", function()
    local ids = Book:parseIdentifiers("librarything:1234567890\nisbn:9780765326355")
    assert.equals("1234567890", ids.librarything_id)
    assert.is_nil(ids.isbn_10)
    assert.equals("9780765326355", ids.isbn_13)
  end)
end)

describe("LibraryThing transport", function()
  local api, values, requests, responses, incomplete_tries

  before_each(function()
    mocks.reset()
    values = {}
    incomplete_tries = nil
    api = setmetatable({
      settings = {
        readSetting = function(_, key) return values[key] end,
        updateSetting = function(_, key, value) values[key] = value end,
        debugLog = function() end,
        debugWarn = function() end,
      },
    }, { __index = Api })
    requests, responses = {}, {}
    stub(NetworkManager, "isConnected", function() return true end)
    stub(Trapper, "dismissableRunInSubprocess", function(_, fn)
      -- As when the user dismisses it, or the subprocess dies.
      if incomplete_tries then
        incomplete_tries = incomplete_tries + 1
        return false
      end
      return true, fn()
    end)
    stub(socketutil, "set_timeout", function() end)
    stub(socketutil, "reset_timeout", function() end)
    stub(socketutil, "table_sink", function(t)
      return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end
    end)
    ltn12.source = ltn12.source or {}
    stub(ltn12.source, "string", function(s)
      return function() local chunk = s; s = nil; return chunk end
    end)
    stub(http, "request", function(req)
      requests[#requests + 1] = req
      req.body = req.source and req.source() or nil
      local response = responses[#requests]
      req.sink(response[2])
      return 1, response[1], response[3] or {}
    end)
  end)

  after_each(function()
    mock.revert(NetworkManager); mock.revert(Trapper); mock.revert(socketutil)
    mock.revert(ltn12.source); mock.revert(http); mock.revert(json)
  end)

  it("saves the session cookies from a pasted Cookie header, and only those", function()
    values[SETTING.LIBRARYTHING.PASSWORD_ENC] = "old-ciphertext"
    values[SETTING.LIBRARYTHING.PASSWORD_PLAIN] = "old-password"
    assert.is_true(api:saveSessionCookie(" cookie_userid=Reader; cf_clearance=xyz; cookie_usernum=1234567;"
      .. " cookie_userchecksum=abc; LTAnonSessionID=1 "))
    assert.equals("cookie_userid=Reader; cookie_usernum=1234567; cookie_userchecksum=abc", values[SETTING.LIBRARYTHING.SESSION_COOKIE])
    assert.equals("Reader", api:username())
    assert.equals("1234567", values[SETTING.USER_ID])
    assert.equals("", values[SETTING.LIBRARYTHING.PASSWORD_ENC])
    assert.equals("", values[SETTING.LIBRARYTHING.PASSWORD_PLAIN])
    assert.is_true(api:hasCredential())
  end)

  it("gets website session cookies through Android sign-in without sending stored cookies", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Old; cookie_usernum=1; cookie_userchecksum=old"
    stub(json, "decode", function() return { data = {
      cookie_userid = "Reader", cookie_usernum = "1234567", cookie_userchecksum = "abc",
      auth_token = "app-token", auth_checksum = "app-checksum",
    } } end)
    responses[1] = { 200, "{}", { ["set-cookie"] = "LTAnonSessionID=api-session; path=/" } }

    assert.is_true(api:login("Reader", "test pass"))
    assert.equals("https://api4.librarything.com", requests[1].url:match("^https://[^/]+"))
    assert.matches("/app_authorize.php%?", requests[1].url)
    assert.matches("auth_username=Reader", requests[1].url)
    assert.matches("auth_password=test%+pass", requests[1].url)
    assert.matches("^Dalvik/2.1.0", requests[1].headers["User-Agent"])
    assert.is_nil(requests[1].headers.Cookie)
    assert.is_nil(values[SETTING.LIBRARYTHING.SITE_SESSION])
    assert.equals("cookie_userid=Reader; cookie_usernum=1234567; cookie_userchecksum=abc",
      values[SETTING.LIBRARYTHING.SESSION_COOKIE])
    assert.equals("Reader", values[SETTING.LIBRARYTHING.USERNAME])
    assert.equals("1234567", values[SETTING.USER_ID])
    assert.is_true((values[SETTING.LIBRARYTHING.PASSWORD_ENC] ~= ""
      and values[SETTING.LIBRARYTHING.PASSWORD_PLAIN] == "")
      or (values[SETTING.LIBRARYTHING.PASSWORD_ENC] == ""
        and values[SETTING.LIBRARYTHING.PASSWORD_PLAIN] == "test pass"))
    for key, value in pairs(values) do
      if key ~= SETTING.LIBRARYTHING.PASSWORD_PLAIN then
        assert.is_false(type(value) == "string" and value:find("test pass", 1, true) ~= nil)
      end
    end
  end)

  it("doesn't replace a saved session when Android sign-in omits a cookie", function()
    local old_session = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=old"
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = old_session
    stub(json, "decode", function() return { data = {
      cookie_userid = "Other", cookie_usernum = "2", cookie_userchecksum = "bad;value",
    } } end)
    responses[1] = { 200, "{}" }

    local ok, err = api:login("Other", "test pass")
    assert.is_nil(ok)
    assert.equals("LibraryThing returned an incomplete sign-in response", err)
    assert.equals(old_session, values[SETTING.LIBRARYTHING.SESSION_COOKIE])
  end)

  it("searches again with the site session LibraryThing sets, and keeps it", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc"
    local error_page = "<p>Error. If this error persists, email info@librarything.com or post on Talk.</p>"
    local results = '<tr><td><a data-workid="16471009" href="/work/16471009/t/Oathbringer"></a></td><td><p class="item">'
      .. '<a data-workid="16471009" href="/work/16471009/t/Oathbringer">Oathbringer</a> by <a href="/a/6065/x">Brandon Sanderson</a></p></td></tr>'
    responses[1] = { 200, '{"text":"' .. base64(error_page):gsub("/", "\\/") .. '"}',
      { ["set-cookie"] = "LTAnonSessionID=4242; expires=Wed, 13-Oct-2027 17:00:00 GMT; path=/, LTAnonSessionID=4242; path=/" } }
    responses[2] = { 200, '{"text":"' .. base64(results):gsub("/", "\\/") .. '"}' }

    local books = api:searchWorks("Oathbringer")
    assert.equals(1, #books)
    assert.equals("16471009", books[1].book_id)
    assert.equals(2, #requests)
    assert.is_nil(requests[1].headers.Cookie:find("LTAnonSessionID", 1, true))
    assert.equals("cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc; LTAnonSessionID=4242", requests[2].headers.Cookie)
    assert.equals("4242", values[SETTING.LIBRARYTHING.SITE_SESSION])
  end)

  it("reports LibraryThing's search error instead of no results", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc"
    values[SETTING.LIBRARYTHING.SITE_SESSION] = "4242"
    responses[1] = { 200, '{"text":"' .. base64("<p>Error. If this error persists, email us.</p>") .. '"}' }
    local books, err = api:searchWorks("Oathbringer")
    assert.same({}, books)
    assert.equals("LibraryThing's search failed", err)
    assert.equals(1, #requests)
  end)

  it("needs all three session cookies", function()
    assert.is_false(api:saveSessionCookie("cookie_userid=Reader; cookie_userchecksum=abc"))
    assert.is_nil(values[SETTING.LIBRARYTHING.SESSION_COOKIE])
    assert.is_false(api:hasCredential())
  end)

  it("forgets the copies found under another account", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Old; cookie_usernum=1; cookie_userchecksum=a"
    values[SETTING.LIBRARYTHING.WORKS] = { ["5"] = { title = "Oathbringer", copy = "9" } }
    values[SETTING.LIBRARYTHING.COLLECTION_IDS] = { reading = 2 }
    assert.is_true(api:saveSessionCookie("cookie_userid=New; cookie_usernum=2; cookie_userchecksum=b"))
    assert.same({ ["5"] = { title = "Oathbringer" } }, values[SETTING.LIBRARYTHING.WORKS])
    assert.is_nil(values[SETTING.LIBRARYTHING.COLLECTION_IDS])
  end)

  it("reports a Cloudflare challenge as such, not as an expired session", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc"
    local notices = 0
    api.on_error = function() notices = notices + 1 end
    responses[1] = { 403, "<title>Just a moment...</title>", { ["cf-mitigated"] = "challenge" } }
    local code, err = api:request("/work/1")
    assert.is_nil(code)
    assert.equals(Api.CHALLENGE_ERROR, err)
    assert.equals(0, notices)
  end)

  it("treats a redirect to the signed-out page as an expired session, without following it", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc"
    local failures = 0
    api.on_error = function(err) if err == "Unauthorized" then failures = failures + 1 end end
    responses[1] = { 302, "", { location = "/signoutconfirm.php" } }
    local code, err = api:request("/ajax_setBookRating.php", { ajax = true, form = { { "book", 1 } } })
    assert.is_nil(code)
    assert.equals("Unauthorized", err)
    assert.equals(1, failures)
    assert.is_false(requests[1].redirect)
    assert.equals("XMLHttpRequest", requests[1].headers["X-Requested-With"])
    assert.equals("book=1", requests[1].body)
    assert.matches("^ShelfSync/", requests[1].headers["User-Agent"])
  end)

  it("sends only the saved session cookies and treats a sign-in redirect as an expired session", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc"
    local failures = 0
    api.on_error = function(err) if err == "Unauthorized" then failures = failures + 1 end end
    responses[1] = { 302, "", { location = "https://www.librarything.com/signin" } }
    local code, err = api:request("/work/1")
    assert.is_nil(code)
    assert.equals("Unauthorized", err)
    assert.equals(1, failures)
    assert.equals("cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc", requests[1].headers.Cookie)
    assert.equals("https://www.librarything.com/work/1", requests[1].url)
  end)

  it("re-authenticates and retries a request after a sign-in redirect", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=old"
    values[SETTING.LIBRARYTHING.PASSWORD_PLAIN] = "test pass"
    stub(json, "decode", function() return { data = {
      cookie_userid = "Reader", cookie_usernum = "1234567", cookie_userchecksum = "fresh",
    } } end)
    responses[1] = { 302, "", { location = "/signin" } }
    responses[2] = { 200, "{}" }
    responses[3] = { 200, "retried" }

    local code, body = api:request("/work/1")

    assert.equals(200, code)
    assert.equals("retried", body)
    assert.equals(3, #requests)
    assert.equals("cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=old", requests[1].headers.Cookie)
    assert.is_nil(requests[2].headers.Cookie)
    assert.matches("auth_password=test%+pass", requests[2].url)
    assert.equals("cookie_userid=Reader; cookie_usernum=1234567; cookie_userchecksum=fresh", requests[3].headers.Cookie)
    assert.equals("cookie_userid=Reader; cookie_usernum=1234567; cookie_userchecksum=fresh",
      values[SETTING.LIBRARYTHING.SESSION_COOKIE])
  end)

  it("re-authenticates when a work page says the user is signed out", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=old"
    values[SETTING.LIBRARYTHING.PASSWORD_PLAIN] = "test pass"
    stub(json, "decode", function() return { data = {
      cookie_userid = "Reader", cookie_usernum = "1234567", cookie_userchecksum = "fresh",
    } } end)
    responses[1] = { 200, work_page({ signed_out = true, copy_id = 1 }) }
    responses[2] = { 200, "{}" }
    responses[3] = { 200, work_page({ copy_id = 42, collections = { { 7, "Currently reading" } } }) }

    local status, err = api:_findUserBookOnWorkPage("16471009")

    assert.is_nil(err)
    assert.equals("42", status.id)
    assert.equals(3, #requests)
    assert.equals("cookie_userid=Reader; cookie_usernum=1234567; cookie_userchecksum=fresh", requests[3].headers.Cookie)
  end)

  it("clears saved credentials on logout", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc"
    values[SETTING.LIBRARYTHING.PASSWORD_ENC] = "ciphertext"
    values[SETTING.LIBRARYTHING.PASSWORD_PLAIN] = "password"

    api:logout()

    assert.equals("", values[SETTING.LIBRARYTHING.SESSION_COOKIE])
    assert.equals("", values[SETTING.LIBRARYTHING.PASSWORD_ENC])
    assert.equals("", values[SETTING.LIBRARYTHING.PASSWORD_PLAIN])
  end)

  it("doesn't send a request that opts out again after an incomplete try", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc"
    incomplete_tries = 0
    local code, err = api:request("/action_addbooks_express_add_book.php?workcode=1",
      { method = "POST", ajax = true, no_retry = true })
    assert.is_nil(code)
    assert.equals("Request failed", err)
    assert.equals(1, incomplete_tries)

    -- Others are still tried twice.
    api:request("/ajax_collections_popup.php", { ajax = true, form = { { "bookid", 1 } } })
    assert.equals(3, incomplete_tries)
  end)

  it("reports a failed request by its status, not the page it got back", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc"
    responses[1] = { 500, "<!DOCTYPE html><html><body><h1>Something went wrong</h1></body></html>" }
    local ok, err = api:setRating("9", 7)
    assert.is_nil(ok)
    assert.equals("LibraryThing answered HTTP 500", err)
  end)

  it("falls back to the work page for a work with no known title, extracted in the subprocess", function()
    values[SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1; cookie_userchecksum=abc"
    responses[1] = { 200, work_page({ copy_id = 42, collections = { { 7, "Currently reading" } }, reads = { { "2026-10-01" } } }) }
    local status = api:findUserBook("16471009")
    assert.equals("42", status.id)
    assert.equals(STATUS.READING, status.status_id)
    assert.equals("/work/16471009", requests[1].url:match("librarything%.com(.*)$"))
  end)
end)


-- A LibraryThing account, answering api:request the way librarything.com's
-- endpoints do, so the status changes can be followed request by request.
local function fake_account()
  local NAMES = { [500001] = "Read", [1] = "Your library", [4] = "Wishlist", [7] = "Currently reading",
    [3] = "To read", [5] = "Read but unowned", [6] = "Favorites" }
  local ORDER = { 500001, 1, 4, 7, 3, 5, 6 }
  local account = {
    copies = {}, -- copy id -> { work, title, author, collections = { [cid] = true }, rows = {}, rating, review }
    added = {}, -- copy ids, most recent first
    next_copy = 77,
    calls = {},
  }

  function account:copy(copy_id, work, fields)
    local copy = { work = work, collections = {}, rows = {}, rating = 0 }
    for k, v in pairs(fields or {}) do copy[k] = v end
    self.copies[tostring(copy_id)] = copy
    return copy
  end

  local function query(path)
    local params = {}
    for k, v in (path:match("%?(.*)$") or ""):gmatch("([^&=]+)=([^&]*)") do
      params[k] = v:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    end
    return params
  end

  local function popup(copy)
    local html = {}
    for _, id in ipairs(ORDER) do
      table.insert(html, ('<label  data-control_side="left"><input type="checkbox"  data-cid="%d" name="checkbox_%d" value="1" %s'
        .. 'onclick="lt.collections.handle_collection_popup_item(this);" id="checkbox_%d"  class="chkbox "><span>%s</span></label>')
        :format(id, id, copy and copy.collections[id] and 'checked="checked" ' or "", id, NAMES[id]))
    end
    return table.concat(html)
  end

  function account:request(path, opts)
    opts = opts or {}
    local form = {}
    for _, field in ipairs(opts.form or {}) do form[field[1]] = field[2] end
    table.insert(self.calls, { path = path, form = form, fields = opts.form, opts = opts })
    local params = query(path)
    local function reply(body) return 200, opts.extract and opts.extract(body) or body, {} end

    if path:match("^/catalog_bottom%.php") then
      local term, html = params.deepsearch:lower(), {}
      for id, copy in pairs(self.copies) do
        if (copy.title or ""):lower():find(term, 1, true) or (copy.author or ""):lower():find(term, 1, true) then
          table.insert(html, ('<a href="/work/%s/book/%s">%s</a>'):format(copy.work, id, copy.title))
        end
      end
      return reply("<table>" .. table.concat(html) .. "</table>")
    elseif path == "/ajax_collections_popup.php" then
      return reply(popup(self.copies[tostring(form.bookid)]))
    elseif path:match("^/ajax_lb_newwork_edit_bookfields%.php") then
      local copy = self.copies[params.book]
      if params.type == "review" then
        return reply('<input type="hidden" name="edit_type" value="review"><textarea name="form_review">'
          .. (copy.review or "") .. '</textarea><select name="form_review_language"><option value="">(blank)</option>'
          .. '<option value="eng" selected="selected" >English</option></select>'
          .. '<input type="hidden" value="' .. copy.rating .. '" name="form_rating">')
      end
      local html = { '<input type="hidden" name="edit_type" value="reading_dates">' }
      -- As the site does, someone else's (or no) copy gets an empty form.
      for i, row in ipairs(copy and copy.rows or { { started = "", finished = "" } }) do
        table.insert(html, ('<input type="text" name="newdatestartedA[%d]" value="%s"><input type="text" name="newdateendedA[%d]" value="%s">')
          :format(i, row.started, i, row.finished))
      end
      table.insert(html, '<input type="text" name="newdatestartedA[0]"><input type="text" name="newdateendedA[0]">')
      return reply(table.concat(html))
    elseif path == "/ajax_newwork_edit_bookfields_submit.php" then
      local copy = self.copies[tostring(form.edit_book)]
      if form.edit_type == "review" then
        copy.review, copy.rating = form.form_review, tonumber(form.form_rating)
        return reply('{".edit_field_review":{"content":"x"},".edit_field_rating":{"content":"x"}}')
      end
      local rows = {}
      for _, field in ipairs(opts.form) do
        local kind, index = field[1]:match("^newdate(%a+)A%[(%d+)%]$")
        index = tonumber(index)
        if kind and index > 0 then
          rows[index] = rows[index] or { started = "", finished = "" }
          rows[index][kind == "started" and "started" or "finished"] = field[2]
        end
      end
      copy.rows = rows
      return reply('{".edit_field_reading_dates":{"content":"x"}}')
    elseif path == "/ajax_collectionsToggleBook.php" then
      local copy = self.copies[tostring(form.bookid)]
      local id = tonumber(form.c_id)
      if form.addRemove == 1 then
        copy.collections[id] = true
      elseif next(copy.collections, next(copy.collections)) then
        -- Like the site: a copy's last collection can't be removed.
        copy.collections[id] = nil
      end
      local html = {}
      for _, cid in ipairs(ORDER) do
        if copy.collections[cid] then
          table.insert(html, ('<div><a href="/catalog.php?collection=%d" target="_top">%s</a></div>'):format(cid, NAMES[cid]))
        end
      end
      return reply(table.concat(html))
    elseif path == "/ajax_lb_addbooks_express_open.php" then
      local html = { '<input type="hidden" name="memcache_key" value="u_key" id="memcache_key">' }
      for _, id in ipairs(ORDER) do
        table.insert(html, ('<label><input type="checkbox" name="books_collections[]" value="%d" id="books_collections[]" class="chkbox chkbox"> <span>%s</span></label>')
          :format(id, NAMES[id]))
      end
      return reply(table.concat(html))
    elseif path:match("^/ajax_addbooks_express_show_bestwork%.php") then
      return reply('{"#abx_data_info":{"content":"<div class=\\"card_title clamp clamp2\\" data-autoscale=\\"90\\"><a href=\\"\\/work\\/'
        .. params.workcode .. '\\" data-workid=\\"' .. params.workcode .. '\\">The Way of Kings<\\/a><\\/div>'
        .. '<div class=\\"card_author clamp\\"><a href=\\"\\/author\\/x\\">Brandon Sanderson<\\/a><\\/div>'
        .. '<dd>Tor (2011), 1,007 pages<\\/dd>'
        .. '<input type=\\"hidden\\" name=\\"record_id\\" value=\\"272878834\\" id=\\"record_id\\" class=\\"\\" >'
        .. '<input type=\\"hidden\\" name=\\"source_type\\" value=\\"amazon\\" id=\\"source_type\\" class=\\"\\" >'
        .. '<input type=\\"hidden\\" name=\\"source_id\\" value=\\"2109\\" id=\\"source_id\\" class=\\"\\" >'
        .. '<input type=\\"hidden\\" name=\\"isbn\\" value=\\"0765365278\\" id=\\"isbn\\" class=\\"\\" >"}}')
    elseif path:match("^/action_addbooks_express_add_book%.php") then
      local copy_id = tostring(self.next_copy)
      self.next_copy = self.next_copy + 1
      local copy = self:copy(copy_id, params.workcode, { title = "The Way of Kings", author = "Sanderson, Brandon" })
      for id in params.collection:gmatch("%d+") do copy.collections[tonumber(id)] = true end
      table.insert(self.added, 1, copy_id)
      return reply("Added The Way of Kings: Book One of the Stormlight Archive")
    elseif path == "/response_list_lt2.php" then
      local html = {}
      for _, copy_id in ipairs(self.added) do
        table.insert(html, ('<a href="/work/%s/book/%s">Edit</a>'):format(self.copies[copy_id].work, copy_id))
      end
      return reply(table.concat(html))
    elseif path == "/ajax_setBookRating.php" then
      self.copies[tostring(form.book)].rating = tonumber(form.rating)
      return reply("&frac12;")
    end
    error("unexpected request " .. path)
  end

  return account
end

describe("LibraryThing status changes", function()
  local api, values, account, today

  before_each(function()
    mocks.reset()
    values = { [SETTING.LIBRARYTHING.SESSION_COOKIE] = "cookie_userid=Reader; cookie_usernum=1234567; cookie_userchecksum=abc" }
    account = fake_account()
    today = os.date("%Y-%m-%d")
    api = setmetatable({
      settings = {
        readSetting = function(_, key) return values[key] end,
        updateSetting = function(_, key, value) values[key] = value end,
        debugLog = function() end,
        debugWarn = function() end,
      },
      request = function(_, path, opts) return account:request(path, opts) end,
    }, { __index = Api })
  end)

  local function called(pattern)
    for _, call in ipairs(account.calls) do
      if call.path:match(pattern) then return call end
    end
  end

  it("parses the collection picker", function()
    local _, empty = account:request("/ajax_collections_popup.php", { form = { { "bookid", "none" } } })
    assert.equals(7, #parse.parse_collections_popup(empty))
    account:copy(9, "1", { collections = { [7] = true, [1] = true } })
    local _, popup = account:request("/ajax_collections_popup.php", { form = { { "bookid", "9" } } })
    local checked = {}
    for _, c in ipairs(parse.parse_collections_popup(popup)) do
      if c.checked then table.insert(checked, c.key) end
    end
    assert.same({ "library", "reading" }, checked)
  end)

  it("adds a work that isn't in the library to Your library and Currently reading, starting a read today", function()
    api:rememberWork("8556314", { title = "The Way of Kings", author = "Brandon Sanderson" })
    local status = api:updateUserBook("8556314", STATUS.READING)

    assert.equals(STATUS.READING, status.status_id)
    assert.equals("77", status.id)
    local add = called("^/action_addbooks_express_add_book").path
    assert.matches("collection=1%%2C7", add)
    assert.matches("record_id=272878834", add, 1, true)
    assert.matches("workcode=8556314", add, 1, true)
    assert.is_true(called("^/action_addbooks_express_add_book").opts.no_retry)
    assert.same({ { started = today, finished = "" } }, account.copies["77"].rows)
    assert.equals("77", values[SETTING.LIBRARYTHING.WORKS]["8556314"].copy)
    assert.same({ library = 1, reading = 7, to_read = 3, read_unowned = 5 }, values[SETTING.LIBRARYTHING.COLLECTION_IDS])
    assert.is_nil(called("^/work/"))
  end)

  it("finds a copy under another title by its author, and doesn't add another", function()
    account:copy(12, "8556314", { title = "Der Weg der Könige", author = "Sanderson, Brandon", collections = { [1] = true } })
    api:rememberWork("8556314", { title = "The Way of Kings", author = "Brandon Sanderson" })

    local status = api:updateUserBook("8556314", STATUS.READING)
    assert.equals("12", status.id)
    assert.equals(STATUS.READING, status.status_id)
    assert.same({ [1] = true, [7] = true }, account.copies["12"].collections)
    assert.is_nil(called("^/action_addbooks_express_add_book"))
  end)

  it("finishes the open read and moves the book from Currently reading to Your library", function()
    account:copy(9, "16471009", { title = "Oathbringer", collections = { [7] = true },
      rows = { { started = "2026-09-01", finished = "" } } })
    api:rememberWork("16471009", { title = "Oathbringer", copy = "9" })

    local status = api:updateUserBook("16471009", STATUS.FINISHED)
    assert.equals(STATUS.FINISHED, status.status_id)
    assert.same({ [1] = true }, account.copies["9"].collections)
    assert.same({ { started = "2026-09-01", finished = today } }, account.copies["9"].rows)
  end)

  it("moves a finished book to the collection chosen for read books", function()
    account:copy(9, "16471009", { title = "Oathbringer", collections = { [1] = true, [7] = true, [3] = true },
      rows = { { started = "2026-09-01", finished = "" } } })
    api:rememberWork("16471009", { title = "Oathbringer", copy = "9" })
    assert.is_truthy(api:refreshCollections())
    api:setReadCollection({ id = 500001, name = "Read" })

    local status = api:updateUserBook("16471009", STATUS.FINISHED)
    assert.equals(STATUS.FINISHED, status.status_id)
    assert.same({ [1] = true, [500001] = true }, account.copies["9"].collections)
  end)

  it("adds a work finished elsewhere straight to the collection chosen for read books", function()
    api:rememberWork("8556314", { title = "The Way of Kings", author = "Brandon Sanderson" })
    api:setReadCollection({ id = 5, name = "Read but unowned" })

    local status = api:updateUserBook("8556314", STATUS.FINISHED)
    assert.equals(STATUS.FINISHED, status.status_id)
    assert.same({ [5] = true }, account.copies["77"].collections)
    assert.same({ { started = "", finished = today } }, account.copies["77"].rows)
  end)

  it("takes a book in the collection chosen for read books as Read, but not one just in Your library", function()
    account:copy(9, "16471009", { title = "Oathbringer", collections = { [1] = true, [500001] = true } })
    account:copy(10, "8556314", { title = "The Way of Kings", collections = { [1] = true } })
    api:rememberWork("16471009", { title = "Oathbringer", copy = "9" })
    api:rememberWork("8556314", { title = "The Way of Kings", copy = "10" })

    assert.is_nil(api:findUserBook("16471009").status_id)
    api:setReadCollection({ id = 500001, name = "Read" })
    assert.equals(STATUS.FINISHED, api:findUserBook("16471009").status_id)
    assert.is_nil(api:findUserBook("8556314").status_id)
  end)

  it("lists the account's collections and goes back to Your library if the chosen one is gone", function()
    assert.equals("Your library", api:readCollection().name)
    local names = {}
    for _, collection in ipairs(api:refreshCollections()) do table.insert(names, collection.name) end
    assert.same({ "Read", "Your library", "Wishlist", "Currently reading", "To read", "Read but unowned", "Favorites" }, names)

    api:setReadCollection({ id = 500001, name = "Read" })
    assert.same({ id = 500001, name = "Read" }, api:readCollection())
    values[SETTING.LIBRARYTHING.COLLECTIONS] = { { id = 1, name = "Your library" }, { id = 7, name = "Currently reading" } }
    assert.same({ id = 1, name = "Your library" }, api:readCollection())
    -- Nor ever a status collection.
    api:setReadCollection({ id = 7, name = "Currently reading" })
    assert.equals(1, api:readCollection().id)
  end)

  it("dates a finish queued while offline when it was finished", function()
    account:copy(9, "16471009", { title = "Oathbringer", collections = { [1] = true },
      rows = { { started = "2026-09-01", finished = today } } })
    api:rememberWork("16471009", { title = "Oathbringer", copy = "9" })
    local finished_at = os.time() - 3 * 24 * 3600

    assert.is_true(api:setDateFinished("16471009", finished_at))
    assert.equals(os.date("%Y-%m-%d", finished_at), account.copies["9"].rows[1].finished)
  end)

  it("looks the copy up again once it's been deleted, and then has none", function()
    api:rememberWork("16471009", { title = "Oathbringer", copy = "404" })
    local status = api:findUserBook("16471009")
    assert.is_nil(status.id)
    assert.equals("Oathbringer", status.title)
    assert.is_nil(values[SETTING.LIBRARYTHING.WORKS]["16471009"].copy)
  end)

  it("doesn't take an expired session for a deleted copy", function()
    api:rememberWork("16471009", { title = "Oathbringer", copy = "9" })
    api.request = function(_, path, opts)
      if path:match("^/ajax_lb_newwork_edit_bookfields") then return nil, "Unauthorized" end
      return account:request(path, opts)
    end
    local status, err = api:findUserBook("16471009")
    assert.is_nil(status)
    assert.equals("Unauthorized", err)
    assert.equals("9", values[SETTING.LIBRARYTHING.WORKS]["16471009"].copy)
  end)

  it("says the reading dates weren't saved, rather than showing what LibraryThing answered", function()
    account:copy(9, "16471009", { title = "Oathbringer", collections = { [1] = true, [7] = true },
      rows = { { started = "2026-09-01", finished = "" } } })
    api:rememberWork("16471009", { title = "Oathbringer", copy = "9" })
    api.request = function(_, path, opts)
      if path == "/ajax_newwork_edit_bookfields_submit.php" then
        return 200, "<!DOCTYPE html><html><body>Something went wrong</body></html>", {}
      end
      return account:request(path, opts)
    end

    local status, err = api:updateUserBook("16471009", STATUS.FINISHED)
    assert.is_nil(status)
    assert.equals("LibraryThing didn't save the reading dates", err)
  end)

  it("removes the status but keeps the copy in the library", function()
    account:copy(9, "16471009", { title = "Oathbringer", collections = { [1] = true, [7] = true, [3] = true } })
    api:rememberWork("16471009", { title = "Oathbringer", copy = "9" })
    assert.is_true(api:removeRead("9"))
    assert.same({ [1] = true }, account.copies["9"].collections)
  end)

  it("keeps the review's rating when only the text is sent", function()
    account:copy(9, "16471009", { title = "Oathbringer", collections = { [1] = true }, rating = 7 })
    assert.is_true(api:setReview({ id = "9", book_id = "16471009" }, "Great", nil))
    assert.equals("Great", account.copies["9"].review)
    assert.equals(7, account.copies["9"].rating)
  end)

  it("names a work linked by its id", function()
    local book = api:findBookByIdentifiers({ librarything_id = "8556314" })
    assert.equals("The Way of Kings", book.title)
    assert.equals(1007, book.pages)
    assert.equals("Brandon Sanderson", book.contributions[1].author.name)
  end)

  it("doesn't offer Paused or Did Not Finish", function()
    local status, err = api:updateUserBook("1", STATUS.PAUSED)
    assert.is_nil(status)
    assert.matches("no Paused status", err, 1, true)
    assert.equals(0, #account.calls)
  end)
end)
