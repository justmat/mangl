-- mangl
--
-- arc suggested.
-- grid capable.
--
-- ----------
--
-- based on the script angl
-- by @tehn and the
-- engine/script glut
-- by @artfwo
--
-- ----------
--
-- load samples via param menu
--
-- ----------
--
-- mangl is a 7 track granular
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
-- norns key3 = set speed to 0
--
-- norns enc1 = volume
-- norns enc3 = nav
--
-- ----------
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
-- alt + key2 = loop in/out
-- alt + key3 = loop clear
--
-- alt + enc1 = filter cutoff
-- alt + enc2 = delay send
--
-- nb: loop in/out is set in
-- one button press. loop in
-- on press, loop out on release.
--
-- ----------
--
-- @justmat v2.2
--
-- llllllll.co/t/21066

engine.name = 'MGlut'

local a = arc.connect(1)
local g = grid.connect(1)
local lfo = include 'lib/hnds_mangl'

local gridbuf = require 'lib/gridbuf'
local grid_ctl = gridbuf.new(16, 8)
local grid_voc = gridbuf.new(16, 8)

local tau = math.pi * 2

local VOICES = 7

local positions = {}
local gates = {}
local voice_levels = {}
local track_speed = {}
local loop_in = {}
local loop_out = {}
local loops = {}
local latched = {}
for i = 1, VOICES do
  positions[i] = -1
  track_speed[i] = 0
  loop_in[i] = nil
  loop_out[i] = nil
  gates[i] = 0
  voice_levels[i] = 0
  loops[i] = {
    state = 0,
    dir = 1
  }
  latched[i] = true
end

local tracks = {"one", "two", "three", "four", "five", "six", "seven"}
local track = 1
local alt = false

local last_enc = 0
local time_last_enc = 0
local time_last_scrub = 0

local was_playing = false

local metro_grid_refresh
local metro_blink

-- arc sensitivity settings

local scrub_sens
local speed_sens
local size_sens
local density_sens
local spread_sens
local jitter_sens

-- for lib/hnds

local lfo_targets = {"none"}
for i = 1, VOICES do
  table.insert(lfo_targets, i .. "position")
  table.insert(lfo_targets, i .. "volume")
  table.insert(lfo_targets, i .. "size")
  table.insert(lfo_targets, i .. "density")
  table.insert(lfo_targets, i .. "spread")
  table.insert(lfo_targets, i .. "jitter")
  table.insert(lfo_targets, i .. "cutoff")
  table.insert(lfo_targets, i .. "send")
end

-- pattern recorder. should likely be swapped out for pattern_time lib

local pattern_banks = {}
local pattern_timers = {}
local pattern_leds = {} -- for displaying button presses
local pattern_positions = {} -- playback positions
local record_bank = -1
local record_prevtime = -1
local record_length = -1
local alt = false
local blink = 0
local metro_blink


local function record_event(x, y, z)
  if record_bank > 0 then
    -- record first event tick
    local current_time = util.time()

    if record_prevtime < 0 then
      record_prevtime = current_time
    end

    local time_delta = current_time - record_prevtime
    table.insert(pattern_banks[record_bank], {time_delta, x, y, z})
    record_prevtime = current_time
  end
end


local function start_playback(n)
  pattern_timers[n]:start(0.001, 1) -- TODO: timer doesn't start immediately with zero
end


local function stop_playback(n)
  pattern_timers[n]:stop()
  pattern_positions[n] = 1
end


local function arm_recording(n)
  record_bank = n
end


local function stop_recording()
  local recorded_events = #pattern_banks[record_bank]

  if recorded_events > 0 then
    -- save last delta to first event
    local current_time = util.time()
    local final_delta = current_time - record_prevtime
    pattern_banks[record_bank][1][1] = final_delta

    start_playback(record_bank)
  end

  record_bank = -1
  record_prevtime = -1
end


local function pattern_next(n)
  local bank = pattern_banks[n]
  local pos = pattern_positions[n]

  local event = bank[pos]
  local delta, x, y, z = table.unpack(event)
  pattern_leds[n] = z
  grid_key(x, y, z, true)

  local next_pos = pos + 1
  if next_pos > #bank then
    next_pos = 1
  end

  local next_event = bank[next_pos]
  local next_delta = next_event[1]
  pattern_positions[n] = next_pos

  -- schedule next event
  pattern_timers[n]:start(next_delta, 1)
