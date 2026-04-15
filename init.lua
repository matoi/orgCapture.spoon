local log = hs.logger.new('orgCapture', 'debug')

local obj = {}

obj.__index = obj

-- metadata
obj.name = "orgCapture"
obj.version = "0.2"
obj.author = "Noriaki Matoi"
obj.homepage = ""
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- The name of the Emacs application.
obj.emacsAppName = "Emacs"

--- Path to emacsclient binary.
obj.emacsClientPath = "/opt/homebrew/bin/emacsclient"

--- Delay after Cmd-C before reading the clipboard (microseconds).
obj.clipboardDelayMicros = 500000

--- Enable verbose logging for troubleshooting.
obj.debugLogging = true

require("hs.ipc")

if not hs.ipc.cliStatus() then
   hs.alert("hs CLI not found. Installing...")
   hs.ipc.cliInstall()
   if not hs.ipc.cliStatus() then
      hs.alert("Unable to install ipc module. orgCapture will not function.")
      print("\norgCapture: unable to install ipc module.",
            "Make sure you can execute hs from command line.",
            "See documentation of hs.ipc\n")
      return obj
   end
end

function obj:log(message)
   if self.debugLogging then
      print("orgCapture: " .. message)
   end
end

-- Safe accessors --------------------------------------------------------

local function safeAppName(app)
   if not app then return nil end
   local ok, name = pcall(function() return app:name() end)
   if ok and name and name ~= "" then return name end
   ok, name = pcall(function() return app:title() end)
   if ok and name and name ~= "" then return name end
   return nil
end

local function safeWindowTitle(window)
   if not window then return "" end
   local ok, title = pcall(function() return window:title() end)
   if ok and title then return title end
   return ""
end

-- URI providers ---------------------------------------------------------

-- Browsers with native AppleScript URL access
local browserScripts = {
   Safari       = 'tell application "Safari" to return URL of current tab of front window',
   ["Google Chrome"] = 'tell application "Google Chrome" to return URL of active tab of front window',
   Arc          = 'tell application "Arc" to return URL of active tab of front window',
   ["Brave Browser"] = 'tell application "Brave Browser" to return URL of active tab of front window',
}

-- Browsers that lack AppleScript URL support.
-- URL is grabbed via Cmd-L, Cmd-A, Cmd-C from the address bar.
local keystrokeBrowsers = {
   firefox = true,
   Zen     = true,
}

local function getBrowserURL(appName)
   local script = browserScripts[appName]
   if script then
      local ok, result = hs.osascript.applescript(script)
      if ok and result then return result end
      return nil
   end
   return nil
end

local function getURLViaKeystroke(clipDelay)
   local saved = hs.pasteboard.getContents()
   hs.eventtap.keyStroke({"cmd"}, "l")
   hs.timer.usleep(100000)
   hs.eventtap.keyStroke({"cmd"}, "a")
   hs.timer.usleep(50000)
   hs.eventtap.keyStroke({"cmd"}, "c")
   hs.timer.usleep(clipDelay)
   local url = hs.pasteboard.getContents()
   -- Restore clipboard
   if saved then
      hs.pasteboard.setContents(saved)
   else
      hs.pasteboard.clearContents()
   end
   -- Press Escape to deselect the address bar
   hs.eventtap.keyStroke({}, "escape")
   if url and url ~= saved and url:match("^https?://") then
      return url
   end
   return nil
end

local function getFinderPath()
   local ok, result = hs.osascript.applescript([[
      tell application "Finder"
         set sel to selection
         if (count of sel) > 0 then
            return POSIX path of (item 1 of sel as alias)
         else
            return POSIX path of (target of front window as alias)
         end if
      end tell
   ]])
   if ok and result then return result end
   return nil
end

function obj:getURI(appName)
   if appName == "Finder" then
      local path = getFinderPath()
      if path then return "file://" .. path end
      return nil
   end
   if keystrokeBrowsers[appName] then
      return getURLViaKeystroke(self.clipboardDelayMicros)
   end
   return getBrowserURL(appName)
end

-- Clipboard -------------------------------------------------------------

function obj:performCopyAndCheck()
   local originalContent = hs.pasteboard.getContents()
   hs.eventtap.keyStroke({"cmd"}, "c")
   hs.timer.usleep(self.clipboardDelayMicros)
   local newContent = hs.pasteboard.getContents()
   return newContent ~= originalContent
end

-- Elisp argument formatting ---------------------------------------------
-- These produce Emacs Lisp literals.  The elisp sexp is passed to
-- emacsclient via hs.task.new() which bypasses the shell entirely,
-- so only Emacs reader escaping is needed (backslash and double-quote).

