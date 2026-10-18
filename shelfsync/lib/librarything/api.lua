-- LibraryThing has no write API (its public /api and /services endpoints
-- are read-only and need a developer key), so like StoryGraph and Goodreads
-- this replays the requests librarything.com's own pages make, signed in
-- with the account's session cookies. None of them need a CSRF token.
-- Users can paste those cookies from a browser, or get them from the
-- private username/password sign-in endpoint. It sends the password in a GET
-- URL; ShelfSync encrypts the saved password when possible for reauthentication.
--
-- LibraryThing tracks books differently from the other providers:
--
-- 1. A book is a "work" (book_id here, linked from KOReader) with the
--    user's own copy of it (`id` in findUserBook's status) only if it's in
--    their library. Adding one goes through the site's "express add", which
--    picks an edition for the work. The copy is found by searching the
--    user's catalog and then remembered (see findUserBook).
-- 2. There's no reading status. A status is which of the default
--    collections the copy is in (Currently reading / To read), plus its
--    reading dates: a copy with a finished read and no read since is Read.
-- 3. There's no reading progress, so nothing is sent while reading; finishing
--    a book sets its finished date.
--
-- www.librarything.com is behind Cloudflare, which can answer a request
-- with a browser challenge (HTTP 403, `cf-mitigated: challenge`) that a
-- plugin can't complete. Those are reported as such (see CHALLENGE_ERROR)
-- rather than as an expired session, and nothing tries to get around them.
-- Work pages (/work/<id>) are challenged that way while the small requests
-- the site's own scripts make aren't, so those are what's used; a work page
-- only as a last resort.
local config_ok, shelfsync_config = pcall(require, "shelfsync_config")
local config = (config_ok and type(shelfsync_config) == "table" and shelfsync_config.librarything) or {}
local logger = require("shelfsync/lib/common/safe_logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local T = require("ffi/util").template
local Trapper = require("ui/trapper")
local NetworkManager = require("ui/network/manager")
local socketutil = require("socketutil")

local VERSION = require("shelfsync_version")
local SETTING = require("shelfsync/lib/common/constants/settings")
local LIBRARYTHING = require("shelfsync/lib/librarything/constants")
local CryptoUtil = require("shelfsync/lib/common/crypto_util")

local BASE_URL = LIBRARYTHING.BASE_URL
local STATUS = LIBRARYTHING.STATUS
local COLLECTION = LIBRARYTHING.COLLECTION

local APP_AUTH_URL = "https://api4.librarything.com"
local APP_TOKEN = "687aa7458d1ae63c50e1e32887e4d40b"
local APP_DIRECT_SIGNIN = "e038a6205d72c98c68e0afa670d0199c"
local APP_USER_AGENT = "Dalvik/2.1.0 (Linux; U; Android 16; 23090RA98G Build/BP2A.250605.031.A3)"

local CHALLENGE_ERROR = "LibraryThing's Cloudflare protection blocked the request with a browser check. ShelfSync can't complete those, so try again later."

local LibraryThingApi = {
  enabled = true,
  settings = nil, -- Injected by main.lua
  CHALLENGE_ERROR = CHALLENGE_ERROR,
}

----------------------------------------------------------------------
-- Encoding helpers
----------------------------------------------------------------------

local function urlencode(str)
  str = tostring(str or ""):gsub("\n", "\r\n")
  str = str:gsub("([^%w %-%_%.%~])", function(c)
    return ("%%%02X"):format(string.byte(c))
  end)
  return (str:gsub(" ", "+"))
end

-- `fields` is a list of { name, value } pairs, so a name can repeat (as
-- LibraryThing's reading-date rows do) and the order is kept.
local function form_encode(fields)
  local parts = {}
  for _, field in ipairs(fields) do
    table.insert(parts, urlencode(field[1]) .. "=" .. urlencode(field[2]))
  end
  return table.concat(parts, "&")
end

local function utf8_char(code)
  code = tonumber(code)
  if not code or code < 0 or code > 0x10FFFF then return "?" end
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then
    return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
  end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000),
      0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000),
    0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local NAMED_ENTITIES = {
  amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'", nbsp = " ",
  rsquo = "’", lsquo = "‘", ldquo = "“", rdquo = "”", ndash = "–", mdash = "—",
  hellip = "…", frac12 = "½", thinsp = " ", rsaquo = "›", raquo = "»",
}

local function decode_entities(str)
  if not str then return nil end
  str = str:gsub("&#[xX](%x+);", function(hex) return utf8_char(tonumber(hex, 16)) end)
  str = str:gsub("&#(%d+);", utf8_char)
  return (str:gsub("&(%a+);", function(name)
    return NAMED_ENTITIES[name:lower()] or ("&" .. name .. ";")
  end))
end

