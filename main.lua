love.run = function()
	if love.math then
		love.math.setRandomSeed(os.time())
	end
 
	if love.load then love.load(arg) end
 
	-- We don't want the first frame's dt to include time taken by love.load.
	if love.timer then love.timer.step() end

	local dt = 0.0    -- delta time
 
	local tr = 1/100  -- tick rate
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

-------------------------------------------------------------------------------

local loader = require "loader"

function love.filedropped(file)
	-- Stop playback
	-- Unload previous data
	-- Use the loader to detect and load in the module file.
	-- Init playroutine with one fitting the module.

	module = loader(file)
end












local threadData = 'thread.lua'
local ti, to
local thread

local sd

love.load = function(args)
	--thread = love.thread.newThread(threadData)
	--ti, to = love.thread.newChannel(), love.thread.newChannel()

	--sd = love.sound.newSoundData(1024, 44100, 16, 1) -- buffsize,smplrate,bitdepth,channels

	--thread:start(ti,to,sd)
end

love.update = function(dt)
	--if not thread:isRunning() then
		--print(thread:getError())
	--end
end