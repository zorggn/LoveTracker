--F >= 0x20 -> Tempo!
--F <  0x20 -> Speed!


-- http://eab.abime.net/showthread.php?t=53623

-- correct NTSC
local XTAL_NTSC         =                                            28.63636000-- MHz
local NTSC_COLORCARRIER = XTAL_NTSC / 8                           --  3.57954500   MHz

-- correct PAL
local XTAL_PAL          =                                            28.37516000-- MHz
local PAL_LINES         = 625
local PAL_FRATE         = 50 / 2   -- Hz
local PAL_COLORCARRIER  = XTAL_PAL * (PAL_LINES * PAL_FRATE)      --  4.43361875   MHz
-- a +25 may be missing from the above...
local AMIGA_COLORCLOCK  = PAL_COLORCARRIER / 1.25                 --  3.54689500   MHz

-- Final values to be used
local AMIGA_CPU_NTSC    = NTSC_COLORCARRIER * 2                   --  7.15909000   MHz
local AMIGA_CPU_PAL     = AMIGA_COLORCLOCK  * 2                   --  7.09379000   MHz

local AMIGA_CPU_NOTNTSC =                                             7.15909050-- MHz
-- The above value is also found in some module spec. docs.
local AMIGA_CPU_NOTPAL  =                                             7.09378920-- MHz
-- The above value results if the pal color carrier is taken as 4.43361825 Mhz.
local AMIGA_CPU_NOTPAL2 =                                             7.09379000-- MHz
-- The above with a crystal frequency of 28.375 MHz.



local module

local routine = {}

routine.load = function(mod)
	module = mod
	print(mod)
	print(mod.samples)
	print(mod.samples[3])
	print(mod.samples[3].length)
end

routine.update = function(dt)

end

local smpidx = 3
local wwidth = 1816
routine.draw = function()
	love.graphics.print(('%02d'):format(smpidx),0,0)
	if module.samples[smpidx].length > 0 then

		local div, len = 1, module.samples[smpidx].length
		while len > wwidth do
			if len / div < wwidth then break end
			div = div + 1
		end

		local truncOffset = module.samples[smpidx].length-module.samples[smpidx].loopstart/2

		love.graphics.print(('  : %s (/%d)'):format(module.samples[smpidx].name, div),0,0)
		love.graphics.print(('Length %d (%d)'):format(module.samples[smpidx].length,truncOffset),0,12)
		love.graphics.print(('Finetune %d'):format(module.samples[smpidx].finetune),0,24)
		love.graphics.print(('Volume %d'):format(module.samples[smpidx].volume),0,36)
		love.graphics.print(('|: %d (%d)'):format(module.samples[smpidx].loopstart, 0),0,48)
		love.graphics.print((':| %d (%d)'):format(module.samples[smpidx].looplen, (truncOffset + module.samples[smpidx].looplen/2)),0,60)

		-- Loop start is in bytes, but length should be treated as WORDs, so...
		-- MODs with defined loop starts need to have the area before the loopstart
		-- truncated... except one needs to divide loop start with 2 to get the correct
		-- position...

		-- 15 and 31 instrument mod loop positions behave differently...
		if module.oldFormat then
			love.graphics.line(
				math.floor(module.samples[smpidx].loopstart/2/div)+16,
				0,
				math.floor(module.samples[smpidx].loopstart/2/div)+16,
				1024)

			love.graphics.line(
				math.floor((module.samples[smpidx].length - (truncOffset - module.samples[smpidx].looplen))/div)+16,
				0,
				math.floor((module.samples[smpidx].length - (truncOffset - module.samples[smpidx].looplen))/div)+16,
				1024)
		else
			love.graphics.line(
				math.floor(module.samples[smpidx].loopstart/div)+16,
				0,
				math.floor(module.samples[smpidx].loopstart/div)+16,
				1024)

			love.graphics.line(
				math.floor((module.samples[smpidx].loopstart + module.samples[smpidx].looplen)/div)+16,
				0,
				math.floor((module.samples[smpidx].loopstart + module.samples[smpidx].looplen)/div)+16,
				1024)
		end

		for i=0, #module.samples[smpidx].raw-1 do

			local smp = module.samples[smpidx].raw:sub(i+1,i+1):byte()

			-- samplepoint values
			if i < 1024/12 then
				love.graphics.print((smp >= 0x80 and -0x100+smp or smp),0,(6*12)+(i*12))
			end

			-- visual display
			love.graphics.push('all')
			love.graphics.setColor(0,.25,.75)
			if i < #module.samples[smpidx].raw-1 then
				local smp2 = module.samples[smpidx].raw:sub(i+2,i+2):byte()
				love.graphics.line(
					math.floor(i/div)+16,
					512 - (smp >= 0x80 and -0x100+smp or smp),
					math.floor((i+1)/div)+16,
					512 - (smp2 >= 0x80 and -0x100+smp2 or smp2)
					)
			end
			love.graphics.pop()
			love.graphics.points(math.floor(i/div)+16,512 - (smp >= 0x80 and -0x100+smp or smp))
		end
	end
end

routine.keypressed = function(k)
	if k == 'left' then
		smpidx = ((smpidx - 2) % #module.samples) + 1
		if module.samples[smpidx].length > 0 then
			love.audio.newSource(module.samples[smpidx].data):play()
		end
	end
	if k == 'right' then
		smpidx = ((smpidx    ) % #module.samples) + 1
		if module.samples[smpidx].length > 0 then
			love.audio.newSource(module.samples[smpidx].data):play()
		end
	end
end

return routine