end


local function record_handler(n)
  if alt then
    -- clear pattern
    if n == record_bank then stop_recording() end
    if pattern_timers[n].is_running then stop_playback(n) end
    pattern_banks[n] = {}
    do return end
  end

  if n == record_bank then
    -- stop if pressed current recording
    stop_recording()
  else
    local pattern = pattern_banks[n]

    if #pattern > 0 then
      -- toggle playback if there's data
      if pattern_timers[n].is_running then stop_playback(n) else start_playback(n) end
    else
      -- stop recording if it's happening
      if record_bank > 0 then
        stop_recording()
      end
      -- arm new pattern for recording
      arm_recording(n)
    end
  end
end

-- internals

local function get_sample_name()
  -- strips the path and extension from filenames
  -- if filename is over 15 chars, returns a folded filename
  local long_name = string.match(params:get(track .. "sample"), "[^/]*$")
  local short_name = string.match(long_name, "(.+)%..+$")
  if string.len(short_name) >= 15 then
    return string.sub(short_name, 1, 4) .. '...' .. string.sub(short_name, -4)
  else
    return short_name
  end
end


local function display_voice(phase, width)
  local pos = phase * width

  local levels = {}
  for i = 1, width do levels[i] = 0 end

  local left = math.floor(pos)
  local index_left = left + 1
  local dist_left = math.abs(pos - left)

  local right = math.floor(pos + 1)
  local index_right = right + 1
  local dist_right = math.abs(pos - right)

  if index_left < 1 then index_left = width end
  if index_left > width then index_left = 1 end

  if index_right < 1 then index_right = width end
  if index_right > width then index_right = 1 end

  levels[index_left] = math.floor(math.abs(1 - dist_left) * 15)
  levels[index_right] = math.floor(math.abs(1 - dist_right) * 15)

  return levels
end


local function start_voice(voice, pos)
  engine.seek(voice, pos)
  engine.gate(voice, 1)
  gates[voice] = 1
end


local function stop_voice(voice)
  gates[voice] = 0
  engine.gate(voice, 0)
end


local function set_speed(n)
  params:set(n .. "speed", track_speed[n])
end


local function hold_track_speed(n)
  -- remember track speed and direction while scrubbing audio file
  local speed = params:get(n .. "speed")
  if speed ~= 0 then
    track_speed[n] = speed
    if speed < 0 then
      loops[n].dir = -1
    else
      loops[n].dir = 1
    end
  end
end


local function scrub(n, d)
  -- scrub playback position
  hold_track_speed(n)
  params:set(n .. "speed", 0)
  was_playing = true
  engine.seek(n, positions[n] + d / scrub_sens)
end


local function clear_loop(track)
  loop_in[track] = nil
  loop_out[track] = nil
  loops[track].state = 0
end


function loop_pos()
  -- keeps playback inside the loop
  for i = 1, VOICES do
    if loops[i].state == 1 then
      if loops[i].dir == -1 then
        if positions[i] <= loop_in[i] then
          positions[i] = loop_out[i]
          engine.seek(i, loop_out[i])
        end
      else
        if positions[i] >= loop_out[i] then
          positions[i] = loop_in[i]
          engine.seek(i, loop_in[i])
        end
      end
    end
  end
end

-- for hnds

function lfo.process()
  -- for lib hnds
  for i = 1, 4 do
    local target = params:get(i .. "lfo_target")
    local target_name = string.sub(lfo_targets[target], 2)
    local voice = string.sub(lfo_targets[target], 1, 1)
    if params:get(i .. "lfo") == 2 then
      -- volume
      if target_name == "volume" then
        params:set(lfo_targets[target], lfo.scale(lfo[i].slope, -1.0, 2.0, -60, 20))
      -- size
      elseif target_name == "size" then
        params:set(lfo_targets[target], lfo.scale(lfo[i].slope, -1.0, 2.0, 1, 500))
      -- density
      elseif target_name == "density" then
        params:set(lfo_targets[target], lfo.scale(lfo[i].slope, -1.0, 2.0, 0, 512))
      -- spread
      elseif target_name == "spread" then
        params:set(lfo_targets[target], lfo.scale(lfo[i].slope, -1.0, 2.0, 0, 100))
      -- jitter
      elseif target_name == "jitter" then
        params:set(lfo_targets[target], lfo.scale(lfo[i].slope, -1.0, 2.0, 0, 500))
      -- position
      elseif target_name == "position" then
        engine.seek(voice, lfo.scale(lfo[i].slope, -1.0, 2.0, 0, 1))
      -- filter cutoff
      elseif target_name == "cutoff" then
        params:set(lfo_targets[target], lfo.scale(lfo[i].slope, -1.0, 2.0, 0, 20000))
      -- delay send
      elseif target_name == "send" then
        params:set(lfo_targets[target], lfo.scale(lfo[i].slope, -1.0, 2.0, 0.00, 1.00))
      end
    end
  end
