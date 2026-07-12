-- 00-lock-title.lua — Always show absolute filepath for local (HDD) items
-- Behavior:
--   • If started with --force-media-title=... -> respect it (your app can override deliberately).
--   • Else if the current item is a local file -> force absolute path (like your screenshot).
--   • Else (streams/URLs) -> use playlist title, filename, or media-title as best effort.

local mp = require "mp"

-- Keep honoring explicit CLI titles if you pass them on purpose
local boot_cli_force = mp.get_property("force-media-title") or ""
local honor_cli = (boot_cli_force ~= "")

local last_set, timer = nil, nil

local function is_abs(p)
    return type(p) == "string" and #p > 0 and (p:sub(1,1) == "/")
end

local function has_scheme(p)
    return type(p) == "string" and p:match("^%a[%w+.-]*://") ~= nil
end

-- very small normalizer (handles "//", "/./", and collapses simple "..")
local function normpath(p)
    if not p or p == "" then return p end
    -- collapse // and /./
    p = p:gsub("//+", "/"):gsub("/%./", "/")
    -- resolve a few .. segments conservatively
    local parts, stack = {}, {}
    for seg in p:gmatch("[^/]+") do
        if seg == ".." then
            if #stack > 0 then table.remove(stack) end
        elseif seg ~= "." then
            table.insert(stack, seg)
        end
    end
    return "/" .. table.concat(stack, "/")
end

local function abspath_for_local()
    -- Use the *real* stream-open-filename if available first (often absolute)
    local sof = mp.get_property("stream-open-filename")
    if sof and sof ~= "" then
        if has_scheme(sof) then
            -- file:// URIs -> convert to path-ish quickly
            if sof:sub(1,7) == "file://" then
                local path = sof:gsub("^file://", "")
                return normpath(path)
            else
                return nil -- stream, not local
            end
        else
            -- plain path
            return is_abs(sof) and sof or normpath((mp.get_property("working-directory") or "/") .. "/" .. sof)
        end
    end

    -- Fallback: use path + working-directory
    local path = mp.get_property("path") or ""
    if path == "" then return nil end

    if has_scheme(path) then
        if path:sub(1,7) == "file://" then
            local p = path:gsub("^file://", "")
            return normpath(p)
        else
            return nil -- stream/URL
        end
    end

    if is_abs(path) then
        return normpath(path)
    end

    local wd = mp.get_property("working-directory") or ""
    if wd ~= "" then
        return normpath(wd .. "/" .. path)
    end
    return path
end

local function current_pos()
    return mp.get_property_native("playlist-pos") or mp.get_property_native("playlist-current-pos")
end

local function title_from_playlist()
    local pos = current_pos()
    local pl  = mp.get_property_native("playlist")
    if type(pos) ~= "number" or type(pl) ~= "table" then return nil end
    local e = pl[pos + 1]
    if type(e) ~= "table" then return nil end
    if e.title and e.title ~= "" then return e.title end
    if e.filename and e.filename ~= "" then
        -- If playlist has a local filename and we can resolve abs path, prefer abs
        if not has_scheme(e.filename) and is_abs(e.filename) then return e.filename end
        local wd = mp.get_property("working-directory") or ""
        if wd ~= "" and not has_scheme(e.filename) and not is_abs(e.filename) then
            return normpath(wd .. "/" .. e.filename)
        end
        return e.filename
    end
    return nil
end

local function best_title()
    -- 1) Respect explicit CLI title if provided
    if honor_cli and boot_cli_force ~= "" then
        return boot_cli_force
    end

    -- 2) Local (HDD) files: always show absolute path
    local abs = abspath_for_local()
    if abs and abs ~= "" then
        return abs
    end

    -- 3) Playlist title / filename (streams etc.)
    local tpl = title_from_playlist()
    if tpl and tpl ~= "" then
        return tpl
    end

    -- 4) Fallbacks: media-title or a minimal label
    local mt = mp.get_property("media-title")
    if mt and mt ~= "" and mt ~= "mpv" then return mt end
    return "mpv"
end

local function set_title(reason)
    local want = best_title()
    if want and want ~= last_set then
        mp.set_property("force-media-title", want)
        mp.set_property("file-local-options/force-media-title", want)
        last_set = want
        -- mp.msg.info(("lock-title[%s]: %s"):format(reason or "?", want))
    end
end

local function schedule(reason, delay)
    if timer then timer:kill(); timer = nil end
    timer = mp.add_timeout(delay or 0.06, function()
        timer = nil
        set_title(reason)
    end)
end

-- Lifecycle
mp.register_event("start-file", function()
    last_set = nil
    if not honor_cli then
        mp.set_property("force-media-title", "")
        mp.set_property("file-local-options/force-media-title", "")
    end
    schedule("start-file", 0.04)
end)

mp.register_event("file-loaded", function()
    schedule("file-loaded", 0.06)
end)

mp.register_event("playback-restart", function()
    schedule("playback-restart", 0.06)
end)

-- Properties that can arrive late or change during opens
mp.observe_property("stream-open-filename", "string", function() schedule("sof", 0.05) end)
mp.observe_property("working-directory",   "string", function() schedule("wd",  0.05) end)
mp.observe_property("path",                "string", function() schedule("path",0.05) end)
mp.observe_property("metadata",             "native", function() schedule("meta",0.08) end)

-- Playlist navigation
mp.observe_property("playlist",             "native", function() schedule("playlist", 0.08) end)
mp.observe_property("playlist-pos",         "number", function() schedule("plist-pos",0.06) end)
mp.observe_property("playlist-current-pos", "number", function() schedule("plist-cpos",0.06) end)

mp.register_event("end-file", function()
    if not honor_cli then
        mp.set_property("force-media-title", "")
        mp.set_property("file-local-options/force-media-title", "")
        last_set = nil
    end
end)

-- Safety net for weird late resolutions
local periodic = mp.add_periodic_timer(2.0, function() set_title("periodic") end)
periodic:resume()

-- Initial kick
mp.add_timeout(0.05, function() set_title("init") end)
