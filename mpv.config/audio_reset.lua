local mp = require 'mp'

mp.register_event("file-loaded", function()
    mp.add_timeout(0.3, function()
        local fmt = mp.get_property("audio-out-params/format") or ""
        local s = fmt:lower()
        if s:find("spdif", 1, true) or s:find("iec958", 1, true) then
            -- Remember the configured device so the cycle restores it
            -- instead of landing on the ALSA default (DAC/desk speakers).
            local dev = mp.get_property("audio-device")
            mp.commandv("audio-reload")
            mp.set_property("audio-device", "no")
            mp.add_timeout(0.1, function()
                mp.set_property("audio-device", dev)
                mp.add_timeout(0.1, function()
                    -- Kick mpv out of any frozen state left by the device
                    -- cycle. This mirrors the manual seek the user would
                    -- otherwise need to do on watch-later resumes.
                    mp.commandv("seek", 0, "relative+exact")
                end)
            end)
        end
    end)
end)
