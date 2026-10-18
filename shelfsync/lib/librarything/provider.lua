local _ = require("gettext")
local logger = require("shelfsync/lib/common/safe_logger")

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local BaseProvider = require("shelfsync/lib/common/base_provider")
local LIBRARYTHING = require("shelfsync/lib/librarything/constants")

local LibraryThing = setmetatable({
  allows_new_read = true,
  -- LibraryThing keeps no reading progress (see api.lua), so there's none
  -- to read back or send; finishing a book is what gets synced.
  has_remote_progress = false,
  tracks_progress = false,
  -- No reading journal to send highlights or notes to.
  supports_notes = false,
  -- A work page that loads always shows whether the copy is in a status
  -- collection, so a missing status is real, not a failed read.
  has_reliable_status = true,
}, { __index = BaseProvider })
LibraryThing.__index = LibraryThing

function LibraryThing:linkBook(book, link_method)
  local filename = self.ui.document.file

  -- An edition from a book source (see api.lua's searchSource) isn't a work
  -- on LibraryThing yet: adding it to the library makes one, which is then
  -- linked as usual (and set to Currently reading below).
  if self.api:isSourceEdition(book.book_id) then
    local work_id, err = self.api:addSourceEdition(book.book_id,
      { self.api:collectionId(LIBRARYTHING.COLLECTION.LIBRARY) })
    if not work_id then
      logger.warn("LibraryThing: Couldn't add the edition from the book source: " .. tostring(err))
      UIManager:show(InfoMessage:new {
        text = _("Couldn't add the book to LibraryThing: ") .. tostring(err),
        icon = "notice-warning",
      })
      return false
    end
    book.book_id = work_id
  end

  -- What the user's copy is looked up by in their catalog.
  local author = book.contributions and book.contributions[1] and book.contributions[1].author
  self.api:rememberWork(book.book_id, {
    title = book.title,
    author = author and author.name or nil,
  })

  local status, lookup_error = self.api:findUserBook(book.book_id)
  status = status or {}
  book.pages = tonumber(book.pages) or status.page_count
  book.title = book.title or status.title

  local delete = self:_deletedKeys(book, { "book_id", "edition_id", "pages", "title" })
  self.settings:updateBookSetting(filename, {
    book_id = tostring(book.book_id),
    pages = book.pages,
    title = book.title,
    link_method = link_method,
    _delete = delete,
  })
  self.state.book_status = status

  -- Only a lookup that loaded can show the book has no status. Adding it to
  -- Currently reading only adds a collection, so a book that's in the library
  -- without a status (e.g. just "Your library") gets it too.
  if lookup_error then
    logger.warn("LibraryThing: Couldn't check the book's status, not adding it to Currently reading: " .. tostring(lookup_error))
    UIManager:show(InfoMessage:new {
      text = _("Linked, but couldn't check the book's status on LibraryThing, so it wasn't added to Currently reading automatically. Use \"Update status\" to set it manually.")
        .. "\n\n" .. tostring(lookup_error),
      icon = "notice-warning",
    })
  elseif not status.status_id then
    logger.info("LibraryThing: Book has no status, adding it to Currently reading")
    local added, err = self.api:updateUserBook(book.book_id, LIBRARYTHING.STATUS.READING)
    if added and added.status_id then
      self.state.book_status = added
    else
      logger.warn("LibraryThing: Failed to add book to Currently reading: " .. tostring(err))
      self.state.book_status = added or status
      UIManager:show(InfoMessage:new {
        text = _("Linked, but couldn't add the book to Currently reading on LibraryThing. Use \"Update status\" to set it manually."),
        icon = "notice-warning",
      })
    end
  end

  return true
end

local function reachedEnd(self, value, update_type, filename)
  if update_type == "pages" then
    local pages = tonumber(self.settings:pages(filename))
    return pages ~= nil and pages > 0 and value >= pages
  end
  return value >= 100
end

-- Only the end of the book is sent (see pushProgress), so nothing else turns
-- Wi-Fi on or is queued while reading.
function LibraryThing:sendsProgress(value, update_type, filename)
  return reachedEnd(self, value, update_type, filename)
end

function LibraryThing:getRemoteProgress(_status, _update_type)
  return 0
end

function LibraryThing:getRemotePercent(_status)
  return nil
end

-- Only reaching the end matters: it marks a book being read as Read,
-- finished today. Otherwise there's nothing to send, and the status is
-- returned as it was.
function LibraryThing:pushProgress(_current_read, value, update_type, filename, status)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    return nil, "No linked book found on LibraryThing"
  end

  status = status or self.state.book_status or {}
  if not reachedEnd(self, value, update_type, filename) or status.status_id ~= LIBRARYTHING.STATUS.READING then
    return status
  end

  local result, err = self.api:updateUserBook(book_id, LIBRARYTHING.STATUS.FINISHED)
  if not result then
    return nil, err
  end
  self:onMarkedFinished(book_id, filename)
  return result
end

-- updateUserBook dates a finished read today; one finished earlier (queued
-- while offline) is dated when it was.
function LibraryThing:onMarkedFinished(book_id, filename, finished_at)
  self:notifyBookFinished(filename)
  if finished_at and os.date("%Y-%m-%d", finished_at) ~= os.date("%Y-%m-%d") then
    return self:setDateFinished(book_id, finished_at)
  end
  return true
end

function LibraryThing:setDateFinished(book_id, finished_at)
  return self.api:setDateFinished(book_id, finished_at)
end

-- LibraryThing rates in half stars; the composer's quarter stars are
-- rounded down. The review text is saved with the rating, as the site's
-- review form does.
function LibraryThing:submitReview(filename, rating, text)
  local book_id = self.settings:readBookSetting(filename, "book_id")
  if not book_id then
    return false, "No linked book found on LibraryThing"
  end

  local status, err = self.api:findUserBook(book_id)
  if not status then
    return false, err
  end
  if not status.id then
    return false, "The book isn't in your LibraryThing library"
  end

  local half_stars = rating and rating > 0 and math.floor(rating * 2) or nil
  local ok
  if text and text:match("%S") then
    ok, err = self.api:setReview(status, text, half_stars)
  elseif half_stars then
    ok, err = self.api:setRating(status.id, half_stars)
  else
    return false, "No rating or review text supplied"
  end
  return ok == true, err
end

return LibraryThing
