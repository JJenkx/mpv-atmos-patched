local function reset_position()
    local duration = mp.get_property_number("duration")
    local position = mp.get_property_number("time-pos")
    if duration and position and position >= duration * 0.95 then
        mp.set_property_number("time-pos", 0)
    end
end

mp.register_event("file-loaded", reset_position)

--function on_file_loaded()
--
--    -- Get the filepath of the currently playing file
--    local filepath = mp.get_property("path")
--
--    -- Get the filename of the currently playing file
--    local filename = mp.get_property("filename")
--    
--    -- Get the current playback position
--    local pos = mp.get_property("time-pos")
--
--    -- Set up a hook to wait for the "duration" property to become available
--    local function on_duration_available()
--        -- Get the total length of the currently playing file
--        local duration = mp.get_property_number("duration")
----        print("Video duration: " .. duration)
--
--        -- Convert duration to a string
--        duration = tostring(duration)
--
--        -- Execute the script, passing the filename, playback position, and total length as arguments
--        mp.command_native({"run", "bash", "/path/to/bash.script.sh", filepath, pos, duration})
--
--        -- Unregister the hook
--        mp.unregister_event(on_duration_available)
--    end
--    mp.add_timeout(0.1, on_duration_available)
--end
--
--mp.register_event("file-loaded", on_file_loaded)
--