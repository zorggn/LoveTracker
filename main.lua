love.run = function()
	if love.math then
		love.math.setRandomSeed(os.time())
	end
 
	if love.load then love.load(arg) end
 
	-- We don't want the first frame's dt to include time taken by love.load.
	if love.timer then love.timer.step() end

	local dt = 0.0    -- delta time
 
	local tr = 1/60  -- tick rate
	local fr = 1/60   -- frame rate

	local da = 0.0    -- draw accumulator
	local ua = 0.0    -- update accumulator
 
	-- Main loop time.
	while true do
		-- Process events.
		if love.event then
			love.event.pump()
			for name, a,b,c,d,e,f in love.event.poll() do
				if name == "quit" then
					if not love.quit or not love.quit() then
						return a
					end
				end
				love.handlers[name](a,b,c,d,e,f)
			end
		end
 
		-- Update dt, as we'll be passing it to update
		if love.timer then
			love.timer.step()
			dt = love.timer.getDelta()
			da = da + dt
			ua = ua + dt
		end
 
		-- Call atomic
		if love.atomic then love.atomic(dt) end

		-- Call update
		if ua > tr then
			if love.update then
				love.update(tr) -- will pass 0 if love.timer is disabled
			end
			ua = ua % tr
		end
 
		-- Call draw
		if da > fr then
			if love.graphics and love.graphics.isActive() then
				love.graphics.clear(love.graphics.getBackgroundColor())
				love.graphics.origin()
				if love.draw then love.draw() end -- no interpolation
				love.graphics.present()
			end
			da = da % fr
		end
 
		-- Optimal sleep time, anything higher does not go below 0.40 % cpu
		-- utilization; 0.001 results in 0.72 %, so this is an improvement.
		if love.timer then love.timer.sleep(0.002) end
	end
end

local log = function(str,...) print(string.format(str,...)) end

-------------------------------------------------------------------------------

local loader = require "loader"

local module
local routine

function love.filedropped(file)

	-- Stop playback; Unload previous data.
	if routine and routine.playing then
		love.audio.stop()
		routine = nil 
	end
	if module then
		module = nil
	end

	-- Use the loader to detect and load in the module file.
	module = loader(file)

	-- Init playroutine with one fitting the module.
	routine = require("playroutine_" .. module.fileType)

	-- Play the module.
	-- routine.init(module)
end

-------------------------------------------------------------------------------

local samplesToMix, playbackPosition, bufferTime, cpuTime, samplingPeriod, tickPeriod = 0,0,0,0,0,0

love.load = function(args)

	love.graphics.setFont(love.graphics.newFont('FSEX300.ttf', 16))

end

love.atomic = function(dt)
	
end

love.update = function(dt)
	if routine then
		samplesToMix, playbackPosition, bufferTime, cpuTime, samplingPeriod, tickPeriod = routine(dt)
	end
end

love.draw = function()
	love.graphics.setColor(1,1,1)
	love.graphics.print(("Samples mixed:       %d smps"):format(samplesToMix), 0, 0)
	love.graphics.print(("Playback position:   %d ticks"):format(playbackPosition), 0, 12)
	love.graphics.print(("Time (Buffer-based): %g seconds"):format(bufferTime), 0, 24)
	love.graphics.print(("Time (Timer-based):  %g seconds"):format(cpuTime), 0, 36)
	love.graphics.print(("Sampling period:     %g ms"):format(samplingPeriod*1000), 0, 48)
	love.graphics.print(("Tick period:         %g ms"):format(tickPeriod*1000), 0, 60)

	if module then

	-- Position is in ticks, so we just improvise by treating all rows having 6 ticks, and all patterns having 64 rows.
		local currentOrder   = math.floor((playbackPosition/6/64) % #module.orders) -- number
		local currentPattern = module.orders[currentOrder] -- number
		local currentRow     = math.floor((playbackPosition/6)%64) -- number
		local currentTick    = math.floor(playbackPosition%6) -- number

		if not module.patterns[currentPattern] then return end
		for i=0, #module.patterns[currentPattern] do
			if i ~= currentRow then
				love.graphics.setColor(0.5,0.5,0.5)
			else
				if     currentTick == 0 then
					love.graphics.setColor(1.0,0.0,0.0)
				elseif currentTick == 1 then
					love.graphics.setColor(1.0,1.0,0.0)
				elseif currentTick == 2 then
					love.graphics.setColor(0.0,1.0,0.0)
				elseif currentTick == 3 then
					love.graphics.setColor(0.0,1.0,1.0)
				elseif currentTick == 4 then
					love.graphics.setColor(0.0,0.0,1.0)
				elseif currentTick == 5 then
					love.graphics.setColor(1.0,0.0,1.0)
				end
			end
			love.graphics.print(("%02d"):format(i), 0, i*12)
			love.graphics.print(module.printRow(module.patterns[currentPattern][i], module.chnNum),12,i*12)
		end
	end
end