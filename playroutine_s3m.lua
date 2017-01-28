-- Basic playroutine skellington
-- by zorg @ 2017 § ISC
-------------------------------

-- Reference to the module
local module

local currentOrder
local currentPattern
local currentRow
local currentTick
-------------------------------

-- Period / Frequency Shenanigans

C4speedFinetunes = {
	[ 0x00 ] = 7895, -- -8
	[ 0x01 ] = 7941,
	[ 0x02 ] = 7985,
	[ 0x03 ] = 8046,
	[ 0x04 ] = 8107,
	[ 0x05 ] = 8169,
	[ 0x06 ] = 8232,
	[ 0x07 ] = 8280,
	[ 0x08 ] = 8363, -- Default
	[ 0x09 ] = 8413,
	[ 0x0A ] = 8463,
	[ 0x0B ] = 8529,
	[ 0x0C ] = 8581,
	[ 0x0D ] = 8651,
	[ 0x0E ] = 8723,
	[ 0x0F ] = 8757, -- +7
}

defaultC4speed = C4speedFinetunes[ 0x08 ]

fourthOctavePeriod = {1712, 1616, 1524, 1440,1356,1280,1208,1140,1076,1016,0960,0907}

baseClock  = defaultC4speed * fourthOctavePeriod[1]
fixedClock = baseClock / 44100 --samplingRate

notePeriod = {}

for octave = 0, 10 do
	for note = 1, 12 do
		notePeriod[octave*12+note] = (defaultC4speed * 16 * (fourthOctavePeriod[note] / 2^octave)) / C4speedFinetunes[8]
	end
end


-------------------------------

-- Voices

local voice = {}

voice.setNote = function(v, note)
	v.notePeriod = notePeriod[note]
	v._currentOffset = 0.0
end

voice.setInstrument = function(v, instrument)
	v.instrument = instrument
end

voice.setVolume = function(v, volume)
	v.sampleVolume = volume
end

voice.setOffset = function(v, offset)
	v.sampleOffset = offset
end

voice.process = function(v)
	if v.notePeriod == 0 then return 0 end
	if not v.instrument then return 0 end
	local normalizer = defaultC4speed / module.instruments[v.instrument].c4speed
	local currPeriod = v.notePeriod * normalizer
	v._currentOffset = v._currentOffset + (fixedClock / currPeriod)
	if v._currentOffset > module.instruments[v.instrument].data:getSampleCount() then
		v._currentOffset = 0.0
		v.notePeriod = 0
		return 0
	end
	--v._currentOffset = v._currentOffset % module.instruments[v.instrument].data:getSampleCount()
	local smp = module.instruments[v.instrument].data:getSample(math.floor(v._currentOffset))
	return smp
end

local mtVoice = {__index = voice}

local newVoice = function()
	local v = setmetatable({},mtVoice)

	v._currentOffset = 0.0

	v.notePeriod    = 0
	v.instrument    = 0

	v.sampleVolume  = 1.0 -- [ 0, 1]
	v.sampleOffset  = 0.0 -- [ 0, 65280] Oxx

	return v
end

local voices
-------------------------------

-- Sound Buffer

local samplingRate   = 44100                 -- Hz (1/seconds)
local bitDepth       =    16                 -- bits
local channelCount   =     1                 -- channels
local bufferSize     =  256                 -- samplepoints
local buffer         = love.sound.newSoundData(
					bufferSize,
					samplingRate, 
					bitDepth, 
					channelCount
					)                        -- SoundData
local bufferOffset   = 0                     -- samplepoints
-------------------------------

-- Queuable Source

local qSource      = love.audio.newQueueableSource(samplingRate, bitDepth, channelCount)
-------------------------------

-- Global Parameters

local tempo                                  -- beats per minute (Factor, not actual BPM!)
local speed                                  -- ticks per row (Divisor)
local timeSigNumer   =   4                   -- rows per beat (For actual BPM calculation)
local timeSigDenom   =   4                   -- row type (note lengths, for "midi")

-- Calculated Parameters

local midiPPQ                                -- pulse per quarternote
local samplingPeriod = 1 / samplingRate      -- seconds (per smp)
local tickPeriod                             -- seconds (per tick)
local actualBPM                              -- beats per minute (This one is the real deal.)

local restartOrder   = 0
local globalVolume   = 1.0
-------------------------------

-- Processing-related Variables

local cpuTime        = 0.0                   -- seconds (based on love.timer)
local bufferTime     = 0.0                   -- seconds (based on processed smp-s)

local playbackPos    = 0                     -- ticks
local samplesTotal   = 0                     -- +smp

local trackingMode   = 'buffer'                 -- cpu or buffer based playback cursor positioning
local tickAccum      = 0                     -- seconds
local samplesMixed   = 0                     -- smp

local patBreak, posJump = false, false       -- If true, handle position update specially.
-------------------------------

-- Functions

