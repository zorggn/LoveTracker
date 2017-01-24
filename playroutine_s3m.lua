-- Basic playroutine skellington
-- by zorg @ 2017 § ISC
-------------------------------

-- Sound Buffer

local samplingRate   = 44100                 -- Hz (1/seconds)
local bitDepth       =    16                 -- bits
local channelCount   =     1                 -- channels
local bufferSize     =  1000                 -- samplepoints
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

local tempo          = 120                   -- beats per minute
local speed          =   6                   -- ticks per row
local timeSigNumer   =   4                   -- rows per beat
local timeSigDenom   =   4                   -- row type (note lengths, for "midi")

-- Calculated Parameters

local midiPPQ        = speed * timeSigNumer *
						(4 / timeSigDenom)   -- pulse per quarternote
local samplingPeriod = 1 / samplingRate      -- seconds (per smp)
local tickPeriod     = (60) / ( tempo *
						timeSigNumer * speed)-- seconds (per tick)

local restartOrder   = 0
local globalVolume   = 1.0
-------------------------------

-- Processing-related Variables

local cpuTime        = 0.0                   -- seconds (based on love.timer)
local bufferTime     = 0.0                   -- seconds (based on processed smp-s)

local playbackPos    = 0                     -- ticks

local trackingMode   = 'cpu'                 -- cpu or buffer based playback cursor positioning
local tickAccum      = 0                     -- seconds
local samplesMixed   = 0                     -- smp
-------------------------------

-- Function

return function(dt)

	-- This always happens with the function call.
	cpuTime = cpuTime + dt

	-- If there are no more free internal buffers, return early.
	if qSource:getFreeBufferCount() == 0 then
		return 0, playbackPos, bufferTime, cpuTime, samplingPeriod, tickPeriod
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

		-- Stuff.

		-- Advance playback position.
		playbackPos = playbackPos + 1
	end

	-- Render samplepoint(s); count based on elapsed CPU time.
	-- Code doesn't deal with stereo, for now.
	local samplesToMix = math.ceil(dt / samplingPeriod)
	for i=0, samplesToMix do

		-- Render each voice, and mix them together
		-- |output| <= 1.0 * N -> Normalize to [-1,1]
		local smp = 0.0
		for i = 0, 31 do
			smp = smp + ((playbackPos%24==0) and (((playbackPos%24)/12)-12) or love.math.random()) -- Beat test
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

	-- How much time elapsed with regards to processed smp-s.
	bufferTime = bufferTime + (samplesToMix * samplingPeriod)

	-- Use in another place to draw stuff out.
	return samplesToMix, playbackPos, bufferTime, cpuTime, samplingPeriod, tickPeriod
end
-------------------------------