local _ = require("gettext")

local T = require("ffi/util").template

local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

local InfoMessage = require("ui/widget/infomessage")

local _t = require("shelfsync/lib/common/table_util")

local LIBRARYTHING = require("shelfsync/lib/librarything/constants")
local ICON = require("shelfsync/lib/common/constants/icons")
local SETTING = require("shelfsync/lib/common/constants/settings")

local LibraryThingMenu = {}
LibraryThingMenu.__index = LibraryThingMenu

function LibraryThingMenu:new(o)
  return setmetatable(o or {
    enabled = true
  }, self)
end

function LibraryThingMenu:isActive()
  return self.settings:providerEnabled()
    and self.api:hasCredential()
    and (self.enabled or self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) == true)
end

function LibraryThingMenu:trackingDisabledReason()
  if not self.settings:providerEnabled() then
    return _("enable LibraryThing first")
  end
  if not self.api:hasCredential() then
    return _("log in first")
  end
  if not self.enabled and self.settings:readSetting(SETTING.IGNORE_VERSION_BLOCK) ~= true then
    return _("update ShelfSync to continue")
  end
  if not self.settings:bookLinked() then
    return _("link this book first")
  end
  return nil
end

function LibraryThingMenu:mainMenu()
  return {
    enabled_func = function()
      return true
    end,
    text_func = function()
      return self.settings:bookLinked() and _("LibraryThing: " .. ICON.LINK) or _("LibraryThing")
    end,
    sub_item_table_func = function()
      local has_book = self.ui.document and true or false
      return self:getSubMenuItems(has_book)
    end,
  }
end

function LibraryThingMenu:getSubMenuItems(book_view)
  local menu_items = {
    {
      text = _("Enabled"),
      checked_func = function()
        return self.settings:providerEnabled()
      end,
      callback = function()
        self.settings:setProviderEnabled(not self.settings:providerEnabled())
      end,
      separator = true,
    },
    book_view and {
      text_func = function()
        if self.settings:bookLinked() then
          return self.librarything:getLinkedBookLabel()
        else
          return _("Link book")
        end
      end,
      enabled_func = function()
        return self:isActive()
      end,
      hold_callback = function(menu_instance)
        if self.settings:bookLinked() then
          self.settings:updateBookSetting(
            self.ui.document.file,
            {
              _delete = { 'book_id', 'pages', 'title', 'link_method' }
            }
          )

          menu_instance:updateItems()
        end
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        if not self:isActive() then
          return
        end

        local force_search = self.settings:bookLinked()

        self.librarything:showLinkBookDialog(force_search, function()
          menu_instance:updateItems()
        end)
      end,
      separator = true
    },
    -- LibraryThing keeps no reading progress, so "tracking" here syncs the
    -- book's status: Read (with the date) once it's finished.
    book_view and {
      text_func = function()
        local reason = self:trackingDisabledReason()
        if reason then
          return T(_("Automatically sync status (%1)"), reason)
        end
        return _("Automatically sync status")
      end,
      help_text = _("Marks the book as Read on LibraryThing when you finish it in KOReader: sets today's finished date and moves it to the collection chosen under \"Read books go to\". LibraryThing doesn't track reading progress, so nothing is sent while reading."),
      checked_func = function()
        return self.settings:syncEnabled()
      end,
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      callback = function()
        local sync = not self.settings:syncEnabled()
        self.settings:setSync(sync)
      end,
    },
    book_view and {
      text = _("Update status"),
      enabled_func = function()
        return self:isActive() and self.settings:bookLinked()
      end,
      sub_item_table_func = function()
        self.cache:cacheUserBook()

        return self:getStatusSubMenuItems()
      end,
      separator = true
    },
    {
      text_func = function()
        return T(_("Read books go to: %1"), self.api:readCollection().name)
      end,
      help_text = _("The LibraryThing collection a book is put in when it's marked as Read, after which it's taken out of Currently reading and To read."),
      sub_item_table_func = function()
        return self:getReadCollectionItems()
      end,
    },
    {
      text = _("Account"),
      sub_item_table_func = function()
        return self:getAuthSubMenuItems()
      end,
    },
  }
  return _t.filter(menu_items, function(v)
    return v
  end)
end

-- A radio item marking the current book with `status_id` (after
-- confirmation). LibraryThing has no Paused or Did Not Finish.
function LibraryThingMenu:_statusMenuItem(icon, status_id)
  return {
    text = _(icon .. " " .. LIBRARYTHING.STATUS_NAME[status_id]),
    checked_func = function()
      return self.state.book_status.status_id == status_id
    end,
    callback = function(menu_instance)
      -- Only refreshed if it's still showing once the change is done.
      local item_table = menu_instance.item_table
      self.dialog_manager:maybeConfirm({
        text = ("Mark book as %s?"):format(LIBRARYTHING.STATUS_NAME[status_id]),
        ok_callback = function()
          self.cache:queueBookStatus(self.ui.document.file, status_id, function(saved)
            if not saved then
              self.dialog_manager:showError("Book status could not be updated")
            end
            if menu_instance.item_table == item_table then
              menu_instance.item_table = self:getStatusSubMenuItems()
              menu_instance:updateItems()
            end
          end)
        end,
        no_confirm_callback = function()
          menu_instance:updateItems()
        end
      })
    end,
    radio = true
  }