local fixTiming = function()
	midiPPQ        = speed * timeSigNumer * (4 / timeSigDenom)
	tickPeriod     = 2.5 / tempo
	actualBPM      = (60) / (tickPeriod * midiPPQ)
end

math.clamp = function(x,min,max)
	if min>max then min,max=max,min end
	return math.min(math.max(x, min), max)
end

local routine = {}

routine.load = function(mod)
	module = mod
	-- Set initial values.
	tempo = module.initialTempo
	speed = module.initialSpeed

	fixTiming()

	-- Init to beginning.
	currentOrder   = 0
	currentPattern = module.orders[currentOrder]
	currentRow     = 0
	currentTick    = 0

	-- Create voices for each track ("channel")
	voices = {}
	for i = 0, module.chnNum - 1 do
		voices[i] = newVoice()
	end

	-- Step the timer since startup may spike the dt, which
	-- is bad news for any time-sensitive code.
	love.timer.step()

end

routine.update = function(dt)

	-- This always happens with the function call.
	cpuTime = cpuTime + dt

	-- If there are no more free internal buffers, return early.
	if qSource:getFreeBufferCount() == 0 then
		return
	end

	-- Advance the playback cursor using one of the below methods.
	if trackingMode == 'cpu' then
		tickAccum = tickAccum + dt
	elseif trackingMode == 'buffer' then
		tickAccum = tickAccum + (samplingPeriod * samplesMixed)
	end

	-- If we've accumulated enough to reach a new tick, process it.
	if tickAccum >= tickPeriod then
		tickAccum = tickAccum - tickPeriod

		-- Skip marker and empty patterns (254, 255).
		if currentPattern < 254 then

			-- Process tracks ("channels").
			for ch=0, module.chnNum-1 do

				local channel = module.patterns[currentPattern][currentRow][ch]

				if channel then

					-- Check for cell components.

					local note       = channel.note
					if type(note) == 'number' then
						-- Note pitch.
					elseif note == '^^ ' then
						-- Note cut.
					end

					local instrument = channel.instrument
					if instrument then
						-- Apply instrument.
					end

					local volume     = channel.volumecmd
					if volume then
						-- Apply extra volume command.
						-- Range: 0x00-0x40, so normalize by 64.
						voices[ch]:setVolume(volume / 64)
					end

					local effect      = channel.effectcmd
					effect = effect and string.char(effect+64) or false
					local effectParam = channel.effectprm

					-- First tick of every row.
					if currentTick == 0 then

						-- T0 effects.
						if     effect == 'A' then
							-- Set Speed
							-- 0 speed not allowed for obvious reasons.
							if effectParam >= 0x01 and effectParam <= 0xFF then
								speed = effectParam
							end
						elseif effect == 'T' then
							-- Set Tempo
							-- Minimum tempo should be 32 BPM, though we technically COULD allow lower values.
							if effectParam >= 0x20 and effectParam <= 0xFF then
								tempo = effectParam
							end
						elseif effect == 'B' then
							-- Position Jump (to order)
							posJump = math.clamp(effectParam, 0x00, 0xFF)
						elseif effect == 'C' then
							-- Pattern Break (to row)
							-- Stored as two decimal digits, so needs conversion.
							patBreak = math.clamp(math.floor(effectParam/16)*10 + effectParam%16, 0, 63)
						elseif effect == 'O' then
							-- Set (sample) Offset
							local offset = math.clamp(effectParam, 0x00, 0xFF)
							offset = offset * 0x100
							voices[ch]:setOffset(offset)
						end

					end

				end

			end

			-- Fix timing, since we may have modified it in one of the tracks.
			fixTiming()

		end

		-- Advance playback position.
		if not (posJump or patBreak) then
			-- Simple case.
			if currentTick + 1 < speed then
				currentTick = currentTick + 1
			else
				currentTick = 0
				--print(currentOrder, currentPattern)
				if currentRow + 1 <= #module.patterns[currentPattern] then
					currentRow = currentRow + 1
				else
					currentRow = 0
					if currentOrder + 1 <= #module.orders then
						currentOrder = currentOrder + 1
						currentPattern = module.orders[currentOrder]
					else
						currentOrder = 0
						currentPattern = module.orders[currentOrder]
					end
				end
			end
			-- Check for markers and empty pattern slots.
			-- Not sure if 255 can appear between legit slots or not, if not, this code
			-- can be adjusted a bit.
			if currentPattern >= 254 then
				--print "Found Marker / Empty pattern!"
				for i = currentOrder, #module.orders do
					--print("order ",i,"has pattern ",module.orders[i])
					if module.orders[i] < 254 then
						currentOrder = i
						currentPattern = module.orders[currentOrder]
						-- Unless we want the code jumping in the middle of random patterns
						-- if the posjump/patbreak would go to an invalid pattern, then
						-- leave this uncommented.
						currentTick = 0
						currentRow = 0
						break
					end
				end
				if currentPattern >= 254 then
					-- Restart from beginning
					currentOrder = 0
					currentPattern = module.orders[currentOrder]
					currentTick = 0
					currentRow = 0
				end
			end
		else
			-- Special handling.
			currentTick = 0
			if posJump and not patBreak then
				-- Jump to 0th row of given order.
				currentOrder = posJump % #module.orders
				currentPattern = module.orders[currentOrder]
				currentRow = 0
			elseif not posJump and patBreak then
				-- Jump to given row of next order.
				currentOrder = (currentOrder + 1) % #module.orders
				currentPattern = module.orders[currentOrder]
				currentRow = patBreak % #module.patterns[currentPattern]
			else
				-- Jump to given row of given order.
				currentOrder = posJump % #module.orders
				currentPattern = module.orders[currentOrder]
				currentRow = patBreak % #module.patterns[currentPattern]
			end
			posJump, patBreak = false, false
		end

		-- Stats.
		playbackPos = playbackPos + 1
	end

	-- Render samplepoint(s); count based on elapsed CPU time.
	-- Technically this isn't the best thing to do, but whatever.
	-- Code doesn't deal with stereo, for now.
	local samplesToMix = math.ceil(dt / samplingPeriod)
	for i=0, samplesToMix do

		-- Render each voice, and mix them together
		-- |output| <= 1.0 * N -> Normalize to [-1,1]
		local smp = 0.0
		for ch = 0, module.chnNum - 1 do
			smp = smp + voices[ch]:process()
		end
		smp = smp / 32.0
		buffer:setSample(bufferOffset, smp)

		-- Advance buffer pointer, flush buffer if full.
		bufferOffset = bufferOffset + 1
		if bufferOffset >= buffer:getSampleCount() then
			bufferOffset = 0
			qSource:queue(buffer)
			qSource:play() -- For safety.
		end
	end

	samplesMixed = samplesToMix
	samplesTotal = samplesTotal + samplesToMix

	-- How much time elapsed with regards to processed smp-s.
	bufferTime = bufferTime + (samplesToMix * samplingPeriod)