end


-- init ----------

function init()
  g.key = function(x, y, z)
    grid_key(x, y, z)
  end
  
  -- polls
  for v = 1, VOICES do
    local phase_poll = poll.set('phase_' .. v, function(pos) positions[v] = pos end)
    phase_poll.time = 0.025
    phase_poll:start()

    local level_poll = poll.set('level_' .. v, function(lvl) voice_levels[v] = lvl end)
    level_poll.time = 0.05
    level_poll:start()
  end
    
  -- recorders
  for v = 1, VOICES do
    table.insert(pattern_timers, metro.init(function(tick) pattern_next(v) end))
    table.insert(pattern_banks, {})
    table.insert(pattern_leds, 0)
    table.insert(pattern_positions, 1)
  end
  
  params:add_separator("load samples")

  local sep = ": "

  --params:add_group("samples", VOICES)
  for i = 1, VOICES do
    params:add_file(i .. "sample", i .. sep .. "sample")
    params:set_action(i .. "sample", function(file) engine.read(i, file) end)
  end
  params:add_separator("mangl params")

  for v = 1, VOICES do
    params:add_group("voice " .. v, 15)

    params:add_option(v .. "play", "play", {"off","on"}, 1)
    params:set_action(v .. "play", function(x) engine.gate(v, x-1) end)

    params:add_taper(v .. "gain", "gain", -60, 20, -12, 0, "dB")
    params:set_action(v .. "gain", function(value) engine.gain(v, math.pow(10, value / 20)) end)

    params:add_control(v .. "pos", "pos", controlspec.new(0, 1, "lin", 0.001, 0))
    params:set_action(v .. "pos", function(value)  engine.seek(v, value) end)

    params:add_taper(v .. "speed", "speed", -300, 300, 0, 0, "%")
    params:set_action(v .. "speed", function(value) engine.speed(v, value / 100) end)

    params:add_taper(v .. "jitter", "jitter", 0, 500, 0, 5, "ms")
    params:set_action(v .. "jitter", function(value) engine.jitter(v, value / 1000) end)

    params:add_taper(v .. "size", "size", 1, 500, 100, 5, "ms")
    params:set_action(v .. "size", function(value) engine.size(v, value / 1000) end)

    params:add_taper(v .. "density", "density", 0, 512, 20, 6, "hz")
    params:set_action(v .. "density", function(value) engine.density(v, value) end)
    
    params:add_control(v .. "density_mod_amt", "density mod amt", controlspec.new(0, 1, "lin", 0, 0))
    params:set_action(v .. "density_mod_amt", function(value) engine.density_mod_amt(v, value) end)

    params:add_taper(v .. "pitch", "pitch", -24, 24, 0, 0, "st")
    params:set_action(v .. "pitch", function(value) engine.pitch(v, math.pow(0.5, -value / 12)) end)

    params:add_taper(v.."pan", v..sep.."pan", -100, 100, 0, 0, "%")
    params:set_action(v.."pan", function(value) engine.pan(v, value / 100) end)

    params:add_taper(v .. "spread", "spread", 0, 100, 0, 0, "%")
    params:set_action(v .. "spread", function(value) engine.spread(v, value / 100) end)
    
    params:add_control(v .. "cutoff", "filter cutoff", controlspec.new(20, 20000, "exp", 0, 20000, "hz"))
    params:set_action(v .. "cutoff", function(value) engine.cutoff(v, value) end)
    
    params:add_control(v .. "q", "filter q", controlspec.new(0.00, 1.00, "lin", 0.01, 1))
    params:set_action(v .. "q", function(value) engine.q(v, value) end)

    params:add_control(v .. "send", "delay send", controlspec.new(0.0, 1.0, "lin", 0.01, .2))
    params:set_action(v .. "send", function(value) engine.send(v, value) end)

    params:add_taper(v .. "fade", "att / dec", 1, 9000, 1000, 3, "ms")
    params:set_action(v .. "fade", function(value) engine.envscale(v, value / 1000) end)
  end

  params:add_group("delay", 8)
  -- effect controls
  -- delay time
  params:add_control("delay_time", "*" .. "delay time", controlspec.new(0.0, 60.0, "lin", .01, 2.00, ""))
  params:set_action("delay_time", function(value) engine.delay_time(value) end)
  -- delay size
  params:add_control("delay_size", "*" .. "delay size", controlspec.new(0.5, 5.0, "lin", 0.01, 2.00, ""))
  params:set_action("delay_size", function(value) engine.delay_size(value) end)
  -- dampening 
  params:add_control("delay_damp", "*" .. "delay damp", controlspec.new(0.0, 1.0, "lin", 0.01, 0.10, ""))
  params:set_action("delay_damp", function(value) engine.delay_damp(value) end)
  -- diffusion
  params:add_control("delay_diff", "*" .. "delay diff", controlspec.new(0.0, 1.0, "lin", 0.01, 0.707, ""))
  params:set_action("delay_diff", function(value) engine.delay_diff(value) end)
  -- feedback
  params:add_control("delay_fdbk", "*" .. "delay fdbk", controlspec.new(0.00, 1.0, "lin", 0.01, 0.20, ""))
  params:set_action("delay_fdbk", function(value) engine.delay_fdbk(value) end)
  -- mod depth
  params:add_control("delay_mod_depth", "*" .. "delay mod depth", controlspec.new(0.0, 1.0, "lin", 0.01, 0.00, ""))
  params:set_action("delay_mod_depth", function(value) engine.delay_mod_depth(value) end)
  -- mod rate
  params:add_control("delay_mod_freq", "*" .. "delay mod freq", controlspec.new(0.0, 10.0, "lin", 0.01, 0.10, "hz"))
  params:set_action("delay_mod_freq", function(value) engine.delay_mod_freq(value) end)
  -- delay output volume
  params:add_control("delay_volume", "*" .. "delay output volume", controlspec.new(0.0, 1.0, "lin", 0, 1.0, ""))
  params:set_action("delay_volume", function(value) engine.delay_volume(value) end)

  -- for hnds
  for i = 1, 4 do
    lfo[i].lfo_targets = lfo_targets
  end
  params:add_group("lfo's", 28)
  lfo.init()

  -- arc sensitivty settings
  params:add_separator("hardware config")
  params:add_option("alt_behavior", "alt behavior", {"momentary", "toggle"}, 1)

  params:add_number("speed_sens", "speed sens" .. sep, 1, 100, 10)
  params:set_action("speed_sens", function(x) speed_sens = x end)
  
  params:add_number("size_sens", "size sens" .. sep, 1, 100, 10)
  params:set_action("size_sens", function(x) size_sens = x end)
  
  params:add_number("density_sens", "density sens" .. sep, 1, 100, 10)
  params:set_action("density_sens", function(x) density_sens = x end)

  params:add_number("scrub_sens", "scrub sens" .. sep, 100, 1000, 500)
  params:set_action("scrub_sens", function(x) scrub_sens = x end)

  params:add_number("spread_sens", "spread sens" .. sep, 1, 100, 10)
  params:set_action("spread_sens", function(x) spread_sens = x end)

  params:add_number("jitter_sens", "jitter sens" .. sep, 1, 100, 10)
  params:set_action("jitter_sens", function(x) jitter_sens = x end)
  
  params:read()
  params:bang()
  -- grid refresh timer, 40 fps
  metro_grid_refresh = metro.init(function(stage) grid_refresh() end, 1 / 40)
  metro_grid_refresh:start()

  metro_blink = metro.init(function(stage) blink = blink ~ 1 end, 1 / 4)
  metro_blink:start()
  -- arc redraw metro
  local arc_redraw_timer = metro.init()
  arc_redraw_timer.time = 0.025
  arc_redraw_timer.event = function() arc_redraw() end
  arc_redraw_timer:start()
  -- norns redraw metro
  local norns_redraw_timer = metro.init()
  norns_redraw_timer.time = 0.025
  norns_redraw_timer.event = function() redraw() end
  norns_redraw_timer:start()
  -- loop metro
  local loop_timer = metro.init()
  loop_timer.time = 0.005
  loop_timer.event = function() loop_pos() end
  loop_timer:start()

  norns.enc.sens(3, 8)
  norns.enc.accel(3, false)