end

function LibraryThingMenu:getStatusSubMenuItems()
  return {
    self:_statusMenuItem(ICON.BOOKMARK, LIBRARYTHING.STATUS.TO_READ),
    self:_statusMenuItem(ICON.OPEN_BOOK, LIBRARYTHING.STATUS.READING),
    self:_statusMenuItem(ICON.CHECKMARK, LIBRARYTHING.STATUS.FINISHED),
    {
      text = _(ICON.TRASH .. " Remove"),
      help_text = _("Takes the book out of Currently reading and To read. It stays in your library, with its reading dates."),
      enabled_func = function()
        return self:isActive() and self.state.book_status.status_id ~= nil
      end,
      callback = function(menu_instance)
        -- Only refreshed if it's still showing once the change is done.
        local item_table = menu_instance.item_table
        self.dialog_manager:maybeConfirm({
          text = "Remove current book status?",
          ok_callback = function()
            self.cache:queueBookRemoval(self.ui.document.file, function(removed)
              if not removed then
                self.dialog_manager:showError("Book status could not be removed")
              elseif menu_instance.item_table == item_table then
                menu_instance.item_table = self:getStatusSubMenuItems()
                menu_instance:updateItems()
              end
            end)
          end
        })
      end,
      keep_menu_open = true,
    },
  }
end

