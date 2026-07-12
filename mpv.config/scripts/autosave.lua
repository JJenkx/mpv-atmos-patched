-- autosave.lua
--
-- Periodically saves "watch later" data during playback, rather than only saving on quit.
-- This lets you easily recover your position in the case of an ungraceful shutdown of mpv (crash, power failure, etc.).
--
-- You can configure the save period by creating a "lua-settings" directory inside your mpv configuration directory.
-- Inside the "lua-settings" directory, create a file named "autosave.conf".
-- The save period can be set like so:
--
-- save_period=60
--
-- This will set the save period to once every 60 seconds of playback, time while paused is not counted towards the save period timer.
-- The default save period is 30 seconds.
--
-- Disable if there are less than x seconds left to end of playback
-- disable_at_lt = 30

local options = require 'mp.options'
local utils   = require 'mp.utils'

local o = {
  save_period   = 10,
  disable_at_lt = 30
}

options.read_options(o)

local mp = require 'mp'

-- Cached values used by the shutdown rescue handler.
-- watch_later_file is pre-computed in init() while subprocesses still work
-- reliably, so shutdown only needs plain Lua I/O.
local cached_pos      = nil
local watch_later_file = nil

local function save()
  mp.command("write-watch-later-config")
end

local function init()
  cached_pos       = nil
  watch_later_file = nil

  local path   = mp.get_property("path")
  local wl_dir = mp.command_native({"expand-path", "~~/watch_later"})

  if path and wl_dir then
    -- Compute the MD5 hash the same way mpv does: hash of the raw path string.
    -- Done here in init() rather than in shutdown(), because spawning a
    -- subprocess during the shutdown event is unreliable in mpv 0.41+.
    local tmpfile = "/tmp/mpv_autosave_" .. math.random(1e6, 9e6)
    local fw = io.open(tmpfile, "wb")
    if fw then
      fw:write(path)
      fw:close()
      local res = mp.command_native({
        args           = {"md5sum", tmpfile},
        capture_stdout = true,
        playback_only  = false,
      })
      os.remove(tmpfile)
      if res and res.stdout then
        local hash = res.stdout:match("^(%x+)")
        if hash then
          watch_later_file = utils.join_path(wl_dir, hash:upper())
        end
      end
    end
  end

  if not mp.get_property_bool("seekable", true) then
    return
  end

  -- mpv reads and deletes the watch-later entry the moment it resumes a file,
  -- expecting to rewrite it on quit. Re-save after a short delay so the entry
  -- is never absent for more than ~0.5s after load.
  mp.add_timeout(0.5, function()
    local pos = mp.get_property_number("time-pos")
    if pos and pos > 1 then
      cached_pos = pos
      save()
    end
  end)

  local save_period_timer = mp.add_periodic_timer(o.save_period, function()
    local duration = mp.get_property_number("duration")
    local time_pos = mp.get_property_number("time-pos")
    if duration and time_pos then
      local time_left = duration - time_pos
      if time_left > o.disable_at_lt then
        cached_pos = time_pos
        save()
      end
    end
  end)

  local function pause(name, paused)
    if paused then
      save_period_timer:stop()
    else
      save_period_timer:resume()
    end
  end

  mp.observe_property("pause", "bool", pause)
end

mp.register_event("file-loaded", init)

-- Capture the final position just before unload (time-pos still valid here).
mp.add_hook("on_unload", 50, function()
  local pos = mp.get_property_number("time-pos")
  if pos and pos > 1 then
    cached_pos = pos
  end
end)

-- mpv's save-position-on-quit deletes the watch-later entry when the position
-- is below its internal near-start threshold. The shutdown event fires AFTER
-- that deletion, so we detect a missing entry and recreate it from cached_pos.
-- We only need plain io.open here — no subprocess — because watch_later_file
-- was already resolved during init().
mp.register_event("shutdown", function()
  if not cached_pos or cached_pos <= 1 then return end
  if not watch_later_file then return end

  -- If mpv already wrote a valid entry, leave it alone.
  local existing = io.open(watch_later_file, "r")
  if existing then
    local content = existing:read("*a")
    existing:close()
    if content and content:find("start=") then return end
  end

  -- Rescue: recreate the entry mpv deleted.
  local out = io.open(watch_later_file, "w")
  if out then
    out:write(string.format("start=%f\n", cached_pos))
    out:close()
  end
end)