end

routine.draw = function()
	love.graphics.setColor(1,1,1)
	love.graphics.print(("Samples mixed:       %d (%d)"):format(samplesMixed, math.floor(samplesTotal/bufferSize)), 0, 0)
	love.graphics.print(("Playback position:   %d"):format(playbackPos),         0, 12)
	love.graphics.print(("Time (Buffer-based): %5.5g"):format(bufferTime),       0, 24)
	love.graphics.print(("Time (Timer-based):  %5.5g"):format(cpuTime),          0, 36)
	love.graphics.print(("Sampling period:     %g"):format(samplingPeriod*1000), 0, 48)
	love.graphics.print(("Tick period:         %g"):format(tickPeriod*1000),     0, 60)
	love.graphics.print(("Actual Tempo:        %g"):format(actualBPM),           0, 72)

	love.graphics.print("smps",    32*8, 0)
	love.graphics.print("ticks",   32*8, 12)
	love.graphics.print("seconds", 32*8, 24)
	love.graphics.print("seconds", 32*8, 36)
	love.graphics.print("ms",      32*8, 48)
	love.graphics.print("ms",      32*8, 60)
	love.graphics.print("BPM",     32*8, 72)

	if module then

		love.graphics.print(("Order:   %d"):format(currentOrder),   42*8, 0)
		love.graphics.print(("Pattern: %d"):format(currentPattern), 42*8, 12)
		love.graphics.print(("Row:     %d"):format(currentRow),     42*8, 24)
		love.graphics.print(("Tick:    %d"):format(currentTick),    42*8, 36)
		love.graphics.print(("Speed:   %d"):format(speed),          42*8, 48)
		love.graphics.print(("Tempo:   %d"):format(tempo),          42*8, 60)
		love.graphics.print(("Timing:  %s"):format(trackingMode),   42*8, 72)

		love.graphics.print(("/ %d"):format(#module.orders),                   56*8, 0)
		love.graphics.print(("/ %d"):format(#module.patterns),                 56*8, 12)
		love.graphics.print(("/ %d"):format(#module.patterns[currentPattern]), 56*8, 24)
		love.graphics.print(("/ %d"):format(speed-1),                          56*8, 36)

		if not module.patterns[currentPattern] then return end
		for i=0, #module.patterns[currentPattern] do
			if i ~= currentRow then
				love.graphics.setColor(0.5,0.5,0.5)
			else
				if     currentTick == 0 then
					love.graphics.setColor(1.0,1.0,1.0)
				else
					love.graphics.setColor(0.75,0.75,0.25)
				end
			end
			love.graphics.print(("%02d"):format(i), 0, 84+i*12)
			love.graphics.print(module.printRow(module.patterns[currentPattern][i], module.chnNum),14,84+i*12)
		end
	end
end
-------------------------------

--------------
return routine
-------------------------------