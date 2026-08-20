-- Drive Time Pilot through the same scripted input sequence the RTL benches
-- use, so MAME and the core can be recorded over the same window.
local mach  = manager.machine
local ports = mach.ioport.ports
local function field(p, n) local q = ports[p]; return q and q.fields[n] or nil end
local coin  = field(":IN0", "Coin 1")
local st1   = field(":IN0", "1 Player Start")
local fire  = field(":IN1", "P1 Button 1")
local left  = field(":IN1", "P1 Left")
local right = field(":IN1", "P1 Right")
local frame = 0
local function hold(f, on) if f then f:set_value(on and 1 or 0) end end
emu.register_frame_done(function()
    frame = frame + 1
    hold(coin, frame >= 600 and frame < 604)
    hold(st1,  frame >= 660 and frame < 664)
    if frame > 700 then
        hold(fire, true)
        hold(right, (frame // 60) % 2 == 0)
        hold(left,  (frame // 60) % 2 == 1)
    end
end)