end

-- norns

function key(n, z)
  if n == 1 then
    hold_track_speed(track)
    if params:get("alt_behavior") == 1 then
      alt = z == 1 and true or false
    elseif z == 1 and params:get("alt_behavior") == 2 then
      alt = not alt
    end
  end

  if alt then
    -- key 2 sets the loop_in and loop_out points
    -- loop_in on press, loop_out on release
    if n == 2 then
      if z == 1 then
        if loop_in[track] == nil then
          if loops[track].dir == -1 then
            loop_out[track] = positions[track]
          else
            loop_in[track] = positions[track]
          end
        end
      else
        if loops[track].dir == -1 then
          loop_in[track] = positions[track]
          positions[track] = loop_out[track]
          engine.seek(track, loop_out[track])
          loops[track].state = 1
        else
          loop_out[track] = positions[track]
          positions[track] = loop_in[track]
          engine.seek(track, loop_in[track])
          loops[track].state = 1
        end
      end
    -- key 3 clears the currently selected track
    elseif n == 3 then
      clear_loop(track)
    end
  else
    if was_playing then
      set_speed(track)
      was_playing = false
    end
    -- key 2 activates and deactivates the currently selected voice
    if n == 2 and z == 1 then
      params:set(track .. "play", params:get(track .. "play") == 2 and 1 or 2)
    -- key 3 sets speed to 0
    elseif n == 3 and z == 1 then
      params:set(track .. "speed", 0)
    end
  end
