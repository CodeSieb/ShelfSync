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
  -- Book sources offered for books that aren't on LibraryThing yet (its
  -- "Add books" search), by LibraryThing's source id. Amazon.com is the
  -- site's own default; the rest are national and union catalogues.
  ADD_SOURCES = {
    { id = 1197, name = "Amazon.com books" },
    { id = 1187, name = "Amazon UK books" },
    { id = 1, name = "Library of Congress" },
    { id = 1161, name = "Overcat" },
    { id = 1065, name = "Vlaamse Centrale Catalogus" },
    { id = 753, name = "LIBIS-Net (Belgium)" },
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
  -- The three LibraryThing session cookies accepted by Android sign-in and
  -- by the website's account requests.
  SESSION_COOKIES = { "cookie_userid", "cookie_usernum", "cookie_userchecksum" },
}

return LibraryThing
