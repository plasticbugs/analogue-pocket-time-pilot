-- Dump one frozen Time Pilot machine state plus the MAME snapshot of exactly
-- that state.
--
-- The game rewrites sprite RAM part way down every frame (the cloud multiplex,
-- see docs/hardware.md 7.3), so a frame MAME renders is NOT a function of the
-- sprite RAM you can read at the end of it. To get a state a static renderer
-- can be held to, the CPU is parked in a JR $ loop with the NMI masked off,
-- then a couple of frames are allowed to draw before capturing.
--
-- usage: TP_FRAME=900 TP_TAG=0900 mame timeplt -autoboot_script tools/dumpstate.lua

local OUT    = os.getenv("TP_OUT")   or "artifacts"
local TARGET = tonumber(os.getenv("TP_FRAME") or "900")
local TAG    = os.getenv("TP_TAG")   or string.format("%04d", TARGET)

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]

local PARK = 0xaff0            -- scratch at the top of work RAM

local ports = mach.ioport.ports
local function field(port, name)
    local p = ports[port]
    return p and p.fields[name] or nil
end
local coin  = field(":IN0", "Coin 1")
local st1   = field(":IN0", "1 Player Start")
local fire  = field(":IN1", "P1 Button 1")
local left  = field(":IN1", "P1 Left")
local right = field(":IN1", "P1 Right")

local frame, frozen_at = 0, nil
local park_save = {}          -- work RAM bytes the park stub overwrites

local function hold(f, on) if f then f:set_value(on and 1 or 0) end end

local function freeze()
    park_save[0] = sp:read_u8(PARK)
    park_save[1] = sp:read_u8(PARK + 1)
    sp:write_u8(PARK,     0x18)     -- JR $-2
    sp:write_u8(PARK + 1, 0xfe)
    cpu.state["PC"].value = PARK
    sp:write_u8(0xc300, 0x00)       -- LS259 bit 0 = 0: NMI off and any pending one cleared
    print(string.format("[tp] frozen at frame %d", frame))
end

local function dump()
    local f = assert(io.open(string.format("%s/state_%s.txt", OUT, TAG), "w"))
    f:write(string.format("frame %d\n", frozen_at))
    local function region(name, base, len)
        f:write(name, "\n")
        local line = {}
        for i = 0, len - 1 do
            line[#line + 1] = string.format("%02x", sp:read_u8(base + i))
            if #line == 32 then f:write(table.concat(line), "\n"); line = {} end
        end
        if #line > 0 then f:write(table.concat(line), "\n") end
    end
    region("COLORRAM",   0xa000, 0x400)
    region("VIDEORAM",   0xa400, 0x400)
    region("SPRITERAM0", 0xb000, 0x100)
    region("SPRITERAM1", 0xb400, 0x100)
    -- work RAM, with the park stub's two bytes put back so the dump describes
    -- the machine as it was, not as the freeze left it
    f:write("WORKRAM\n")
    local line = {}
    for i = 0, 0x7ff do
        local a = 0xa800 + i
        local v = sp:read_u8(a)
        if a == PARK     then v = park_save[0] end
        if a == PARK + 1 then v = park_save[1] end
        line[#line + 1] = string.format("%02x", v)
        if #line == 32 then f:write(table.concat(line), "\n"); line = {} end
    end
    if #line > 0 then f:write(table.concat(line), "\n") end
    f:write("END\n")
    f:close()
    mach.video:snapshot()
    print(string.format("[tp] dumped %s", TAG))
    mach:exit()
end

emu.register_frame_done(function()
    frame = frame + 1
    if frozen_at then
        if frame == frozen_at + 2 then dump() end
        return
    end
    -- deterministic run-in: coin, start, then wiggle so the screen gets busy
    hold(coin, frame >= 600 and frame < 604)
    hold(st1,  frame >= 660 and frame < 664)
    if frame > 700 then
        hold(fire, true)
        hold(right, (frame // 60) % 2 == 0)
        hold(left,  (frame // 60) % 2 == 1)
    end
    if frame == TARGET then
        freeze()
        frozen_at = frame
    end
end)

print("[tp] dumpstate.lua armed for frame " .. TARGET)