end


function enc(n, d)
  if alt then
    if n == 1 then
      params:delta(track .. "cutoff", d)
    elseif n == 2 then 
      params:delta(track .. "send", d)
    end
  else
    if n == 1 then
      params:delta(track .. "gain", d)
    elseif n == 3 then
      track = util.clamp(track + d, 1, 7)
    end
  end
  last_enc = n
  time_last_enc = util.time()
end


function redraw()
  screen.aa(1)
  screen.clear()
  screen.move(123, 10)
  screen.font_face(25)
  screen.font_size(6)
  screen.level(2)
  if alt then
    screen.text_right(params:get(track .. "send"))
  else
    if params:get(track .. "sample") == "-" then
      screen.level(1)
      screen.text_right("-")
    else
      screen.text_right(get_sample_name())
    end
  end

  screen.move(64, 36)
  screen.level(params:get(track .. "play") == 2 and 15 or 3)
  screen.font_face(10)
  screen.font_size(30)
  screen.text_center(tracks[track])

  screen.level(2)
  screen.move(20, 10)
  screen.font_face(25)
  screen.font_size(6)
  if alt then
    screen.text_center(string.format("%.2f", params:get(track .. "cutoff")))
  else
    screen.text_center(string.format("%.2f", params:get(track .. "gain")))
  end

  screen.move(20, 50)
  screen.font_size(6)
  screen.font_face(25)
  screen.level(2)
  screen.text_center(alt and "scrub" or "speed")
  screen.move(50, 50)
  screen.text_center(alt and "fine" or "pitch")

  screen.move(80, 50)
  screen.text_center(alt and "spread" or "size")
  screen.move(110, 50)
  screen.text_center(alt and "jitter" or "density")

  screen.level(params:get(track .. "play") == 2 and 15 or 3)
  screen.move(20, 60)
  screen.font_size(8)
  screen.font_face(1)
  screen.text_center(alt and "-" or string.format("%.2f", params:get(track .. "speed")))
  screen.move(50, 60)
  screen.text_center(string.format("%.2f", params:get(track .. "pitch")))

  screen.move(80, 60)
  screen.text_center(string.format("%.2f", alt and params:get(track .. "spread") or params:get(track .. "size")))
  screen.move(110, 60)
  screen.text_center(string.format("%.2f", alt and params:get(track .. "jitter") or params:get(track .. "density")))

  if track == 3 then
    screen.move(100, 36)
  elseif track == 6 then
    screen.move(84, 36)
  elseif track == 7 then
    screen.move(103, 36)
  else
    screen.move(90, 36)
  end

  screen.level(loops[track].state == 1 and 12 or 0)
  screen.font_size(12)
  screen.font_face(12)
  screen.text("L")

  if not latched[track] then
    screen.level(12)
    screen.font_face(12)
    screen.font_size(8)
    screen.move_rel(-6, -11)
    screen.text("m")
  end
  screen.update()