-- The account's collections a read book can go to: any but Currently
-- reading and To read, which are statuses of their own.
function LibraryThingMenu:getReadCollectionItems()
  local reading = self.api:collectionId(LIBRARYTHING.COLLECTION.READING)
  local to_read = self.api:collectionId(LIBRARYTHING.COLLECTION.TO_READ)
  local items = {}
  for _, collection in ipairs(self.api:collections()) do
    if collection.id ~= reading and collection.id ~= to_read then
      table.insert(items, {
        text = collection.name,
        radio = true,
        checked_func = function()
          return self.api:readCollection().id == collection.id
        end,
        callback = function()
          self.api:setReadCollection(collection)
        end,
      })
    end
  end
  if #items > 0 then
    items[#items].separator = true
  end

  table.insert(items, {
    text = _("Refresh the list from LibraryThing"),
    help_text = _("Gets your collections from LibraryThing again, e.g. after adding one there."),
    keep_menu_open = true,
    enabled_func = function()
      return self.api:hasCredential()
    end,
    callback = function(menu_instance)
      -- Only refreshed if it's still showing once the list's back.
      local item_table = menu_instance.item_table
      local info = InfoMessage:new { text = _("Getting your LibraryThing collections...") }
      UIManager:show(info)
      self:_withNetwork(function(wifi_error)
        local collections, err
        if wifi_error then
          err = wifi_error
        else
          collections, err = self.api:refreshCollections()
        end
        UIManager:close(info)
        if not collections then
          UIManager:show(InfoMessage:new {
            text = _("LibraryThing: ") .. tostring(err or _("couldn't get your collections")),
            icon = "notice-warning",
          })
        elseif menu_instance.item_table == item_table then
          menu_instance.item_table = self:getReadCollectionItems()
          menu_instance:updateItems()
        end
      end)
    end,
  })
  return items
end

-- Runs `fn` once there's a network connection, with Wi-Fi turned on first
-- if "Enable wifi on demand" is set, and inside Trapper for the requests.
function LibraryThingMenu:_withNetwork(fn)
  local wifi = self.librarything and self.librarything.wifi
  if wifi then
    wifi:withWifi(function(_wifi_enabled, wifi_error)
      fn(wifi_error)
    end)
  else
    Trapper:wrap(function() fn() end)
  end
end

function LibraryThingMenu:getAuthSubMenuItems()
  return {
    {
      text = _("Sign in with LibraryThing"),
      help_text = _("Sign in with your LibraryThing username and password. ShelfSync caches your password to sign in again if the session expires, encrypted at rest when possible. The unofficial endpoint may change, and the password is sent in an HTTPS URL."),
      keep_menu_open = true,
      callback = function(menu_instance)
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        local dialog
        dialog = MultiInputDialog:new {
          title = _("LibraryThing Sign In"),
          fields = {
            { text = self.api:username() or "", hint = _("Username") },
            { text = "", hint = _("Password"), text_type = "password" },
          },
          buttons = {
            {
              {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
              },
              {
                text = _("Sign in"),
                callback = function()
                  local fields = dialog:getFields()
                  local username, password = fields[1], fields[2]
                  UIManager:close(dialog)

                  Trapper:wrap(function()
                    local info = InfoMessage:new { text = _("Signing in to LibraryThing...") }
                    UIManager:show(info)
                    local ok, err = self.api:login(username, password)
                    UIManager:close(info)
                    if ok then
                      menu_instance:updateItems()
                      UIManager:show(InfoMessage:new { text = _("Signed in to LibraryThing") })
                    else
                      UIManager:show(InfoMessage:new {
                        text = _("LibraryThing sign-in failed: ") .. tostring(err or _("unknown error")),
                        icon = "notice-warning",
                      })
                    end
                  end)
                end,
              },
            },
          },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
      end,
      separator = true,
    },
    {
      text = _("How to sign in"),
      keep_menu_open = true,
      callback = function()
        UIManager:show(InfoMessage:new {
          text = _([[Sign in with your LibraryThing username and password, or use the session cookies from a browser signed in to librarything.com. ShelfSync caches your password to sign in again if the session expires, encrypted at rest when possible. Sign-in sends it in an HTTPS URL. Log out clears the cached password.

Only three cookies are needed: cookie_userid, cookie_usernum and cookie_userchecksum. To copy them from a browser:
- run the fetch-cookies helper from ShelfSync's releases with "--service librarything", and copy the shelfsync_config.lua it writes into the plugin's folder, or
- open the browser's dev tools (F12) > Application/Storage > Cookies > www.librarything.com, and enter the three under "Session cookies" as cookie_userid=...; cookie_usernum=...; cookie_userchecksum=...

The sign-in endpoint is unofficial and may change.

librarything.com is protected by Cloudflare, which can ask a browser to prove it isn't a bot. ShelfSync can't do that, so if Cloudflare challenges it, syncing fails until Cloudflare lets it through again. "Test connection" shows whether that's happening.]]),
        })
      end,
      separator = true,
    },
    {
      text_func = function()
        local username = self.api:hasCredential() and self.api:username()
        return username and T(_("Session cookies (%1)"), username) or _("Session cookies (not set)")
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new {
          title = _("LibraryThing session cookies"),
          input = "",
          input_hint = "cookie_userid=...; cookie_usernum=...; cookie_userchecksum=...",
          description = _("Paste the cookie_userid, cookie_usernum and cookie_userchecksum cookies from a browser signed in to librarything.com. Any other cookies are ignored."),
          buttons = {
            {
              {
                text = _("Cancel"),
                id = "close",
                callback = function()
                  UIManager:close(dialog)
                end,
              },
              {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                  local saved = self.api:saveSessionCookie(dialog:getInputText())
                  UIManager:close(dialog)
                  if saved then
                    menu_instance:updateItems()
                    UIManager:show(InfoMessage:new { text = _("LibraryThing session saved") })
                  else
                    UIManager:show(InfoMessage:new {
                      text = _("Those aren't LibraryThing's session cookies. cookie_userid, cookie_usernum and cookie_userchecksum are all needed."),
                      icon = "notice-warning",
                    })
                  end
                end,
              },
            },
          },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
      end,
    },
    {
      text = _("Test connection"),
      keep_menu_open = true,
      enabled_func = function()
        return self.api:hasCredential()
      end,
      callback = function()
        local info = InfoMessage:new { text = _("Testing LibraryThing connection...") }
        UIManager:show(info)
        self:_withNetwork(function(wifi_error)
          local ok, err
          if wifi_error then
            err = wifi_error
          else
            ok, err = self.api:testConnection()
          end
          UIManager:close(info)
          if ok then
            UIManager:show(InfoMessage:new {
              text = T(_("LibraryThing: connection OK (%1)"), tostring(self.api:username())),
            })
          else
            UIManager:show(InfoMessage:new {
              text = _("LibraryThing: ") .. tostring(err or _("connection failed")),
              icon = "notice-warning",
            })
          end
        end)
      end,
      separator = true,
    },
    {
      text = _("Log out"),
      enabled_func = function()
        return self.api:hasCredential()
      end,
      keep_menu_open = true,
      callback = function(menu_instance)
        self.dialog_manager:maybeConfirm({
          text = _("Log out of LibraryThing on this device?"),
          ok_callback = function()
            self.api:logout()
            menu_instance:updateItems()
            -- The session in shelfsync_config.lua is used whenever none's saved.
            if self.api:hasCredential() then
              UIManager:show(InfoMessage:new {
                text = _("The LibraryThing session in shelfsync_config.lua is still used. Remove it from that file to log out."),
              })
            end
          end,
        })
      end,
    },
  }
end

return LibraryThingMenu
