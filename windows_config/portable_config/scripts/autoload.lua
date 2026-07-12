-- autoload.lua (MPV 0.37+ compatible, symlink-safe)

local mp       = require 'mp'
local msg      = require 'mp.msg'
local utils    = require 'mp.utils'
local opt      = require 'mp.options'

local o = {
    disabled      = false,
    images        = true,
    videos        = true,
    audio         = true,
    ignore_hidden = true,
    max_entries   = 5000,
    tv_regex      = [[[Ss]\d+[Ee]\d+]],
    tv_filter     = false
}
opt.read_options(o, "autoload")

if o.disabled then
    msg.verbose("autoload: disabled via options")
    return
end

local EXT = {}
if o.videos then for _,v in ipairs({"mkv","avi","mp4","webm","flv","wmv","mpeg","mpg","m4v","3gp","mov"}) do EXT[v] = true end end
if o.audio  then for _,v in ipairs({"mp3","flac","wav","ogg","opus"}) do EXT[v] = true end end
if o.images then for _,v in ipairs({"jpg","jpeg","png","gif","webp","tiff","bmp"}) do EXT[v] = true end end

local function alnum_less(a, b)
    local function pad_nums(s) return s:lower():gsub("%d+", function(d) return ("%012d"):format(d) end) end
    return pad_nums(a) < pad_nums(b)
end

local function abspath(p)
    if not p:match("^/") then
        return utils.join_path(utils.getcwd(), p)
    end
    return p
end

