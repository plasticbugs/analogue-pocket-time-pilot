-- Play one sound command in MAME with nothing else going on, so it can be
-- compared against the same command driven into the core in isolation
-- (sim/run_sound.sh).
--
-- The main CPU is parked first, exactly as tools/dumpstate.lua does it, so the
-- only thing the sound board hears is the command written here.
--
--   TP_CMD=01 TP_AT=180 mame timeplt -autoboot_script tools/sndcmd.lua -wavwrite out.wav

local CMD  = tonumber(os.getenv("TP_CMD") or "01", 16)
local AT   = tonumber(os.getenv("TP_AT")  or "180")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local sp   = cpu.spaces["program"]
local PARK = 0xaff0

local frame = 0

local function park()
    sp:write_u8(PARK,     0x18)      -- JR $-2
    sp:write_u8(PARK + 1, 0xfe)
    cpu.state["PC"].value = PARK
    sp:write_u8(0xc300, 0x00)        -- NMI off
end

local function send(v)
    sp:write_u8(0xc000, v)           -- command latch
    sp:write_u8(0xc304, 0x01)        -- LS259 Q2 rising edge -> sound IRQ
    sp:write_u8(0xc304, 0x00)
end

emu.register_frame_done(function()
    frame = frame + 1
    if frame == AT - 60 then park()          end
    if frame == AT - 30 then send(0x00)      end   -- silence every voice
    if frame == AT      then
        send(CMD)
        print(string.format("[tp] command 0x%02x at frame %d (t=%.4f s)", CMD, frame, frame / 60.0))
    end
end)
