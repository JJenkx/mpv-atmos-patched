-- audio_underrun_watchdog.lua
--
-- With SPDIF/HDMI passthrough (TrueHD MAT in particular), mpv's
-- restart-after-underrun path can wedge permanently: the audio chain
-- produces below realtime forever, video crawls at ~1fps synced to the
-- broken audio clock, and the HDMI sink never re-locks. Reinitializing the
-- audio decoder chain (cycling aid) fully recovers it.
--
-- This watchdog detects the wedge (repeated "Audio device underrun"
-- warnings while a spdif format is active) and performs that reinit
-- automatically, at most once per cooldown period.

local COUNT_THRESHOLD = 2   -- underruns ...
local WINDOW_SECS     = 60  -- ... within this many seconds triggers reinit
local COOLDOWN_SECS   = 30  -- min time between automatic reinits

local count = 0
local first_ts = nil
local last_fix = -math.huge

mp.enable_messages("warn")

mp.register_event("log-message", function(e)
    if e.prefix ~= "cplayer" then return end
    if not e.text or not e.text:find("underrun") then return end

    -- Only act on passthrough; PCM output recovers from underruns on its own.
    local fmt = mp.get_property("audio-params/format") or ""
    if not fmt:find("spdif") then return end

    local now = mp.get_time()
    if not first_ts or now - first_ts > WINDOW_SECS then
        first_ts = now
        count = 0
    end
    count = count + 1

    if count >= COUNT_THRESHOLD and now - last_fix > COOLDOWN_SECS then
        last_fix = now
        count = 0
        first_ts = nil
        local aid = mp.get_property_native("aid")
        if aid and aid ~= false then
            mp.msg.warn("repeated passthrough underruns; reinitializing audio chain")
            mp.osd_message("Audio: recovering passthrough stream ...", 2)
            mp.set_property_native("aid", false)
            mp.add_timeout(0.5, function()
                mp.set_property_native("aid", aid)
            end)
        end
    end
end)