local function autoload()
    local path = mp.get_property_native("path")
    local dir, fname = utils.split_path(path)
    if dir == "" or not fname then
        msg.verbose("autoload: non-local file or invalid path")
        return
    end

    if o.tv_filter and not fname:match(o.tv_regex) then
        msg.verbose("autoload: filename does not match TV-show pattern, skipping")
        return
    end

    if mp.get_property_number("playlist-count", 1) > 1 then
        msg.verbose("autoload: existing playlist detected, skipping")
        return
    end

    local files = utils.readdir(dir, "files")
    if not files then
        msg.verbose("autoload: no files in directory")
        return
    end

    local list = {}
    for _,f in ipairs(files) do
        if o.ignore_hidden and f:sub(1,1) == "." then
        else
            local ext = f:match("%.([^.]+)$")
            if ext and EXT[ext:lower()] then
                table.insert(list, f)
            end
        end
    end

    table.sort(list, alnum_less)

    local path_abs = abspath(path)
    local idx
    for i,f in ipairs(list) do
        local abs = abspath(utils.join_path(dir, f))
        if abs == path_abs then
            idx = i
            break
        end
    end

    if not idx then
        msg.verbose("autoload: current file not found in directory list")
        return
    end

    local pre, post = {}, {}
    for i = 1, o.max_entries do
        local prev = list[idx - i]
        local next = list[idx + i]
        if prev then table.insert(pre, 1, utils.join_path(dir, prev)) end
        if next then table.insert(post,     utils.join_path(dir, next)) end
    end

    for _,f in ipairs(pre) do
        mp.commandv("loadfile", f, "append")
        mp.commandv("playlist-move", mp.get_property_number("playlist-count") - 1, 0)
    end

    for _,f in ipairs(post) do
        mp.commandv("loadfile", f, "append")
    end

    msg.verbose(("autoload: inserted %d before and %d after"):format(#pre, #post))
end

mp.register_event("file-loaded", autoload)

















-- -- This script automatically loads playlist entries before and after the
-- -- the currently played file. It does so by scanning the directory a file is
-- -- located in when starting playback. It sorts the directory entries
-- -- alphabetically, and adds entries before and after the current file to
-- -- the internal playlist. (It stops if it would add an already existing
-- -- playlist entry at the same position - this makes it "stable".)
-- -- Add at most 5000 * 2 files when starting a file (before + after).
-- 
-- --[[
-- To configure this script use file autoload.conf in directory script-opts (the "script-opts"
-- directory must be in the mpv configuration directory, typically ~/.config/mpv/).
-- 
-- Example configuration would be:
-- 
-- disabled=no
-- images=no
-- videos=yes
-- audio=yes
-- ignore_hidden=yes
-- 
-- --]]
-- 
-- -- Filename TV Show regex check
-- function checkFilenameRegex(filename, regex)
--   if not string.match(filename, regex) and string.match(filename, "%.mkv$") then
--     print("Filename doesn't match the regex for TV Shows")
--     print("Autoload has been disabled.")
--   else
--     -- Continue if regex matches TV Shows
--     print("Filename matches the regex for TV Shows or is not an mkv file")
--     print("Autoload has been enabled.")
--     MAXENTRIES = 5000
-- 
--     local msg = require 'mp.msg'
--     local options = require 'mp.options'
--     local utils = require 'mp.utils'
-- 
--     o = {
--         disabled = false,
--         images = true,
--         videos = true,
--         audio = true,
--         ignore_hidden = true
--     }
--     options.read_options(o)
-- 
--     function Set (t)
--         local set = {}
--         for _, v in pairs(t) do set[v] = true end
--         return set
--     end
-- 
--     function SetUnion (a,b)
--         local res = {}
--         for k in pairs(a) do res[k] = true end
--         for k in pairs(b) do res[k] = true end
--         return res
--     end
-- 
--     EXTENSIONS_VIDEO = Set {
--         'dts', 'mkv', 'avi', 'mp4', 'ogv', 'webm', 'rmvb', 'flv', 'wmv', 'mpeg', 'mpg', 'm4v', '3gp'
--     }
-- 
--     EXTENSIONS_AUDIO = Set {
--         'dts', 'mp3', 'wav', 'ogm', 'flac', 'm4a', 'wma', 'ogg', 'opus'
--     }
-- 
--     EXTENSIONS_IMAGES = Set {
--         'jpg', 'jpeg', 'png', 'tif', 'tiff', 'gif', 'webp', 'svg', 'bmp'
--     }
-- 
--     EXTENSIONS = Set {}
--     if o.videos then EXTENSIONS = SetUnion(EXTENSIONS, EXTENSIONS_VIDEO) end
--     if o.audio then EXTENSIONS = SetUnion(EXTENSIONS, EXTENSIONS_AUDIO) end
--     if o.images then EXTENSIONS = SetUnion(EXTENSIONS, EXTENSIONS_IMAGES) end
-- 
--     function add_files_at(index, files)
--         index = index - 1
--         local oldcount = mp.get_property_number("playlist-count", 1)
--         for i = 1, #files do
--             mp.commandv("loadfile", files[i], "append")
--             mp.commandv("playlist-move", oldcount + i - 1, index + i - 1)
--         end
--     end
-- 
--     function get_extension(path)
--         match = string.match(path, "%.([^%.]+)$" )
--         if match == nil then
--             return "nomatch"
--         else
--             return match
--         end
--     end
-- 
--     table.filter = function(t, iter)
--         for i = #t, 1, -1 do
--             if not iter(t[i]) then
--                 table.remove(t, i)
--             end
--         end
--     end
-- 
--     -- splitbynum and alnumcomp from alphanum.lua (C) Andre Bogus
--     -- Released under the MIT License
--     -- http://www.davekoelle.com/files/alphanum.lua
-- 
--     -- split a string into a table of number and string values
--     function splitbynum(s)
--         local result = {}
--         for x, y in (s or ""):gmatch("(%d*)(%D*)") do
--             if x ~= "" then table.insert(result, tonumber(x)) end
--             if y ~= "" then table.insert(result, y) end
--         end
--         return result
--     end
-- 
--     function clean_key(k)
--         k = (' '..k..' '):gsub("%s+", " "):sub(2, -2):lower()
--         return splitbynum(k)
--     end
-- 
--     -- compare two strings
--     function alnumcomp(x, y)
--         local xt, yt = clean_key(x), clean_key(y)
--         for i = 1, math.min(#xt, #yt) do
--             local xe, ye = xt[i], yt[i]
--             if type(xe) == "string" then ye = tostring(ye)
--             elseif type(ye) == "string" then xe = tostring(xe) end
--             if xe ~= ye then return xe < ye end
--         end
--         return #xt < #yt
--     end
-- 
--     local autoloaded = nil
-- 
--     function find_and_add_entries()
--         local path = mp.get_property("path", "")
--         local dir, filename = utils.split_path(path)
--         msg.trace(("dir: %s, filename: %s"):format(dir, filename))
--         if o.disabled then
--             msg.verbose("stopping: autoload disabled")
--             return
--         elseif #dir == 0 then
--             msg.verbose("stopping: not a local path")
--             return
--         end
-- 
--         local pl_count = mp.get_property_number("playlist-count", 1)
--         -- check if this is a manually made playlist
--         if (pl_count > 1 and autoloaded == nil) or
--            (pl_count == 1 and EXTENSIONS[string.lower(get_extension(filename))] == nil) then
--             msg.verbose("stopping: manually made playlist")
--             return
--         else
--             autoloaded = true
--         end
-- 
--         local pl = mp.get_property_native("playlist", {})
--         local pl_current = mp.get_property_number("playlist-pos-1", 1)
--         msg.trace(("playlist-pos-1: %s, playlist: %s"):format(pl_current,
--             utils.to_string(pl)))
-- 
--         local files = utils.readdir(dir, "files")
--         if files == nil then
--             msg.verbose("no other files in directory")
--             return
--         end
--         table.filter(files, function (v, k)
--             -- The current file could be a hidden file, ignoring it doesn't load other
--             -- files from the current directory.
--             if (o.ignore_hidden and not (v == filename) and string.match(v, "^%.")) then
--                 return false
--             end
--             local ext = get_extension(v)
--             if ext == nil then
--                 return false
--             end
--             return EXTENSIONS[string.lower(ext)]
--         end)
--         table.sort(files, alnumcomp)
-- 
--         if dir == "." then
--             dir = ""
--         end
-- 
--         -- Find the current pl entry (dir+"/"+filename) in the sorted dir list
--         local current
--         for i = 1, #files do
--             if files[i] == filename then
--                 current = i
--                 break
--             end
--         end
--         if current == nil then
--             return
--         end
--         msg.trace("current file position in files: "..current)
-- 
--         local append = {[-1] = {}, [1] = {}}
--         for direction = -1, 1, 2 do -- 2 iterations, with direction = -1 and +1
--             for i = 1, MAXENTRIES do
--                 local file = files[current + i * direction]
--                 local pl_e = pl[pl_current + i * direction]
--                 if file == nil or file[1] == "." then
--                     break
--                 end
-- 
--                 local filepath = dir .. file
--                 if pl_e then
--                     -- If there's a playlist entry, and it's the same file, stop.
--                     msg.trace(pl_e.filename.." == "..filepath.." ?")
--                     if pl_e.filename == filepath then
--                         break
--                     end
--                 end
-- 
--                 if direction == -1 then
--                     if pl_current == 1 then -- never add additional entries in the middle
--                         msg.info("Prepending " .. file)
--                         table.insert(append[-1], 1, filepath)
--                     end
--                 else
--                     msg.info("Adding " .. file)
--                     table.insert(append[1], filepath)
--                 end
--             end
--         end
-- 
--         add_files_at(pl_current + 1, append[1])
--         add_files_at(pl_current, append[-1])
--     end
-- 
--     mp.register_event("start-file", find_and_add_entries)
-- 
--   end
-- end
-- 
-- -- Main entry point
-- function main()
--   local filename = mp.get_property("filename")
--   local regex = 'S[0-9]*E[0-9]' -- PCRE pattern
--   checkFilenameRegex(filename, regex)
-- end
-- 
-- -- Register main function to the start-file hook
-- mp.register_event("start-file", main)