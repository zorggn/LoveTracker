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
	if module then
		routine = love.filesystem.load("play_" .. module.fileType .. ".lua")()
		-- Play the module.
		if routine then routine.load(module) end
	end
end

-------------------------------------------------------------------------------

love.load = function(args)

	love.graphics.setFont(love.graphics.newFont('FSEX300.ttf', 16))

end

love.atomic = function(dt)
	if routine then
		routine.update(dt)
	end
end

love.update = function(dt)
	
end

love.draw = function()
	if routine then
		routine.draw()
	end
end

love.keypressed = function(...)
	if routine then
		routine.keypressed(...)
	end
end