-- Text content of an HTML fragment, whitespace collapsed.
local function html_text(fragment)
  if not fragment then return nil end
  local text = decode_entities(fragment:gsub("<[^>]*>", " "))
  return (text:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

-- Plain-Lua base64 decoding (no bit operations), for ajax_newsearch.php's
-- base64-wrapped results. Stops at padding or anything outside the alphabet.
local function base64_decode(data)
  data = (data or ""):gsub("[^%w%+/=]", "")
  local out = {}
  for i = 1, #data, 4 do
    local chunk = data:sub(i, i + 3)
    local a, b = B64_INDEX[chunk:sub(1, 1)], B64_INDEX[chunk:sub(2, 2)]
    if not a or not b then break end
    local c, d = B64_INDEX[chunk:sub(3, 3)], B64_INDEX[chunk:sub(4, 4)]
    local n = a * 262144 + b * 4096 + (c or 0) * 64 + (d or 0)
    table.insert(out, string.char(math.floor(n / 65536) % 256))
    if c then table.insert(out, string.char(math.floor(n / 256) % 256)) end
    if d then table.insert(out, string.char(n % 256)) end
    if not c or not d then break end
  end
  return table.concat(out)
end

-- Undoes the escaping of a JSON string's contents, for HTML LibraryThing
-- returns inside JSON. Only the escapes that appear in that HTML matter.
local function json_unescape(str)
  return (str:gsub("\\u(%x%x%x%x)", function(hex) return utf8_char(tonumber(hex, 16)) end)
    :gsub("\\n", "\n"):gsub("\\t", "\t"):gsub("\\r", "")
    :gsub("\\([\"/\\])", "%1"))
end

local function input_value(html, name)
  for tag in (html or ""):gmatch("<input[^>]*>") do
    if tag:find('name="' .. name .. '"', 1, true) then
      return decode_entities(tag:match('value="([^"]*)"') or "")
    end
  end
end

local function today()
  return os.date("%Y-%m-%d")
end

local function iso_date(timestamp)
  return os.date("%Y-%m-%d", tonumber(timestamp) or os.time())
end

----------------------------------------------------------------------
-- Session cookies
----------------------------------------------------------------------

local SESSION_COOKIE_NAMES = {}
for _, name in ipairs(LIBRARYTHING.SESSION_COOKIES) do SESSION_COOKIE_NAMES[name] = true end

-- name -> value for LibraryThing's session cookies in `header`: a browser's
-- Cookie request header, or the name=value pairs copied from its cookie
-- storage. Anything else (analytics, Cloudflare's own cookies) is left
-- out, and so are empty or cleared ones.
local function session_cookies(header)
  local jar = {}
  for name, value in ("; " .. (header or "")):gmatch("[;,]%s*([%w_]+)=([^;,]*)") do
    if SESSION_COOKIE_NAMES[name] then
      value = value:match("^%s*(.-)%s*$")
      if value ~= "" and value ~= "deleted" then
        jar[name] = value
      end
    end
  end
  return jar
end

local function cookie_header(jar)
  local parts = {}
  for _, name in ipairs(LIBRARYTHING.SESSION_COOKIES) do
    if jar[name] then table.insert(parts, name .. "=" .. jar[name]) end
  end
  return table.concat(parts, "; ")
end

-- All three are needed: the forms that read and change a copy take the
-- account's number (cookie_usernum) as well.
local function complete_session(jar)
  return jar.cookie_userid ~= nil and jar.cookie_usernum ~= nil and jar.cookie_userchecksum ~= nil
end

function LibraryThingApi:sessionCookie()
  local stored = self.settings and self.settings:readSetting(SETTING.LIBRARYTHING.SESSION_COOKIE)
  if not stored or stored == "" then stored = config.cookie or "" end
  return cookie_header(session_cookies(stored))
end

function LibraryThingApi:hasCredential()
  return complete_session(session_cookies(self:sessionCookie()))
end

-- Saves the session cookies in a pasted Cookie header (or name=value
-- pairs). Returns false if they're not all there.
function LibraryThingApi:saveSessionCookie(header)
  local jar = session_cookies(header)
  if not complete_session(jar) then
    return false
  end
  self:_saveSession(jar)
  -- Browser cookies don't include credentials ShelfSync can use to renew them.
  self.settings:updateSetting(SETTING.LIBRARYTHING.PASSWORD_ENC, "")
  self.settings:updateSetting(SETTING.LIBRARYTHING.PASSWORD_PLAIN, "")
  return true
end

local function stored_password(settings)
  if not settings then return nil end
  local encrypted = settings:readSetting(SETTING.LIBRARYTHING.PASSWORD_ENC)
  if encrypted and encrypted ~= "" then
    return CryptoUtil.decryptSecret(encrypted)
  end
  local plain = settings:readSetting(SETTING.LIBRARYTHING.PASSWORD_PLAIN)
  if plain and plain ~= "" then return plain end
  return nil
end

local function save_password(settings, password)
  if not settings then return end
  local encrypted = CryptoUtil.encryptSecret(password)
  if encrypted then
    settings:updateSetting(SETTING.LIBRARYTHING.PASSWORD_ENC, encrypted)
    settings:updateSetting(SETTING.LIBRARYTHING.PASSWORD_PLAIN, "")
  else
    settings:updateSetting(SETTING.LIBRARYTHING.PASSWORD_ENC, "")
    settings:updateSetting(SETTING.LIBRARYTHING.PASSWORD_PLAIN, password)
  end
end

local function valid_session_cookie(value)
  return type(value) == "string" and value ~= "" and value ~= "deleted"
    and not value:find("[,;%c]")
end

-- The sign-in endpoint returns the three cookies this provider uses for
-- website requests. The password is cached for reauthentication if they expire.
function LibraryThingApi:login(username, password)
  if not NetworkManager:isConnected() then
    return nil, "Network not connected"
  end
  if type(username) ~= "string" or username == "" or type(password) ~= "string" or password == "" then
    return nil, "Username and password are required"
  end

  local path = "/app_authorize.php?" .. form_encode({
    { "v", 2 },
    { "app_token", APP_TOKEN },
    { "auth_username", username },
    { "auth_password", password },
    { "direct_signin", APP_DIRECT_SIGNIN },
  })
  local code, body = self:request(path, {
    base_url = APP_AUTH_URL,
    accept = "application/json",
    user_agent = APP_USER_AGENT,
    no_cookies = true,
  })
  if not code then
    if body == "Network not connected" or body == CHALLENGE_ERROR then return nil, body end
    return nil, "Could not contact LibraryThing sign-in"
  end
  if code ~= 200 then
    return nil, "LibraryThing sign-in failed (HTTP " .. tostring(code) .. ")"
  end

  local ok, result = pcall(json.decode, body)
  local data = ok and type(result) == "table" and result.data
  if type(data) ~= "table" or not valid_session_cookie(data.cookie_userid)
      or not valid_session_cookie(data.cookie_usernum) or not valid_session_cookie(data.cookie_userchecksum) then
    return nil, "LibraryThing returned an incomplete sign-in response"
  end

  local cookie = "cookie_userid=" .. data.cookie_userid
    .. "; cookie_usernum=" .. data.cookie_usernum
    .. "; cookie_userchecksum=" .. data.cookie_userchecksum
  if not self:saveSessionCookie(cookie) then
    return nil, "LibraryThing returned invalid session cookies"
  end
  save_password(self.settings, password)
  return true
end

-- Ids learned under one account (its collections, its copies of works)
-- don't apply to another; the works' titles still do.
function LibraryThingApi:_forgetAccountIds()
  self.settings:updateSetting(SETTING.LIBRARYTHING.COLLECTION_IDS, nil)
  self.settings:updateSetting(SETTING.LIBRARYTHING.COLLECTIONS, nil)
  self.settings:updateSetting(SETTING.LIBRARYTHING.READ_COLLECTION, nil)
  local works = self.settings:readSetting(SETTING.LIBRARYTHING.WORKS)
  if type(works) == "table" then
    for _, work in pairs(works) do work.copy = nil end
    self.settings:updateSetting(SETTING.LIBRARYTHING.WORKS, works)
  end
end

function LibraryThingApi:_saveSession(jar)
  if jar.cookie_userid ~= self:username() then
    self:_forgetAccountIds()
  end
  self.settings:updateSetting(SETTING.LIBRARYTHING.SESSION_COOKIE, cookie_header(jar))
  self.settings:updateSetting(SETTING.LIBRARYTHING.USERNAME, jar.cookie_userid)
  self.settings:updateSetting(SETTING.USER_ID, jar.cookie_usernum)
  self.last_auth_warning = nil
end

function LibraryThingApi:logout()
  self:_forgetAccountIds()
  self.settings:updateSetting(SETTING.LIBRARYTHING.SESSION_COOKIE, "")
  self.settings:updateSetting(SETTING.LIBRARYTHING.USERNAME, "")
  self.settings:updateSetting(SETTING.LIBRARYTHING.PASSWORD_ENC, "")
  self.settings:updateSetting(SETTING.LIBRARYTHING.PASSWORD_PLAIN, "")
  self.settings:updateSetting(SETTING.USER_ID, nil)
end

function LibraryThingApi:username()
  local username = self.settings and self.settings:readSetting(SETTING.LIBRARYTHING.USERNAME)
  if username and username ~= "" then return username end
  return session_cookies(self:sessionCookie()).cookie_userid
end

-- The account's number, which some edit forms need (book_usernum).
function LibraryThingApi:me()
  local usernum = session_cookies(self:sessionCookie()).cookie_usernum
  return { id = usernum or self:username() or "librarything_user" }
end

-- LibraryThing's site session cookie (LTAnonSessionID), which it sets on
-- any visitor (signed in or not), as a browser keeps it. Its search answers
-- with an error without one.
function LibraryThingApi:_siteSessionCookie()
  local value = self.site_session
    or (self.settings and self.settings:readSetting(SETTING.LIBRARYTHING.SITE_SESSION))
  return value and value ~= "" and ("LTAnonSessionID=" .. value) or nil
end

function LibraryThingApi:_keepSiteSession(set_cookie)
  local value
  for found in ("; " .. (set_cookie or "")):gmatch("[;,]%s*LTAnonSessionID=([^;,]*)") do
    value = found
  end
  if not value or value == "" or value == "deleted" or value == self.site_session then return false end
  self.site_session = value
  if self.settings then
    self.settings:updateSetting(SETTING.LIBRARYTHING.SITE_SESSION, value)
  end
  return true
end

-- Warn (once per cooldown) that the stored session no longer works.
function LibraryThingApi:notifyAuthFailure()
  local now = os.time()
  if self.last_auth_warning and now - self.last_auth_warning < 300 then
    return
  end
  self.last_auth_warning = now
  if self.on_error then
    self.on_error("Unauthorized")
  end
end

----------------------------------------------------------------------
-- Transport
----------------------------------------------------------------------

-- Response headers passed back from the subprocess: just what's used, one
-- per line, so no JSON (or newline in a value) is needed to carry them.
local META_HEADERS = { "location", "set-cookie", "cf-mitigated", "content-type" }

local function encode_response(code, headers, body)
  local lines = {}
  for _, name in ipairs(META_HEADERS) do
    local value = headers and headers[name]
    if type(value) == "table" then value = table.concat(value, ", ") end
    if value then
      table.insert(lines, name .. "\t" .. (tostring(value):gsub("[\r\n]", " ")))
    end
  end
  local meta = table.concat(lines, "\n")
  return tostring(code or "error") .. "\n" .. #meta .. "\n" .. meta .. (body or "")
end

local function decode_response(content)
  local code, meta_len, rest = (content or ""):match("^([^\n]*)\n(%d+)\n(.*)$")
  if not code then return nil end
  meta_len = tonumber(meta_len)
  local headers = {}
  for line in rest:sub(1, meta_len):gmatch("[^\n]+") do
    local name, value = line:match("^([^\t]+)\t(.*)$")
    if name then headers[name] = value end
  end
  return tonumber(code) or code, headers, rest:sub(meta_len + 1)
end

local function is_challenge(code, headers, body)
  if headers["cf-mitigated"] == "challenge" then return true end
  return code == 403 and type(body) == "string"
    and (body:find("Just a moment...", 1, true) ~= nil or body:find("cf_chl_", 1, true) ~= nil)
end

-- Where a request goes without a working session: the sign-in pages, or
-- (for the site's own scripts' requests) a "you're signed out" page.
local function is_sign_in_redirect(location)
  if type(location) ~= "string" then return false end
  local path = location:gsub("^https?://[^/]+", "")
  return path:match("^/signin") ~= nil or path:match("^/enter") ~= nil
    or path:match("^/signup") ~= nil or path:match("^/signoutconfirm") ~= nil
end

-- A short reason for a failed request: the transport error when nothing
-- came back, otherwise just the status. Never the response itself, which is
-- a whole HTML page that would end up in a message on the e-reader.
local function request_error(code, body)
  if not code then return body or "Request failed" end
  return "LibraryThing answered HTTP " .. tostring(code)
end

-- Sends one request to www.librarything.com and returns its status code,
-- body and the headers in META_HEADERS, or nil and a reason. Redirects
-- aren't followed: the cookies only ever go to librarything.com, and the
-- callers that expect one read its Location. `opts`:
--   method:  "GET" (default) or "POST"
--   form:    { { name, value }, ... } sent as the POST body
--   ajax:    sent as XMLHttpRequest, as the site's own scripts do
--   extract: run on a 200 response's body inside the subprocess, so a whole
--            page doesn't have to be passed back (or kept) to read part of it
--   base_url/user_agent/accept: override for the Android app sign-in request
--   no_cookies: don't send or save cookies for that request
--   no_retry: don't send it again when the first try doesn't complete, as
--            it may have reached LibraryThing anyway (adding a book twice)
--   timeout/maxtime: seconds, for LuaSocket
function LibraryThingApi:request(path, opts, auth_retried)
  opts = opts or {}
  if not self.enabled or not NetworkManager:isConnected() then
    return nil, "Network not connected"
  end

  local cookie = ""
  if not opts.no_cookies then
    cookie = self:sessionCookie()
    local site_session = self:_siteSessionCookie()
    if site_session then
      cookie = cookie ~= "" and (cookie .. "; " .. site_session) or site_session
    end
  end
  local body = opts.form and form_encode(opts.form) or nil
  local method = opts.method or (body and "POST" or "GET")
  local url = (opts.base_url or BASE_URL) .. path
  local headers = {
    ["User-Agent"] = opts.user_agent or T("ShelfSync/%1 (KOReader plugin; +https://github.com/Lyfts/ShelfSync)", table.concat(VERSION, ".")),
    ["Accept"] = opts.accept or (opts.ajax and "*/*" or "text/html,application/xhtml+xml"),
    ["Accept-Language"] = "en",
  }
  if cookie ~= "" then headers["Cookie"] = cookie end
  if opts.ajax then headers["X-Requested-With"] = "XMLHttpRequest" end
  if body then
    headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
    headers["Content-Length"] = tostring(#body)
  elseif method == "POST" then
    headers["Content-Length"] = "0"
  end

  local timeout, maxtime = opts.timeout or 15, opts.maxtime or 30
  local subprocess_fn = function()
    local sink = {}
    socketutil:set_timeout(timeout, maxtime)
    local ok, result, code, response_headers = pcall(http.request, {
      url = url,
      method = method,
      headers = headers,
      source = body and ltn12.source.string(body) or nil,
      sink = socketutil.table_sink(sink),
      redirect = false,
    })
    socketutil:reset_timeout()
    if not ok or not result then
      return encode_response("error", nil, tostring(ok and code or result or "request failed"))
    end
    local response = table.concat(sink)
    if code == 200 and opts.extract then
      response = opts.extract(response) or ""
    end
    return encode_response(code, response_headers, response)
  end

  -- Forking can fail to complete on some devices; one retry recovers most.
  -- An incomplete try can also be one the user dismissed, or one whose
  -- request was sent before it failed, so requests that change something
  -- that can't be changed twice opt out.
  local completed, content
  for attempt = 1, opts.no_retry and 1 or 2 do
    completed, content = Trapper:dismissableRunInSubprocess(subprocess_fn, true, true)
    if completed then break end
    if self.settings and attempt == 1 then
      self.settings:debugWarn("LibraryThing: request did not complete, retrying once: " .. path:match("^[^?]*"))
    end
  end
  if not (completed and content) then
    return nil, "Request failed"
  end

  local code, response_headers, response = decode_response(content)
  if code == nil then
    return nil, "Invalid response from LibraryThing"
  end
  if code == "error" then
    logger.warn("LibraryThing: request failed: " .. (opts.no_cookies and path:match("^[^?]*") or tostring(response)))
    return nil, response ~= "" and response or "Request failed"
  end

  local logged_path = path:match("^[^?]*")
  if not opts.no_cookies then
    response_headers.new_site_session = self:_keepSiteSession(response_headers["set-cookie"])
  end
  if is_challenge(code, response_headers, response) then
    logger.warn("LibraryThing: " .. method .. " " .. logged_path .. " got a Cloudflare challenge (HTTP " .. tostring(code) .. ")")
    return nil, CHALLENGE_ERROR, response_headers
  end

  if self.settings then
    self.settings:debugLog("LibraryThing: " .. method .. " " .. logged_path .. " -> HTTP " .. tostring(code))
  end

  local sign_in_redirect = (code == 301 or code == 302 or code == 303)
    and is_sign_in_redirect(response_headers.location)
  local signed_out_page = code == 200 and type(response) == "string"
    and response:find("LibraryThing%.is_signed_in%s*=%s*0") ~= nil
  if not opts.no_cookies and (code == 401 or sign_in_redirect or signed_out_page) then
    if not auth_retried then
      local username, password = self:username(), stored_password(self.settings)
      if username and password and self:login(username, password) then
        return self:request(path, opts, true)
      end
    end
    self:notifyAuthFailure()
    return nil, "Unauthorized", response_headers
  end

  return code, response, response_headers
end

----------------------------------------------------------------------
-- Searching
----------------------------------------------------------------------

-- Search result rows from ajax_newsearch.php's HTML.
local function parse_search_results(html)
  local books = {}
  local seen = {}
  for row in (html or ""):gmatch("<tr[^>]*>(.-)</tr>") do
    local work_id = row:match('data%-workid="(%d+)"')
    local item = row:match('<p class="item">(.-)</p>')
    if work_id and item and not seen[work_id] then
      seen[work_id] = true
      local title = html_text(item:match('<a[^>]*data%-workid="%d+"[^>]*>(.-)</a>'))
      local author = html_text(item:match('<a[^>]*href="/a/[^"]*"[^>]*>(.-)</a>'))
      local cover = row:match('<img[^>]*src="([^"]+)"')
      local members = (row:match("([%d,]+) members") or ""):gsub(",", "")
      if title and title ~= "" then
        table.insert(books, {
          id = work_id,
          book_id = work_id,
          title = title,
          contributions = author and author ~= "" and { { author = { name = author } } } or {},
          cached_image = cover and { url = decode_entities(cover) } or nil,
          users_count = tonumber(members),
        })
      end
    end
  end
  return books
end

-- Works matching `query` (title, author or ISBN). LibraryThing's search
-- page loads its results from this endpoint as base64-wrapped HTML.
function LibraryThingApi:searchWorks(query)
  query = (query or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if query == "" then return {} end

  local path = "/ajax_newsearch.php?search=" .. urlencode(query)
    .. "&searchtype=newwork_titles&page=1&sortchoice=0&optionidpotential=0&optionidreal=0"
  -- Without a site session, the search only sets one and answers with an
  -- error, so it's sent again with that.
  local code, body, headers
  for _attempt = 1, 2 do
    code, body, headers = self:request(path, { method = "POST", ajax = true })
    if not code then return {}, body end
    if code ~= 200 then return {}, "Search failed (HTTP " .. tostring(code) .. ")" end
    if not headers.new_site_session then break end
  end

  local encoded = body:match('"text"%s*:%s*"(.-)"')
  if not encoded then return {}, "Unexpected search response from LibraryThing" end
  local html = base64_decode(json_unescape(encoded))
  if html:find("If this error persists", 1, true) then
    return {}, "LibraryThing's search failed"
  end
  return parse_search_results(html)
end

-- `opts.autolink`: linking a book on its own (by title) only picks a work
-- that's already on LibraryThing, never an edition from a book source,
-- which adding would put in the library unasked.
function LibraryThingApi:findBooks(title, author, _user_id, opts)
  local query = title or ""
  -- Metadata authors can be "Last, First" or several names; the first one
  -- is enough to narrow the search.
  local first_author = type(author) == "string" and author:match("^[^\n&;]+")
  if first_author and first_author ~= "" then
    query = query .. " " .. first_author:gsub(",", " ")
  end
  local books, err = self:searchWorks(query)
  if err then return nil, err end
  -- The author can be spelled differently there; fall back to the title.
  if #books == 0 and first_author and title and title ~= "" then
    books, err = self:searchWorks(title)
    if err then return nil, err end
  end
  -- Not a work on LibraryThing yet (no member has added it): offer the
  -- editions the chosen book source has, as the "Add books" page does.
  if #books == 0 and not (opts and opts.autolink) and self:addSource() then
    books, err = self:searchSource(query)
    if not err and #books == 0 and first_author and title and title ~= "" then
      books, err = self:searchSource(title)
    end
    if err then return nil, err end
  end
  return books
end

-- A `librarything:<work id>` identifier names the work directly; otherwise
-- the ISBN is searched for, which LibraryThing resolves to its work.
function LibraryThingApi:findBookByIdentifiers(identifiers, _user_id)
  identifiers = identifiers or {}
  if identifiers.librarything_id then
    local work = self:_workDetails(identifiers.librarything_id)
    if work then
      return {
        id = identifiers.librarything_id,
        book_id = identifiers.librarything_id,
        title = work.title,
        pages = work.pages,
        contributions = work.author and { { author = { name = work.author } } } or {},
      }
    end
  end

  for _, isbn in ipairs({ identifiers.isbn_13, identifiers.isbn_10 }) do
    local books = self:searchWorks(isbn)
    if books and #books > 0 then
      return books[1]
    end
  end
  return nil
end

----------------------------------------------------------------------
-- The user's copy of a work
----------------------------------------------------------------------

local function collection_key(name)
  name = (name or ""):lower():gsub("%s+", " "):match("^%s*(.-)%s*$")
  for key, default_name in pairs(LIBRARYTHING.COLLECTION_NAMES) do
    if name == default_name then return key end
  end
end

-- Reading dates, oldest first as LibraryThing lists them: { started =
-- "YYYY-MM-DD" or nil, finished = ... }. Dates can be less precise
-- ("2013", "2013-12"), so they're kept as text.
local function parse_reading_dates(fragment)
  local reads = {}
  for row in (fragment or ""):gmatch("<div[^>]*>(.-)</div>") do
    local started = row:match("Started:%s*<span[^>]*>([^<]*)</span>")
    local finished = row:match("Finished:%s*<span[^>]*>([^<]*)</span>")
    if started or finished then
      table.insert(reads, {
        started = started and started ~= "" and started or nil,
        finished = finished and finished ~= "" and finished or nil,
      })
    end
  end
  return reads
end

-- `read_id` is the collection finished books are put in, if being in it
-- means a book's been read (not so for Your library, where owned books are).
local function status_for(collections, reads, read_id)
  local keys, in_read = {}, false
  for _, collection in ipairs(collections) do
    keys[collection.key or ""] = true
    if read_id and collection.id == read_id then in_read = true end
  end
  if keys[COLLECTION.READING] then return STATUS.READING end
  if keys[COLLECTION.TO_READ] then return STATUS.TO_READ end
  local last = reads[#reads]
  if (last and last.finished) or keys[COLLECTION.READ_UNOWNED] or in_read then
    return STATUS.FINISHED
  end
  return nil
end

-- What's known about the works this account has linked, kept between
-- sessions: work id -> { title, author, copy = the id of the user's copy }.
-- The copy is looked up once (see _findCopy) and then read directly.
function LibraryThingApi:_works()
  local works = self.settings and self.settings:readSetting(SETTING.LIBRARYTHING.WORKS)
  return type(works) == "table" and works or {}
end

-- Merges `fields` into what's kept for the work; a false value removes one.
function LibraryThingApi:rememberWork(work_id, fields)
  if not (self.settings and work_id) then return end
  local works = self:_works()
  local work = works[tostring(work_id)] or {}
  for key, value in pairs(fields) do
    if value == false then work[key] = nil else work[key] = value end
  end
  works[tostring(work_id)] = work
  self.settings:updateSetting(SETTING.LIBRARYTHING.WORKS, works)
end

-- Copy links (/work/<work>/book/<copy>) in a catalog page, as "work/copy"
-- lines, so the ~60 KB page needn't come back from the subprocess.
local function extract_copy_links(html)
  local lines, seen = {}, {}
  for link in html:gmatch("/work/(%d+/book/%d+)") do
    if not seen[link] then
      seen[link] = true
      table.insert(lines, link)
    end
  end
  return table.concat(lines, "\n")
end

local function copy_in_links(links, work_id)
  for work, copy in (links or ""):gmatch("(%d+)/book/(%d+)") do
    if work == tostring(work_id) then return copy end
  end
end

-- Finds the user's copy of the work by searching their catalog (all
-- collections) for `term`, as its "Search your library" box does.
function LibraryThingApi:_searchCatalog(work_id, term)
  term = (term or ""):match("^%s*(.-)%s*$")
  if term == "" then return nil end
  local username = self:username()
  if not username then return nil, "Not logged in to LibraryThing" end
  local code, links = self:request("/catalog_bottom.php?view=" .. urlencode(username)
    .. "&collection=-1&deepsearch=" .. urlencode(term), { extract = extract_copy_links })
  if not code then return nil, links end
  if code ~= 200 then return nil, "Failed to search your LibraryThing catalog (HTTP " .. tostring(code) .. ")" end
  return copy_in_links(links, work_id)
end

-- The user's copy of the work, looked up by its title and then its
-- author's surname, which also finds a copy with a different title (e.g. a
-- translation). Returns nil if there's none, or nil and an error.
function LibraryThingApi:_findCopy(work_id, work)
  local copy, err = self:_searchCatalog(work_id, work.title)
  if copy or err then return copy, err end
  local author = work.author or ""
  local surname = author:find(",", 1, true) and author:match("^%s*([^,]+)") or author:match("([^%s]+)%s*$")
  return self:_searchCatalog(work_id, surname)
end

-- Collections in the collection picker for a copy: every collection of
-- the account, `checked` for the ones the copy's in.
local function parse_collections_popup(html)
  local collections = {}
  for attrs, label in (html or ""):gmatch('<input([^<]-data%-cid="%d+"[^<]-)<span>([^<]*)</span>') do
    local name = html_text(label)
    table.insert(collections, {
      id = tonumber(attrs:match('data%-cid="(%d+)"')),
      name = name,
      key = collection_key(name),
      checked = attrs:find('checked="checked"', 1, true) ~= nil,
    })
  end
  return collections
end

-- The collections the copy is in, or an empty list if there's no such copy
-- (any copy is in at least one). Also learns the account's collection ids.
function LibraryThingApi:_copyCollections(copy_id)
  local code, body = self:request("/ajax_collections_popup.php", {
    ajax = true,
    form = {
      { "view_usernum", self:me().id },
      { "target", "shelfsync" },
      { "bookid", copy_id },
      { "is_ajax", 1 },
    },
  })
  if code ~= 200 then return nil, request_error(code, body) end

  local all = parse_collections_popup(body)
  if #all == 0 then
    return nil, "LibraryThing's collections couldn't be read"
  end
  self:_learnCollections(all)
  local copy_collections = {}
  for _, collection in ipairs(all) do
    if collection.checked then table.insert(copy_collections, collection) end
  end
  -- Renamed collections (e.g. another language) are known by their ids.
  for _, collection in ipairs(copy_collections) do
    if not collection.key then
      for key, id in pairs(self:_savedCollectionIds() or LIBRARYTHING.DEFAULT_COLLECTION_IDS) do
        if tonumber(id) == collection.id then collection.key = key end
      end
    end
  end
  return copy_collections
end

-- The copy's status, read from its collections and reading dates. nil
-- (without an error) if the copy no longer exists.
function LibraryThingApi:_copyStatus(work_id, copy_id, title)
  -- Read first: unlike the collection picker (which a signed-out request
  -- gets too, with nothing checked), this form redirects without a working
  -- session, so an expired one isn't taken for a deleted copy.
  local usernum = self:me().id
  local rows, err = self:_readingDateRows(work_id, copy_id, usernum)
  if not rows then return nil, err end

  local collections
  collections, err = self:_copyCollections(copy_id)
  if not collections then return nil, err end
  if #collections == 0 then return nil end
  local reads = {}
  for _, row in ipairs(rows) do
    if row.started ~= "" or row.finished ~= "" then
      table.insert(reads, {
        started = row.started ~= "" and row.started or nil,
        finished = row.finished ~= "" and row.finished or nil,
      })
    end
  end

  return {
    id = tostring(copy_id),
    book_id = tostring(work_id),
    usernum = usernum,
    title = title,
    collections = collections,
    reading_dates = reads,
    status_id = status_for(collections, reads, self:_readCollectionIdForStatus()),
  }
end

-- The work's status for the user: `id` is their copy's id, unset if it's
-- not in their library; `status_id` is unset if no collection or reading
-- date gives it one. Only the small requests the site's own scripts make
-- are used once the work's title is known (see linkBook), as Cloudflare
-- challenges plugins on librarything.com's work pages.
function LibraryThingApi:findUserBook(work_id, _user_id)
  if not work_id then return nil, "No LibraryThing work" end
  work_id = tostring(work_id)
  local work = self:_works()[work_id] or {}

  if work.copy then
    local status, err = self:_copyStatus(work_id, work.copy, work.title)
    if status or err then return status, err end
    -- Deleted on LibraryThing since, or another account's.
    self:rememberWork(work_id, { copy = false })
  end

  -- Without a title to search the catalog for, the work page has the copy,
  -- if Cloudflare lets it through.
  if not work.title then
    local status, err = self:_findUserBookOnWorkPage(work_id)
    if status then
      self:rememberWork(work_id, { title = status.title or false, copy = status.id or false })
    end
    return status, err
  end

  local copy, err = self:_findCopy(work_id, work)
  if err then return nil, err end
  if not copy then
    return { book_id = work_id, title = work.title }
  end
  self:rememberWork(work_id, { copy = copy })
  local status
  status, err = self:_copyStatus(work_id, copy, work.title)
  if status or err then return status, err end
  return { book_id = work_id, title = work.title }
end

-- Keeps only what parse_user_book reads from a work page (~250 KB), so
-- that's all that comes back from the subprocess.
local function extract_work_page(html)
  local parts = {}
  table.insert(parts, html:match("<title>.-</title>") or "")
  table.insert(parts, html:match("LibraryThing%.is_signed_in%s*=%s*%d+") or "")
  local start = html:find("book_info_area yourbook", 1, true)
  if start then
    table.insert(parts, html:sub(start, start + 30000))
  end
  return table.concat(parts, "\n")
end

-- The contents of the panel's <dd> for `field`. LibraryThing pads the tag's
-- attributes with spaces (`<dd  class="edit_field_collections" >`).
local function panel_field(panel, field)
  return panel:match('<dd[^>]-class="edit_field_' .. field .. '"[^>]*>(.-)</dd>')
end

-- The user's copy of `work_id`, from the work page's "Your Book
-- Information" panel, which is only there while it's in their library.
-- (The page's own bookID isn't the user's copy: it's set for any work.)
local function parse_user_book(html, work_id, collection_ids, read_id)
  -- The account's number when signed in, 0 when not.
  local signed_in = html:match("LibraryThing%.is_signed_in%s*=%s*(%d+)")
  if signed_in == "0" then
    return nil, "Unauthorized"
  end

  -- "<title> by <author> | LibraryThing"; the title itself can contain "by".
  local title = html_text(html:match("<title>(.-)</title>"))
  title = title and title:gsub("%s*|%s*LibraryThing%s*$", "")
  title = title and (title:match("^(.*)%s+by%s+") or title)
  local status = { book_id = tostring(work_id), title = title ~= "" and title or nil }

  local start = html:find("book_info_area yourbook", 1, true)
  if not start then
    return status
  end
  local panel = html:sub(start)

  local usernum, copy_id = panel:match("open_collection_popup%((%d+),%s*{'bookid':(%d+)")
  copy_id = copy_id or panel:match("setRating%('[^']*',%s*'(%d+)'")
  if not copy_id then
    return status
  end
  status.id = copy_id
  status.usernum = usernum

  status.collections = {}
  local collections_html = panel_field(panel, "collections") or ""
  for id, name in collections_html:gmatch('<a class="coll_(%d+)"[^>]*>(.-)</a>') do
    name = html_text(name)
    local key = collection_key(name)
    -- An account whose collections are named differently (e.g. another
    -- language) still has them under the ids its own panel uses.
    if not key and collection_ids then
      for candidate, candidate_id in pairs(collection_ids) do
        if tostring(candidate_id) == id then key = candidate end
      end
    end
    table.insert(status.collections, { id = tonumber(id), name = name, key = key })
  end

  for tag in panel:gmatch("<input[^>]*>") do
    if tag:find('name="form_rating"', 1, true) then
      status.rating = tonumber(tag:match('value="(%d+)"'))
      break
    end
  end

  status.reading_dates = parse_reading_dates(panel_field(panel, "reading_dates"))
  local pages = (panel_field(panel, "pub_basic") or ""):match("([%d,]+) pages")
  status.page_count = pages and tonumber((pages:gsub(",", ""))) or nil
  status.status_id = status_for(status.collections, status.reading_dates, read_id)
  return status
end

function LibraryThingApi:_findUserBookOnWorkPage(work_id)
  local code, body = self:request("/work/" .. urlencode(work_id), {
    extract = extract_work_page,
  })
  if not code then return nil, body end
  if code ~= 200 then
    return nil, "Failed to load the LibraryThing work (HTTP " .. tostring(code) .. ")"
  end

  local status, err = parse_user_book(body, work_id, self:_savedCollectionIds(), self:_readCollectionIdForStatus())
  if err == "Unauthorized" then
    self:notifyAuthFailure()
  end
  return status, err
end

----------------------------------------------------------------------
-- Book sources ("Add books")
----------------------------------------------------------------------

-- The book source searched for books that aren't on LibraryThing yet,
-- { id, name }, or nil if that's turned off.
function LibraryThingApi:addSource()
  local chosen = self.settings and self.settings:readSetting(SETTING.LIBRARYTHING.ADD_SOURCE)
  if chosen == false then return nil end
  if type(chosen) == "table" and tonumber(chosen.id) then
    return { id = tonumber(chosen.id), name = chosen.name }
  end
  return LIBRARYTHING.ADD_SOURCES[1]
end

-- `source` is { id, name }, or false to not search any.
function LibraryThingApi:setAddSource(source)
  self.settings:updateSetting(SETTING.LIBRARYTHING.ADD_SOURCE,
    source and { id = source.id, name = source.name } or false)
end

-- Each result's record (the edition's catalogue data, as JSON in its
-- data-record attribute), one per line, so the ~100 KB of result HTML
-- needn't come back from the subprocess.
local function extract_source_records(html)
  -- Only result rows carry a data-record; its quotes are escaped, so it ends
  -- at the next one (unlike the tag, as the JSON can hold a ">").
  local records = {}
  for record in html:gmatch('data%-record="([^"]*)"') do
    table.insert(records, record)
  end
  return table.concat(records, "\n")
end

local function json_value(value)
  -- JSON null, however the decoder represents it.
  if value == nil or (json.null and value == json.null) or type(value) == "function" or type(value) == "userdata" then
    return nil
  end
  return value
end

-- "Yarros, Rebecca" -> "Rebecca Yarros", as the work search shows authors.
local function unflip(name)
  local last, first = (name or ""):match("^%s*([^,]+),%s*(.-)%s*$")
  if last and first ~= "" then return first .. " " .. last end
  return name
end

-- An edition from a book source, as a search result. Its id isn't a work
-- (there isn't one yet), but a key to the record kept to add it.
local function source_book(id, record, source)
  local text = function(key)
    local value = json_value(record[key])
    return type(value) ~= "table" and value ~= nil and tostring(value) or nil
  end
  local author = text("books_author")
  local pages = tonumber(text("books_pages") or "")
  return {
    id = id,
    book_id = id,
    title = decode_entities(text("books_title") or ""),
    contributions = author and { { author = { name = decode_entities(unflip(author)) } } } or {},
    isbn = text("books_ISBN"),
    pub_date = text("books_date"),
    publisher = decode_entities(text("books_publication") or text("publisher_place") or ""),
    edition_format = source.name,
    pages = pages,
    page_count = pages,
  }
end

-- Editions matching `query` in the chosen book source, as search results.
-- Picking one adds it (see addSourceEdition), which creates its work.
function LibraryThingApi:searchSource(query)
  local source = self:addSource()
  query = (query or ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if not source or query == "" then return {} end

  local code, records = self:request("/response_search_beta_lt2.php", {
    ajax = true,
    form = {
      { "form_find", query },
      { "new_search", 1 },
      { "form_tags", "" },
      { "books_collections[]", self:collectionId(COLLECTION.LIBRARY) },
      { "libraryChoice", source.id },
      { "forceLT2", 1 },
      { "is_ajax", 1 },
    },
    extract = extract_source_records,
  })
  if not code then return {}, records end
  if code ~= 200 then return {}, request_error(code, records) end

  self.source_records = {}
  local books = {}
  for raw in (records or ""):gmatch("[^\n]+") do
    local ok, record = pcall(json.decode, decode_entities(raw))
    if ok and type(record) == "table" and json_value(record.books_title) then
      local id = "source:" .. (#books + 1)
      self.source_records[id] = record
      table.insert(books, source_book(id, record, source))
      if #books >= 20 then break end
    end
  end
  return books
end

function LibraryThingApi:isSourceEdition(book_id)
  return type(book_id) == "string" and book_id:match("^source:") ~= nil
end

-- The record as the "Add books" page posts it: jQuery's encoding of nested
-- objects and arrays (a[0][b]=..., a[]=...), with nulls left out.
local function append_record_fields(fields, prefix, value)
  value = json_value(value)
  if value == nil then return end
  if type(value) == "table" then
    if #value > 0 then
      for i, item in ipairs(value) do
        if type(item) == "table" then
          append_record_fields(fields, prefix .. "[" .. (i - 1) .. "]", item)
        else
          append_record_fields(fields, prefix .. "[]", item)
        end
      end
    else
      local keys = {}
      for key in pairs(value) do table.insert(keys, key) end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, key in ipairs(keys) do
        local name = prefix and (prefix .. "[" .. tostring(key) .. "]") or tostring(key)
        append_record_fields(fields, name, value[key])
      end
    end
  elseif type(value) == "number" and value == math.floor(value) then
    table.insert(fields, { prefix, string.format("%d", value) })
  else
    table.insert(fields, { prefix, tostring(value) })
  end
end

-- Adds an edition found by searchSource to the library, in the collections
-- with the given ids, as the "Add books" page does, which creates its work.
-- Returns the work's and the new copy's ids.
function LibraryThingApi:addSourceEdition(book_id, collection_ids)
  local record = self.source_records and self.source_records[book_id]
  if not record then return nil, "Search for the book again" end

  local form = {}
  append_record_fields(form, nil, record)
  table.insert(form, { "form_tags", "" })
  for _, id in ipairs(collection_ids) do
    table.insert(form, { "books_collections[]", id })
  end
  table.insert(form, { "forceLT2", 1 })
  table.insert(form, { "is_ajax", 1 })

  -- Not sent twice: an interrupted try may have added it already.
  local code, links = self:request("/addbook_regular.php", {
    ajax = true,
    no_retry = true,
    form = form,
    extract = extract_copy_links,
  })
  if code ~= 200 then return nil, request_error(code, links) end
  local work_id, copy_id = (links or ""):match("(%d+)/book/(%d+)")
  if not work_id then
    logger.warn("LibraryThing: adding an edition from a book source was refused")
    return nil, "LibraryThing couldn't add the book to your library"
  end
  self.source_records[book_id] = nil
  self:rememberWork(work_id, { copy = copy_id })
  return work_id, copy_id
end

----------------------------------------------------------------------
-- Collections
----------------------------------------------------------------------

function LibraryThingApi:_savedCollectionIds()
  local saved = self.settings and self.settings:readSetting(SETTING.LIBRARYTHING.COLLECTION_IDS)
  return type(saved) == "table" and saved or nil
end

-- Collection key -> id for this account. Learned from the collection lists
-- LibraryThing shows (see _learnCollections); the defaults are what every
-- account has had them numbered as so far.
function LibraryThingApi:collectionId(key)
  local saved = self:_savedCollectionIds()
  return (saved and tonumber(saved[key])) or LIBRARYTHING.DEFAULT_COLLECTION_IDS[key]
end

-- Keeps the account's collections, { { id, name, key }, ... }, and the ids
-- of the ones ShelfSync uses by name.
function LibraryThingApi:_learnCollections(collections)
  if not self.settings or #collections == 0 then return end
  local list, ids = {}, {}
  for _, collection in ipairs(collections) do
    table.insert(list, { id = collection.id, name = collection.name })
    if collection.key then ids[collection.key] = collection.id end
  end
  self.settings:updateSetting(SETTING.LIBRARYTHING.COLLECTIONS, list)
  if next(ids) then
    self.settings:updateSetting(SETTING.LIBRARYTHING.COLLECTION_IDS, ids)
  end
end

-- The account's collections, as last seen on LibraryThing (or its default
-- ones until then), each { id, name, key }.
function LibraryThingApi:collections()
  local saved = self.settings and self.settings:readSetting(SETTING.LIBRARYTHING.COLLECTIONS)
  local list = {}
  for _, collection in ipairs(type(saved) == "table" and #saved > 0 and saved or LIBRARYTHING.DEFAULT_COLLECTIONS) do
    table.insert(list, { id = tonumber(collection.id), name = collection.name, key = collection_key(collection.name) })
  end
  return list
end

-- Reads the account's collections from LibraryThing again.
function LibraryThingApi:refreshCollections()
  local code, body = self:request("/ajax_collections_popup.php", {
    ajax = true,
    form = { { "view_usernum", self:me().id }, { "target", "shelfsync" }, { "is_ajax", 1 } },
  })
  if not code then return nil, body end
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  local collections = parse_collections_popup(body)
  if #collections == 0 then return nil, "LibraryThing's collections couldn't be read" end
  self:_learnCollections(collections)
  return self:collections()
end

-- The collection a finished book is put in, { id, name }: the one chosen
-- in the menu, or Your library.
function LibraryThingApi:readCollection()
  local chosen = self.settings and self.settings:readSetting(SETTING.LIBRARYTHING.READ_COLLECTION)
  local id = type(chosen) == "table" and tonumber(chosen.id)
  -- Never a status collection, whatever's saved, nor one that's no longer
  -- on LibraryThing.
  if id and id ~= self:collectionId(COLLECTION.READING) and id ~= self:collectionId(COLLECTION.TO_READ) then
    for _, collection in ipairs(self:collections()) do
      if collection.id == id then return { id = id, name = collection.name } end
    end
  end
  local library = self:collectionId(COLLECTION.LIBRARY)
  for _, collection in ipairs(self:collections()) do
    if collection.id == library then return { id = library, name = collection.name } end
  end
  return { id = library, name = "Your library" }
end

function LibraryThingApi:setReadCollection(collection)
  self.settings:updateSetting(SETTING.LIBRARYTHING.READ_COLLECTION,
    collection and { id = collection.id, name = collection.name } or nil)
end

-- The read collection's id, if being in it means a book's been read.
function LibraryThingApi:_readCollectionIdForStatus()
  local id = self:readCollection().id
  if id ~= self:collectionId(COLLECTION.LIBRARY) then return id end
end

-- Collections in the express-add form, each { id, name, key }.
local function parse_collection_checkboxes(html)
  local collections = {}
  for tag, label in (html or ""):gmatch('(<input[^>]*name="books_collections%[%]"[^>]*>)%s*<span>(.-)</span>') do
    local id = tonumber(tag:match('value="(%d+)"'))
    local name = html_text(label)
    if id then table.insert(collections, { id = id, name = name, key = collection_key(name) }) end
  end
  return collections
end

-- The add-book form for a work: lists the account's collections, and holds
-- the key the express add needs (see _addWork).
function LibraryThingApi:_addForm(work_id)
  local code, form_html = self:request("/ajax_lb_addbooks_express_open.php", {
    ajax = true,
    form = { { "workcode", work_id }, { "forceLT2", 1 }, { "is_lightbox_request", 1 }, { "is_ajax", 1 } },
  })
  if code ~= 200 then return nil, request_error(code, form_html) end

  local collections = parse_collection_checkboxes(form_html)
  if #collections == 0 then
    return nil, "LibraryThing didn't accept the saved session. Enter its session cookies again."
  end
  self:_learnCollections(collections)
  return form_html
end

-- Checks the saved session by opening the add-book form for a well-known
-- work, which only lists the account's collections when signed in (and so
-- also learns their ids). Returns true, or nil and why not.
local TEST_WORK_ID = "8556314"

function LibraryThingApi:testConnection()
  if not self:hasCredential() then
    return nil, "Not logged in to LibraryThing"
  end
  local form_html, err = self:_addForm(TEST_WORK_ID)
  if not form_html then return nil, err end
  return true
end

-- Parses the collection list ajax_collectionsToggleBook.php returns.
local function parse_toggle_response(html)
  local collections = {}
  for id, name in (html or ""):gmatch('collection=(%d+)"[^>]*>(.-)</a>') do
    table.insert(collections, { id = tonumber(id), name = html_text(name) })
  end
  return collections
end

-- Adds the copy to (or removes it from) a collection, by id. LibraryThing
-- won't remove a copy's last collection, so callers add another one first.
function LibraryThingApi:setCollection(copy_id, collection_id, add)
  local code, body = self:request("/ajax_collectionsToggleBook.php", {
    ajax = true,
    form = {
      { "bookid", copy_id },
      { "c_id", collection_id },
      { "addRemove", add and 1 or 0 },
      { "returnUI", 1 },
      { "containerID", "collections" .. tostring(copy_id) },
      { "excludeContainer", 1 },
      { "is_catalogB", 0 },
    },
  })
  if code ~= 200 then
    return nil, request_error(code, body)
  end
  local now_in = false
  for _, collection in ipairs(parse_toggle_response(body)) do
    if collection.id == collection_id then now_in = true end
  end
  if now_in ~= (add and true or false) then
    return nil, "LibraryThing didn't update the collection"
  end
  return true
end

local function in_collection(status, id)
  for _, collection in ipairs(status.collections or {}) do
    if collection.id == id then return true end
  end
  return false
end

----------------------------------------------------------------------
-- Adding a work to the library
----------------------------------------------------------------------

-- The edition the site's "express add" picks for a work, as the HTML it
-- shows for it: the work's title and author, the edition's page count, and
-- the hidden fields the add needs. Its form names the account's
-- collections and holds the key for this.
function LibraryThingApi:_bestEdition(work_id)
  local form_html, err = self:_addForm(work_id)
  if not form_html then return nil, err end

  local memcache_key = input_value(form_html, "memcache_key")
  if not memcache_key or memcache_key == "" then
    return nil, "LibraryThing's add form couldn't be read"
  end

  local code, edition_json = self:request("/ajax_addbooks_express_show_bestwork.php?memcache_key="
    .. urlencode(memcache_key) .. "&workcode=" .. urlencode(work_id) .. "&show_media_source=0", {
    ajax = true,
    form = { { "fancy_type[#abx_data_info]", "full" }, { "forceLT2", 1 }, { "is_ajax", 1 } },
  })
  if code ~= 200 then return nil, request_error(code, edition_json) end
  return json_unescape(edition_json or "")
end

-- Title, author and page count of a work, for one linked by its id.
function LibraryThingApi:_workDetails(work_id)
  local edition, err = self:_bestEdition(work_id)
  if not edition then return nil, err end
  local title = html_text(edition:match('class="card_title[^"]*"[^>]*>%s*<a[^>]*>(.-)</a>'))
  if not title or title == "" then return nil, "LibraryThing work not found" end
  local pages = edition:match("([%d,]+) pages")
  return {
    title = title,
    author = html_text(edition:match('class="card_author[^"]*"[^>]*>%s*<a[^>]*>(.-)</a>')),
    pages = pages and tonumber((pages:gsub(",", ""))) or nil,
  }
end

-- The user's copy of a work that was just added, from the list of books
-- they added most recently.
function LibraryThingApi:_recentlyAddedCopy(work_id)
  local code, links = self:request("/response_list_lt2.php", {
    ajax = true,
    form = { { "fragment", 1 }, { "limit", 5 }, { "forceLT2", 1 }, { "is_ajax", 1 } },
    extract = extract_copy_links,
  })
  if code ~= 200 then return nil, request_error(code, links) end
  return copy_in_links(links, work_id)
end

-- Adds the work to the library through the site's "express add", in the
-- collections with the given ids, and returns the new copy's id.
function LibraryThingApi:_addWork(work_id, collection_ids)
  local edition, err = self:_bestEdition(work_id)
  if not edition then return nil, err end

  local ids = {}
  for _, id in ipairs(collection_ids) do
    table.insert(ids, tostring(id))
  end
  local query = {
    { "tags", "" },
    { "rating", 0 },
    { "collection", table.concat(ids, ",") },
    { "record_id", input_value(edition, "record_id") or "" },
    { "source_type", input_value(edition, "source_type") or "" },
    { "source_id", input_value(edition, "source_id") or "" },
    { "workcode", work_id },
    { "isbn", input_value(edition, "isbn") or "" },
    { "idealbook", input_value(edition, "idealbook") or "" },
  }
  local add_code, result = self:request("/action_addbooks_express_add_book.php?" .. form_encode(query), {
    method = "POST",
    no_retry = true,
    ajax = true,
    form = { { "forceLT2", 1 }, { "is_ajax", 1 } },
  })
  if add_code ~= 200 then return nil, request_error(add_code, result) end
  if not html_text(result):match("^Added") then
    logger.warn("LibraryThing: express add was refused")
    return nil, "LibraryThing couldn't add the book to your library"
  end

  local copy
  copy, err = self:_recentlyAddedCopy(work_id)
  if not copy then
    return nil, err or "The book was added, but its copy couldn't be found"
  end
  self:rememberWork(work_id, { copy = copy })
  return copy
end

----------------------------------------------------------------------
-- Reading dates
----------------------------------------------------------------------

-- The copy's reading dates as its edit form lists them: rows 1..n, each
-- { started, finished } as entered (possibly ""), so they can be sent
-- back as they were.
function LibraryThingApi:_readingDateRows(work_id, copy_id, usernum)
  local code, body = self:request("/ajax_lb_newwork_edit_bookfields.php?work=" .. urlencode(work_id)
    .. "&book=" .. urlencode(copy_id) .. "&type=reading_dates&book_usernum=" .. urlencode(usernum), {
    ajax = true,
    form = { { "forceLT2", 1 }, { "is_lightbox_request", 1 }, { "is_ajax", 1 } },
  })
  if code ~= 200 then return nil, request_error(code, body) end
  if not body:find("edit_type", 1, true) then
    return nil, "LibraryThing's reading dates couldn't be read"
  end

  local rows = {}
  for tag in body:gmatch("<input[^>]*>") do
    local kind, index = tag:match('name="newdate(%a+)A%[(%d+)%]"')
    index = tonumber(index)
    if index and index > 0 then
      rows[index] = rows[index] or { started = "", finished = "" }
      local value = decode_entities(tag:match('value="([^"]*)"') or "")
      if kind == "started" then rows[index].started = value end
      if kind == "ended" then rows[index].finished = value end
    end
  end
  local list = {}
  for i = 1, #rows do table.insert(list, rows[i]) end
  return list
end

-- Replaces the copy's reading dates with `rows` (the form saves them all at
-- once), plus the empty row the form always sends.
function LibraryThingApi:_saveReadingDateRows(work_id, copy_id, usernum, rows)
  local form = {
    { "edit_work", work_id },
    { "edit_book", copy_id },
    { "book_usernum", usernum },
    { "edit_type", "reading_dates" },
  }
  for i, row in ipairs(rows) do
    table.insert(form, { "newdatestartedA[" .. i .. "]", row.started or "" })
    table.insert(form, { "newdateendedA[" .. i .. "]", row.finished or "" })
  end
  table.insert(form, { "newdatestartedA[0]", "" })
  table.insert(form, { "newdateendedA[0]", "" })

  local code, body = self:request("/ajax_newwork_edit_bookfields_submit.php", { ajax = true, form = form })
  if code ~= 200 then return nil, request_error(code, body) end
  if not (body or ""):find("edit_field_reading_dates", 1, true) then
    return nil, "LibraryThing didn't save the reading dates"
  end
  return true
end

-- Starts a read today, unless one's already open.
function LibraryThingApi:_startRead(status)
  local usernum = status.usernum or self:me().id
  local rows, err = self:_readingDateRows(status.book_id, status.id, usernum)
  if not rows then return nil, err end
  local last = rows[#rows]
  if last and last.started ~= "" and last.finished == "" then
    return true
  end
  table.insert(rows, { started = today(), finished = "" })
  return self:_saveReadingDateRows(status.book_id, status.id, usernum, rows)
end

-- Finishes the open read on `date` (YYYY-MM-DD), or adds a read finished
-- then if none is open. A read already finished on that date is left be.
function LibraryThingApi:_finishRead(status, date)
  local usernum = status.usernum or self:me().id
  local rows, err = self:_readingDateRows(status.book_id, status.id, usernum)
  if not rows then return nil, err end
  local last = rows[#rows]
  if last and last.started ~= "" and last.finished == "" then
    last.finished = date
  elseif last and last.finished == date then
    return true
  else
    table.insert(rows, { started = "", finished = date })
  end
  return self:_saveReadingDateRows(status.book_id, status.id, usernum, rows)
end

----------------------------------------------------------------------
-- Status
----------------------------------------------------------------------

-- Ids of the collections a copy is in for `status_id`: the status's own,
-- or for Finished the one chosen for read books (see readCollection).
function LibraryThingApi:_statusCollectionId(status_id)
  if status_id == STATUS.READING then return self:collectionId(COLLECTION.READING) end
  if status_id == STATUS.TO_READ then return self:collectionId(COLLECTION.TO_READ) end
  if status_id == STATUS.FINISHED then return self:readCollection().id end
end

-- Collections to put a copy in when it's added for `status_id`.
function LibraryThingApi:_addCollectionIds(status_id)
  local library = self:collectionId(COLLECTION.LIBRARY)
  local id = self:_statusCollectionId(status_id)
  if id == library then return { library } end
  -- A finished book goes only where read books are kept, which needn't be
  -- the library (e.g. Read but unowned).
  if status_id == STATUS.FINISHED then return { id } end
  return { library, id }
end

-- Puts the copy in the collection for `status_id`, then takes it out of the
-- other status collections (Currently reading, To read). With no status
-- (Remove), a copy that'd be left in none goes in Your library, as
-- LibraryThing keeps every copy in one.
function LibraryThingApi:_moveToStatusCollection(status, status_id)
  local keep = status_id and self:_statusCollectionId(status_id)
  if keep and not in_collection(status, keep) then
    local ok, err = self:setCollection(status.id, keep, true)
    if not ok then return nil, err end
    table.insert(status.collections, { id = keep })
  end

  local status_ids = { self:collectionId(COLLECTION.READING), self:collectionId(COLLECTION.TO_READ) }
  local others = 0
  for _, collection in ipairs(status.collections or {}) do
    if collection.id ~= status_ids[1] and collection.id ~= status_ids[2] then others = others + 1 end
  end
  if others == 0 and not keep then
    local library = self:collectionId(COLLECTION.LIBRARY)
    local ok, err = self:setCollection(status.id, library, true)
    if not ok then return nil, err end
  end

  for _, id in ipairs(status_ids) do
    if id ~= keep and in_collection(status, id) then
      local ok, err = self:setCollection(status.id, id, false)
      if not ok then return nil, err end
    end
  end
  return true
end

-- Sets the work's status, adding it to the library if it isn't there yet,
-- and returns its status as read back afterwards. `finished_at` (a
-- timestamp) dates a Finished status, by default today.
function LibraryThingApi:updateUserBook(work_id, status_id, finished_at)
  if not self:_statusCollectionId(status_id) then
    return nil, "LibraryThing has no " .. tostring(LIBRARYTHING.STATUS_NAME[status_id] or status_id) .. " status"
  end

  local status, err = self:findUserBook(work_id)
  if not status then return nil, err end

  if not status.id then
    local copy, add_err = self:_addWork(work_id, self:_addCollectionIds(status_id))
    if not copy then return nil, add_err end
    status, err = self:_copyStatus(work_id, copy, status.title)
    if not status then
      return nil, err or "The book was added, but its copy couldn't be found"
    end
  end

  local ok
  ok, err = self:_moveToStatusCollection(status, status_id)
  if ok and status_id == STATUS.READING then
    ok, err = self:_startRead(status)
  elseif ok and status_id == STATUS.FINISHED then
    ok, err = self:_finishRead(status, iso_date(finished_at))
  end
  if not ok then return nil, err end

  return self:findUserBook(work_id)
end

-- Dates the work's latest read as finished on `finished_at`, for a finish
-- that was queued while offline and so set as of the day it was sent. A
-- read finished before `finished_at` is an earlier one, e.g. the first read
-- of a book being re-read, so it's kept and a read finished then is added.
function LibraryThingApi:setDateFinished(work_id, finished_at)
  local status = self:findUserBook(work_id)
  if not status or not status.id then return false end
  local reads = status.reading_dates or {}
  local last = reads[#reads]
  local date = iso_date(finished_at)
  if last and last.finished == date then return true end

  local usernum = status.usernum or self:me().id
  local rows = self:_readingDateRows(work_id, status.id, usernum)
  if not rows then return false end
  local row = rows[#rows]
  -- Dates are YYYY-MM-DD, or less precise ("2013", "2013-12"), which sort
  -- before any day in them, so they're taken for an earlier read too.
  if row and (row.finished == "" or row.finished > date) then
    row.finished = date
  else
    table.insert(rows, { started = "", finished = date })
  end
  return self:_saveReadingDateRows(work_id, status.id, usernum, rows) == true
end

-- "Remove" in the status menu: takes the copy out of the status
-- collections, keeping it (and its reading dates) in the library.
function LibraryThingApi:removeRead(copy_id)
  -- Cache:queueBookRemoval only passes the copy's id.
  local work_id
  for id, work in pairs(self:_works()) do
    if tostring(work.copy) == tostring(copy_id) then work_id = id end
  end
  local status = work_id and self:findUserBook(work_id)
  if not status or tostring(status.id) ~= tostring(copy_id) then return false end
  local ok = self:_moveToStatusCollection(status, nil)
  return ok == true
end

----------------------------------------------------------------------
-- Rating and review
----------------------------------------------------------------------

-- Rating in half stars, 0-10.
function LibraryThingApi:setRating(copy_id, rating)
  local code, body = self:request("/ajax_setBookRating.php", {
    ajax = true,
    form = {
      { "uid", "shelfsync" },
      { "book", copy_id },
      { "editable", 1 },
      { "container", "rate-shelfsync" },
      { "style", 306 },
      { "rating", rating },
      { "is_catalogB", 0 },
      { "is_addbooksB", 0 },
    },
  })
  if code ~= 200 then return nil, request_error(code, body) end
  return true
end

-- Saves the review text, with the rating as `rating` (half stars) or as
-- the form has it, as with the review language.
function LibraryThingApi:setReview(status, text, rating)
  local usernum = status.usernum or self:me().id
  local path = "/ajax_lb_newwork_edit_bookfields.php?work=" .. urlencode(status.book_id)
    .. "&book=" .. urlencode(status.id) .. "&type=review&book_usernum=" .. urlencode(usernum)
  local code, form_html = self:request(path, {
    ajax = true,
    form = { { "forceLT2", 1 }, { "is_lightbox_request", 1 }, { "is_ajax", 1 } },
  })
  if code ~= 200 then return nil, request_error(code, form_html) end

  local language = form_html:match('<select[^>]*name="form_review_language".-<option[^>]*value="(%a+)"[^>]*selected')
    or input_value(form_html, "language") or "eng"
  local submit_code, body = self:request("/ajax_newwork_edit_bookfields_submit.php", {
    ajax = true,
    form = {
      { "edit_work", status.book_id },
      { "edit_book", status.id },
      { "book_usernum", usernum },
      { "edit_type", "review" },
      { "form_review", text },
      { "form_review_language", language },
      { "form_rating", rating or tonumber(input_value(form_html, "form_rating")) or 0 },
      { "language", language },
    },
  })
  if submit_code ~= 200 then return nil, request_error(submit_code, body) end
  if not (body or ""):find("edit_field_review", 1, true) then
    return nil, "LibraryThing didn't save the review"
  end
  return true
end

-- LibraryThing has no reading journal for notes.
function LibraryThingApi:createJournalEntry(_data)
  return nil, "LibraryThing doesn't support notes"
end

-- Exposed for the specs.
LibraryThingApi._parse = {
  base64_decode = base64_decode,
  decode_entities = decode_entities,
  session_cookies = session_cookies,
  parse_search_results = parse_search_results,
  parse_user_book = parse_user_book,
  parse_collection_checkboxes = parse_collection_checkboxes,
  parse_collections_popup = parse_collections_popup,
  extract_copy_links = extract_copy_links,
  parse_toggle_response = parse_toggle_response,
  extract_work_page = extract_work_page,
  encode_response = encode_response,
  decode_response = decode_response,
  extract_source_records = extract_source_records,
  append_record_fields = append_record_fields,
}

return LibraryThingApi