end

-- arc ----------

function a.delta(n, d)
  if alt then
    if n == 1 then
      scrub(track, d)
    elseif n == 2 then
      params:delta(track .. "pitch", d / 20)
    elseif n == 3 then
      params:delta(track .. "spread", d / spread_sens)
    elseif n == 4 then
      params:delta(track .. "jitter", d / jitter_sens)
    end
  else
    if n == 1 then
      params:delta(track .. "speed", d / speed_sens)
    elseif n == 2 then
      params:delta(track .. "pitch", d / 2)
    elseif n == 3 then
      params:delta(track .. "size", d / size_sens)
    elseif n == 4 then
      params:delta(track .. "density", d / density_sens)
    end
  end
end


function a.key(n, z)
  -- for old push button arcs and 4e support
  alt = z == 1 and true or false
  if not alt and was_playing then
    set_speed(track)
  end
end

function arc_redraw()
  a:all(0)
  a:segment(1, positions[track] * tau, tau * positions[track] + 0.2, 15)
  local pitch = params:get(track .. "pitch") / 10
  if pitch > 0 then
    a:segment(2, 0.5, 0.5 + pitch, 15)
  else
    a:segment(2, pitch - 0.5, -0.5, 15)
  end
  if alt == true then
    local spread = params:get(track .. "spread") / 40
    local jitter = params:get(track .. "jitter") / 80
    a:segment(3, 0.5, 0.5 + spread, 15)
    a:segment(4, 0.5, 0.5 + jitter, 15)
  else
    local size = params:get(track .. "size") / 80
    local density = params:get(track .. "density") / 82
    a:segment(3, 0.5, 0.5 + size, 15)
    a:segment(4, 0.5, 0.5 + density, 15)
  end
  a:refresh()
end

-- grid ----------

function grid_key(x, y, z, skip_record)
  
  if y > 1 or (y == 1 and x < 9) then
    if not skip_record then
      record_event(x, y, z)
    end
  end
  -- track selection via grid press
  if y >= 2 and not skip_record then
    track = y - 1
    if alt and z == 1 then
      params:set(track .. "play", 2)
      latched[track] = not latched[track]
    else
      if latched[track] == false then
        params:set(track .. "play", z == 1 and 2 or 1)
      end
    end
  end
  
  if z > 0 then
    -- set voice pos
    if y > 1 then
      local voice = y - 1
      start_voice(voice, (x - 1) / 16)
      params:set(voice .. "play", 2)
    else
      if x == 16 then
        -- alt
        alt = true
      elseif x > 8 then
        record_handler(x - 8)
      elseif x == 8 then
        -- reserved
      elseif x < 8 then
        local voice = x
        if alt then
        -- stop
          stop_voice(voice)
          params:set(voice .. "play", 1)
        else
          track = voice
        end
      end
    end
  else
    -- alt
    if x == 16 and y == 1 then alt = false end
  end
end


function grid_refresh()
  if g == nil then
    return
  end

  grid_ctl:led_level_all(0)
  grid_voc:led_level_all(0)

  -- alt
  grid_ctl:led_level_set(16, 1, alt and 15 or 2)

  -- pattern banks
  for i=1, VOICES do
    local level = 4

    if #pattern_banks[i] > 0 then level = 8 end
    if pattern_timers[i].is_running then
      level = 12
      if pattern_leds[i] > 0 then
        level = 12
      end
    end

    grid_ctl:led_level_set(8 + i, 1, level)
  end

  -- blink armed pattern
  if record_bank > 0 then
      grid_ctl:led_level_set(8 + record_bank, 1, 15 * blink)
  end

  -- voices
  for i=1, VOICES do
    if i == track then
      grid_ctl:led_level_set(i, 1, 4)
    else
      grid_ctl:led_level_set(i, 1, 2)
    end
    if voice_levels[i] > 0 then
      grid_ctl:led_level_set(i, 1, math.min(math.ceil(voice_levels[i] * 15), 15))
      grid_voc:led_level_row(1, i + 1, display_voice(positions[i], 16))
    end
  end

  local buf = grid_ctl | grid_voc
  buf:render(g)
  g:refresh()
end


function cleanup()
  poll.clear_all()
end

