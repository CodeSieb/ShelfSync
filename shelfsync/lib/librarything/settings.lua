local BaseSettings = require("shelfsync/lib/common/base_settings")

local LibraryThingSettings = setmetatable({}, { __index = BaseSettings })
LibraryThingSettings.__index = LibraryThingSettings

function LibraryThingSettings:new(path, ui, shared)
  return BaseSettings.new(self, path, ui, "librarything", shared)
end

-- A book is linked to a LibraryThing work, not an edition (the copy in the
-- user's library is looked up from the work), so book_id doubles as
-- edition_id, as for Goodreads and Fable.
function LibraryThingSettings:getLinkedBookId()
  return self:readBookSetting(self:getFilePath(), "book_id")
end

function LibraryThingSettings:getLinkedEditionId()
  return self:getLinkedBookId()
end

return LibraryThingSettings
