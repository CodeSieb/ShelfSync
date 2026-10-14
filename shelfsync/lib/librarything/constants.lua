local Status = require("shelfsync/lib/common/constants/status")

-- LibraryThing has no reading-status field. A status is which of the
-- default collections a book is in, plus its reading dates (see
-- librarything/api.lua's findUserBook). There's no Paused or Did Not
-- Finish collection, so those statuses are never offered.
local LibraryThing = {
  STATUS = Status.STATUS,
  STATUS_NAME = {
    [Status.STATUS.TO_READ] = "To read",
    [Status.STATUS.READING] = "Currently reading",
    [Status.STATUS.FINISHED] = "Read",
    [Status.STATUS.PAUSED] = "Paused",
    [Status.STATUS.DNF] = "Did Not Finish",
  },
  CATEGORY = Status.CATEGORY,
  ERROR = Status.ERROR,
  BASE_URL = "https://www.librarything.com",
  -- Every account's default collections, matched by name first in case an
  -- older account numbers them differently (see api.lua's collectionIds).
  COLLECTION = {
    LIBRARY = "library",
    TO_READ = "to_read",
    READING = "reading",
    READ_UNOWNED = "read_unowned",
  },
  DEFAULT_COLLECTION_IDS = {
    library = 1,
    to_read = 3,
    read_unowned = 5,
    reading = 7,
  },
  COLLECTION_NAMES = {
    library = "your library",
    to_read = "to read",
    read_unowned = "read but unowned",
    reading = "currently reading",
  },
  -- Every account's default collections, as LibraryThing lists them.
  DEFAULT_COLLECTIONS = {
    { id = 1, name = "Your library" },
    { id = 4, name = "Wishlist" },
    { id = 7, name = "Currently reading" },
    { id = 3, name = "To read" },
    { id = 5, name = "Read but unowned" },
    { id = 6, name = "Favorites" },
  },
  -- LibraryThing's session cookies, the only ones kept from what's pasted
  -- or put in shelfsync_config.lua.
  SESSION_COOKIES = { "cookie_userid", "cookie_usernum", "cookie_userchecksum" },
}

return LibraryThing
