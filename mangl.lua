-- mangl
--
-- arc required.
--
-- ----------
--
-- based on the script angl
-- by @tehn and the
-- engine: glut by @artfwo
--
-- ----------
--
-- load samples via param menu
--
-- ----------
--
-- mangl is a 4 track granular
-- sample player.
--
-- arc ring 1 = speed
-- arc ring 2 = pitch
-- arc ring 3 = grain size
-- arc ring 4 = density
--
-- norns key1 = alt
-- norns key2 = enable/disable
--                voice
-- norns key3 = next track
--
-- holding alt and turning a ring,
-- or pressing a button,
-- performs a secondary
-- function.
--
-- alt + ring1 = scrub
-- alt + ring2 = fine tune
-- alt + ring3 = spread
-- alt + ring4 = jitter
--
-- alt + key2 = flip
-- alt + key3 = skip
--
-- ----------
--
-- @justmat v0.1
--

engine.name = 'Glut'

local a = arc.connect(1)

local tau = math.pi * 2
local VOICES = 4
local positions = {-1,-1,-1,-1}
local pages = {"one", "two", "three", "four"}
local page = 1
local alt = false
local scrub_sensitivity = 450


local function scrub(n, d, speed)
  params:set(n .. "speed", 0)
  engine.seek(n, positions[n] + d / scrub_sensitivity)
  params:set(n .. "speed", speed)
end


function init()
  -- polls
  for v = 1, VOICES do
    local phase_poll = poll.set('phase_' .. v, function(pos) positions[v] = pos end)
    phase_poll.time = 0.025
    phase_poll:start()
  end

  params:add_separator()

  local sep = ": "

  params:add_taper("reverb_mix", "*" .. sep .. "mix", 0, 100, 0, 0, "%")
  params:set_action("reverb_mix", function(value) engine.reverb_mix(value / 100) end)

  params:add_taper("reverb_room", "*" .. sep .. "room", 0, 100, 50, 0, "%")
  params:set_action("reverb_room", function(value) engine.reverb_room(value / 100) end)

  params:add_taper("reverb_damp", "*" .. sep .. "damp", 0, 100, 50, 0, "%")
  params:set_action("reverb_damp", function(value) engine.reverb_damp(value / 100) end)

  for v = 1, VOICES do
    params:add_separator()

    params:add_file(v .. "sample", v .. sep .. "sample")
    params:set_action(v .. "sample", function(file) engine.read(v, file) end)

    params:add_option(v .. "play", v .. sep .. "play", {"off","on"}, 1)
    params:set_action(v .. "play", function(x) engine.gate(v, x-1) end)

    params:add_taper(v .. "volume", v .. sep .. "volume", -60, 20, -10, 0, "dB")
    params:set_action(v .. "volume", function(value) engine.volume(v, math.pow(10, value / 20)) end)

    params:add_taper(v .. "speed", v .. sep .. "speed", -200, 200, 0, 0, "%")
    params:set_action(v .. "speed", function(value) engine.speed(v, value / 100) end)

    params:add_taper(v .. "jitter", v .. sep .. "jitter", 0, 500, 0, 5, "ms")
    params:set_action(v .. "jitter", function(value) engine.jitter(v, value / 1000) end)

    params:add_taper(v .. "size", v .. sep .. "size", 1, 500, 100, 5, "ms")
    params:set_action(v .. "size", function(value) engine.size(v, value / 1000) end)

    params:add_taper(v .. "density", v .. sep .. "density", 0, 512, 20, 6, "hz")
    params:set_action(v .. "density", function(value) engine.density(v, value) end)

    params:add_taper(v .. "pitch", v .. sep .. "pitch", -24, 24, 0, 0, "st")
    params:set_action(v .. "pitch", function(value) engine.pitch(v, math.pow(0.5, -value / 12)) end)

    params:add_taper(v .. "spread", v .. sep .. "spread", 0, 100, 0, 0, "%")
    params:set_action(v .. "spread", function(value) engine.spread(v, value / 100) end)

    params:add_taper(v .. "fade", v .. sep .. "att / dec", 1, 9000, 1000, 3, "ms")
    params:set_action(v .. "fade", function(value) engine.envscale(v, value / 1000) end)
  end

  params:read()
  params:bang()

  local arc_redraw_timer = metro.init()
  arc_redraw_timer.time = 0.025
  arc_redraw_timer.event = function() arc_redraw() end
  arc_redraw_timer:start()

  local norns_redraw_timer = metro.init()
  norns_redraw_timer.time = 0.025
  norns_redraw_timer.event = function() redraw() end
  norns_redraw_timer:start()