local function formatElispString(str)
   if not str then return "nil" end
   local escaped = str
   escaped = string.gsub(escaped, "\\", "\\\\")
   escaped = string.gsub(escaped, '"', '\\"')
   return '"' .. escaped .. '"'
end

local function formatElispBool(val)
   return val and "t" or "nil"
end

-- Begin capture ---------------------------------------------------------

function obj:beginOrgCapture()
   local w = hs.window.focusedWindow()
   if not w then
      self:log("no focused window")
      hs.alert("No focused window found")
      return
   end

   local app = w:application()
   local appName = safeAppName(app) or "Unknown"

   if appName == self.emacsAppName then
      self:log("already in Emacs, ignoring")
      hs.alert("Already in " .. self.emacsAppName .. ". Ignoring request")
      return
   end

   local emacs = hs.application.find(self.emacsAppName)
   if not emacs then
      self:log("Emacs not found")
      hs.alert("No " .. self.emacsAppName .. " found. Ignoring request")
      return
   end

   local bundleId = app:bundleID() or ""
   local windowId = w:id() or 0
   local windowTitle = safeWindowTitle(w)

   -- URI (best-effort; failure is not fatal)
   local uri = self:getURI(appName)
   self:log("URI: " .. (uri or "nil"))

   -- Clipboard copy (best-effort)
   local useClipboard = self:performCopyAndCheck()
   self:log("clipboard copied: " .. tostring(useClipboard))

   -- Build elisp sexp
   local elisp = string.format("(org-capture-hs-begin %s %s %d %s %s %s)",
      formatElispString(appName),
      formatElispString(bundleId),
      windowId,
      formatElispString(windowTitle),
      formatElispString(uri),
      formatElispBool(useClipboard))

   self:log("elisp: " .. elisp)

   -- Use hs.task.new() to call emacsclient directly, bypassing the
   -- shell entirely.  This eliminates shell injection risks from
   -- user-controlled strings (window titles, URIs, app names).
   local task = hs.task.new(self.emacsClientPath,
      function(exitCode, stdOut, stdErr)
         if exitCode ~= 0 then
            self:log("emacsclient failed: rc=" .. tostring(exitCode)
                     .. " stderr=" .. (stdErr or ""))
            hs.alert("Failed to start org-capture in Emacs")
         end
      end,
      {"-e", elisp, "-n"})

   emacs:activate()
   if not task:start() then
      self:log("failed to launch emacsclient task")
      hs.alert("Failed to start emacsclient")
   end
end

-- Return to source window/app ------------------------------------------

function obj:returnToSource(windowId, bundleId, appName)
   self:log(string.format("returnToSource: windowId=%s bundleId=%s appName=%s",
      tostring(windowId), tostring(bundleId), tostring(appName)))

   if windowId and windowId > 0 then
      local w = hs.window.get(windowId)
      if w then
         w:focus()
         self:log("focused window by id")
         return
      end
   end

   if bundleId and bundleId ~= "" then
      local app = hs.application.get(bundleId)
      if app then
         app:activate()
         self:log("activated app by bundle-id")
         return
      end
   end

   if appName and appName ~= "" then
      local app = hs.application.find(appName)
      if app then
         app:activate()
         self:log("activated app by name")
         return
      end
   end

   self:log("could not return to source")
   hs.alert("Could not return to source application")
end

function obj:finalizeOrgCapture(windowId, bundleId, appName)
   self:log("finalize")
   self:returnToSource(windowId, bundleId, appName)
end

function obj:cancelOrgCapture(windowId, bundleId, appName)
   self:log("cancel")
   self:returnToSource(windowId, bundleId, appName)
end

-- Hotkey binding --------------------------------------------------------

obj.functionMap = nil
obj._functionDef = nil

function obj:bindHotkeys(mapping)
   local def = {
      org_capture = function() self:beginOrgCapture() end
   }
   hs.spoons.bindHotkeysToSpec(def, mapping)
   self.functionMap = mapping
   self._functionDef = def
end

function obj:unbindHotkeys()
   if not self._functionDef then return end
   local spoonpath = hs.spoons.scriptPath(3)
   for name, _ in pairs(self._functionDef) do
      local keypath = spoonpath .. name
      if hs.spoons._keys[keypath] then
         hs.spoons._keys[keypath]:delete()
         hs.spoons._keys[keypath] = nil
      end
   end
end

-- Disable hotkeys while Emacs is in front
local appWatcher = hs.application.watcher.new(function(_, event, app)
   if app:bundleID() == 'org.gnu.Emacs' then
      if event == hs.application.watcher.activated then
         obj:unbindHotkeys()
      elseif event == hs.application.watcher.deactivated and obj.functionMap then
         obj:bindHotkeys(obj.functionMap)
      end
   end
end)
appWatcher:start()

print("Finished loading orgCapture.spoon")

return obj