end


function key(n, z)
  if n == 1 then
    alt = z == 1 and true or false
  end

  if z == 1 then
    if alt then
      if n == 2 then
        -- flip
        local speed = params:get(page .. "speed")
        speed = -speed
        params:set(page .. "speed", speed)
      elseif n == 3 then
        -- skip
        engine.seek(page, 1)
      end
    else
      if n == 2 then
        params:set(page .. "play", params:get(page .. "play") == 2 and 1 or 2)
      elseif n == 3 then
        if params:get((page % VOICES) + 1 .. "sample") == "-" then
          page = 1
        else
          page = (page % VOICES) + 1
        end
      end
    end
  end
end


function a.delta(n, d)
  if alt then
    if n == 1 then
      local speed = params:get(page .. "speed")
      scrub(page, d, speed)
    elseif n == 2 then
      params:delta(page .. "pitch", d / 20)
    elseif n == 3 then
      params:delta(page .. "spread", d / 10)
    elseif n == 4 then
      params:delta(page .. "jitter", d / 10)
    end
  else
    if n == 1 then
      params:delta(page .. "speed", d / 10)
    elseif n == 2 then
      params:delta(page .. "pitch", d / 2)
    elseif n == 3 then
      params:delta(page .. "size", d / 10)
    elseif n == 4 then
      params:delta(page .. "density", d / 10)
    end
  end
end


function arc_redraw()
  a:all(0)
  a:segment(1, positions[page] * tau, tau * positions[page] + 0.2, 15)
  local pitch = params:get(page .. "pitch") / 10
  if pitch > 0 then
    a:segment(2, 0.5, 0.5 + pitch, 15)
  else
    a:segment(2, pitch - 0.5, -0.5, 15)
  end
  if alt == true then
    local spread = params:get(page .. "spread") / 40
    local jitter = params:get(page .. "jitter") / 80
    a:segment(3, 0.5, 0.5 + spread, 15)
    a:segment(4, 0.5, 0.5 + jitter, 15)
  else
    local size = params:get(page .. "size") / 80
    local density = params:get(page .. "density") / 82
    a:segment(3, 0.5, 0.5 + size, 15)
    a:segment(4, 0.5, 0.5 + density, 15)
  end
  a:refresh()
end


function redraw()
  screen.clear()
  screen.move(64,40)
  screen.level(params:get(page .. "play") == 2 and 15 or 4)
  screen.font_face(10)
  screen.font_size(30)
  screen.text_center(pages[page])
  screen.move(20, 60)
  screen.level(15)
  screen.font_size(8)
  screen.font_face(1)
  screen.text_center(string.format("%.2f", params:get(page .. "speed")))
  screen.move(50, 60)
  screen.text_center(string.format("%.2f", params:get(page .. "pitch")))
  screen.move(80, 60)
  if alt then
    screen.text_center(string.format("%.2f", params:get(page .. "spread")))
    screen.move(110, 60)
    screen.text_center(string.format("%.2f", params:get(page .. "jitter")))
  else
    screen.text_center(string.format("%.2f", params:get(page .. "size")))
    screen.move(110, 60)
    screen.text_center(string.format("%.2f", params:get(page .. "density")))
  end
  screen.update()
end
