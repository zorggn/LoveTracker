-- Organya "Org" playroutine
-- by zorg @ 2017 § ISC



-- Note: To keep things compact, everything not generic enough to be used by
--       other playroutines are kept inside the respective play_*.lua files,
--       a.k.a. these ones.

local Device = require 'device'
local device = Device(44100, 16, 2, 1024, 'Buffer', 'Buffer')

-- Start defining everything as local, then if we need something to be passed
-- into something that's a bit more "closed", redefine it as a var. of routine.

local source = device.source
local buffer = device.buffer

local module, voice

local tickPeriod, samplingPeriod

local normalizer, normRatio, samplesToMix

local tickAccumulator, currentTick, currentBeat, currentBar
local currentBeatTick, currentBarBeat



-- Constants

local DRUMKIT = {
	[0] = "BASS01.raw",
	      "BASS02.raw",
	      "SNARE01.raw",
	      "SNARE02.raw",
	      "TOM01.raw",
	      "HICLOSE.raw",
	      "HIOPEN.raw",
	      "CRASH.raw",
	      "PER01.raw",
	      "PER02.raw",
	      "BASS03.raw",
	      "TOM02.raw"
} -- Org-02 compatible only, for now.

-- Yoinked from Cucky's C++ implementation
local FREQTABLE = {
   261.62556530060, 277.18263097687, 293.66476791741,
   311.12698372208, 329.62755691287, 349.22823143300,
   369.99442271163, 391.99543598175, 415.30469757995,
   440.00000000000, 466.16376151809, 493.88330125612,
}

local SMPINCREMENT  = {   1,  1,  2,  4, 8,16,32,64}
local SMPMULTIPLIER = {   4,  2,  2,  2, 2, 2, 2, 2}
local PERIODSIZE    = {1024,512,256,128,64,32,16, 8}
local pitchClass    = {
	33408, -- C
	35584,
	37632,
	39808,
	42112,
	44672,
	47488,
	50048,
	52992,
	56320,
	59648,
	63232, -- B
}

-- Replace pitch class data from rnhart.net's approximations with calculated values gotten by rev.-engineering:
for i=1,12 do pitchClass[i] = FREQTABLE[i] * 128 end -- 440.0 * 128 = 56320 exactly.

-- More correct Volume function
local VOLMIN   = 0.204
--local VOLCURVE = function(v) return VOLMIN + ((v) * (1.0 - VOLMIN)) end
-- The old guessed Volume function
--local VOLCURVE = function(v) return 10^(v-1) end
-- A combined Volume function; [0.100,1.000] -> [100,1000] -> [0,900] -> [0,796] -> [204,1000] -> [0.204,1.000]
-- This one keeps the curve assumed by rnhart.net, but starts at the correct minimum volume, and ends at 1.0 max.
local VOLCURVE = function(v) return ((10^(v-1)-0.1)*(796/900))+VOLMIN end
local PANLAW   = function(p)
	local l = (p >= 0.0 and p <= 0.5) and 1.0 or 20.0^(1.0-2.0*p)
	local r = (p >= 0.5 and p <= 1.0) and 1.0 or 20.0^(2.0*p-1.0)
	return l, r
end
local PIZZICATO = function(o) return o*4 end



-- Voice objects

local Voice = {}

Voice.getStatistics = function(v)
	return v.finetune, v.instrument, v.pizzicato, v.currentEvent, v.eventCount,
		v.position, v.pitch, v.length, v.volume, v.panning, v.ticksLeft,
		v.currentOffset
end

Voice.setPitch = function(v, pitch)
	v.pitch = pitch
	if v.pitch < 0xFF then -- else no change
		v.pitchClass = (v.pitch % 12)+1
		v.octave     = math.floor(v.pitch / 12)+1
		if v.type == 'melodic' then
			v.frequency = (pitchClass[v.pitchClass] + (v.finetune - 1000)) /
				PERIODSIZE[v.octave]
		else
			-- Percussives use linear frequency.
			-- 22050 is the sampling rate for pxt.
			-- 32.5 is most probably the lowest frequency supported.
			-- Also explains why a pitch of 0x00 doesn't play, since we have 0 in the numerator.
			v.frequency = v.pitch * (22050/32.5) / device.samplingRate

			-- Re-trigger percussive voices.
			v.currentOffset = 0
		end
	end
end

Voice.setLength = function(v, len)
	-- Don't process continuations if the previous note wasn't as long...
	if v.pitch == 0xFF then return end
	v.length = len
	if v.pizzicato == 0 then
		v.ticksLeft = len+1 -- ticks
	else
		v.ticksLeft = PIZZICATO(v.octave) -- samplepoints
	end
end

Voice.setVolume = function(v, vol)
	v.volume = vol
	if v.volume < 0xFF then -- else no change
		-- Apply org volume curve transformation
		v.amplitude = VOLCURVE(v.volume / 255)
	end
end

Voice.setPanning = function(v, pan)
	v.panning = pan
	if v.panning < 0xFF then -- else no change; also, legit range is 0-13
		-- Apply org panning law
		v.balanceL, v.balanceR = PANLAW(v.panning / 13)
	end
end

Voice.render = function(v)
	-- When not to do anything.
	if v.disabled then return 0.0, 0.0 end
	if v.frequency == 0 or v.octave == 0 then return 0.0, 0.0 end
	if v.type == 'melodic' then
		if v.ticksLeft == 0 then
			return 0.0, 0.0
		end
	else 
		if v.currentOffset >= math.huge then
			return 0.0, 0.0
		end
	end

	-- Get samplepoint.
	local smp
	if v.interpolation == 'nearest' then
		smp = v.data:getSample(math.floor(v.currentOffset))
	elseif v.interpolation == 'linear' then
		-- TODO
	elseif v.interpolation == 'lanczos' then
		-- TODO
	end

	-- Increment offset
	if v.type == 'melodic' then
		v.offsetAccumulator = v.offsetAccumulator +
			((v.frequency * PERIODSIZE[v.octave]) / device.samplingRate) *
			(1 / SMPMULTIPLIER[v.octave])
		while v.offsetAccumulator >= 1 do
			v.currentOffset = (v.currentOffset + SMPINCREMENT[v.octave]) %
			v.data:getSampleCount()
			v.offsetAccumulator = v.offsetAccumulator - 1
		end
	else -- 'percussive'
		v.offsetAccumulator = v.offsetAccumulator + v.frequency
		while v.offsetAccumulator >= 1 do
			v.currentOffset = (v.currentOffset + 1)
			v.offsetAccumulator = v.offsetAccumulator - 1
		end
		if v.currentOffset >= v.data:getSampleCount() then
			v.currentOffset = math.huge
			v.ticksLeft = 0 -- drums are one-shot.
		end
	end

	-- Test fake overlap sound (simulated round-robin tail ends)
	-- This makes consecutive notes sound like in OrgMaker 2,
	-- but it is literally unimplemented in everything else.
	if v.type == 'melodic' then
		smp = (v.ticksLeft == v.length) and smp * 1.2 or smp
	end

	-- Adjust volume and panning
	smp  = smp * v.amplitude
	return smp * v.balanceL, smp * v.balanceR
end

local mtVoice = {__index = Voice}

Voice.new = function(type, instrument, finetune, pizzicato)
	local v = setmetatable({}, mtVoice)

	-- Processing related.
	v.disabled = false -- Whether or not the voice is processed.
	v.muted    = false -- Whether or not the voice output is muted.

	v.offsetAccumulator = 0.0
	v.currentOffset     = 0
	v.currentEvent      = 0 -- Needed because of how the data is stored.
	v.ticksLeft         = 0 -- Needed to count down until the end of an event.

	-- Per-event inputs.
	v.position      = 0x00000000 -- Not /really/ needed.
	v.pitch          = 0x00
	v.length        = 0x00
	v.volume        = 0x00
	v.panning       = 0x00

	-- Calculated values.
	v.pitchClass = 0
	v.octave     = 0
	v.frequency  = 0.0
	v.amplitude  = 0.0
	v.balanceL, v.balanceR = 0.0, 0.0

	-- Set only at song initialization.
	v.type          = type or 'melodic' -- 'melodic' or 'percussive'
	v.looping       = type == 'melodic' and true or false
	v.instrument    = instrument or 0
	v.finetune      = finetune or 1000
	v.pizzicato     = pizzicato or 0

	v.eventCount     = 0
	v.interpolation = 'nearest'

	if v.type == 'melodic' then
		-- Load in the specified waveform from wave100 file.
		local path = 'fmt/org/wave100'
		local file = love.filesystem.newFile(path)
		file:open('r')
		file:seek(v.instrument*256)
		local buffer = file:read(256)
		v.data = love.sound.newSoundData(
			256,
			device.samplingRate, -- doesn't matter.
			8, 
			1
		)
		local smp = 0
		for c in buffer:gmatch('.') do
			local b
			-- Convert from signed (two's complement).
			b = string.byte(c)
			b = b > 127 and -(256-b) or b
			b = b/256
			v.data:setSample(smp, b)
			smp = smp + 1
		end
	else
		-- Load in raw percussion data from separate files.
		if not DRUMKIT[v.instrument] then
			-- Fake sounddata containing one smp of silence for unsupported
			-- drums.
			v.data = love.sound.newSoundData(
				1,
				device.samplingRate, -- doesn't matter.
				8, 
				1
			)
		else
			local path = 'fmt/org/' .. DRUMKIT[v.instrument]
			local file = love.filesystem.newFile(path)
			file:open('r')
			local buffer = file:read()
			v.data = love.sound.newSoundData(
				#buffer,
				device.samplingRate, -- doesn't matter.
				8, 
				1
			)
			local smp = 0
			for c in buffer:gmatch('.') do
				local b
				-- Convert from unsigned.
				b = string.byte(c)
				b = b - 127
				b = b/128
				v.data:setSample(smp, b)
				smp = smp + 1
			end
		end
	end
	return v
end



-- The playroutine

local routine = {}



routine.load = function(mod)
	module = mod

	tickPeriod     = module.tickRate / 1000.0 -- seconds
	samplingPeriod = 1.0 / device.samplingRate

	-- Create and initialize voices.
	normalizer = 0.0
	voice = {}
	for t=0, 15 do
		voice[t] = Voice.new(
			t<8 and 'melodic' or 'percussive',
			module.track[t].instrument,
			module.track[t].finetune,
			module.track[t].pizzicato
		)

		-- Not strictly necessary for the voices to know about this one.
		voice[t].eventCount = module.track[t].eventCount

		if voice[t].eventCount > 0 then normalizer = normalizer + 1.0 end
	end
	if normalizer == 0.0 then normalizer = 1.0 end
	normRatio = math.sqrt(10.0^((normalizer-1.0)/10.0)) -- dB, probably.

	-- Start from the beginning of a song.
	tickAccumulator = 0.0
	currentTick     = 0   -- Ticks in the whole piece
	currentBeatTick = 0   -- Tick in a Beat
	currentBeat     = 0   -- Beats in the whole piece
	currentBarBeat  = 0   -- Beat in a Bar
	currentBar      = 0   -- Bars in the whole piece

	-- Step the timer, since startup may spike the dt, which
	-- is bad news for any timer-sensitive mode.
	love.timer.step()
end



routine.process = function()
	-- Process tracks
	for v=0, 15 do
		if not voice[v].disabled then
			local track = module.event[v]
			local voice = voice[v]
			local event = track[voice.currentEvent]
			-- Process next event.
			if event and event.position == currentTick then
				voice.position = event.position
				voice:setPitch(event.pitch)
				voice:setLength(event.length)
				voice:setVolume(event.volume)
				voice:setPanning(event.panning)
				voice.currentEvent = voice.currentEvent + 1
			end
			-- Sustained mode length processing.
			if voice.pizzicato == 0 then
				if voice.ticksLeft > 0 then
					voice.ticksLeft = voice.ticksLeft - 1
				end
			end
		end
	end
end



routine.step = function()
	-- Advance playback position.
	currentTick = currentTick + 1

	-- Loop processing
	if currentTick == module.loopEnd then
		currentTick = module.loopStart
		-- Set event counters to precalculated indices that are the first ones
		-- after the loop's starting point.
		for v=0, 15 do
			voice[v].currentEvent = module.event[v].firstLoopEvent
		end
	end

	-- Graphical niceties.
	currentBeatTick = currentTick % module.tickPerBeat
	currentBeat     = math.floor(currentTick / module.tickPerBeat)
	currentBarBeat  = currentBeat % module.beatPerBar
	currentBar      = math.floor(currentBeat / module.beatPerBar)
end



routine.render = function(dt)
	-- Rendermode
	if device.renderMode == 'CPU' then
		-- We could check the buffer state here, like below, but that would
		-- swap underruns with rendering slowdowns.
		samplesToMix = math.min(
			math.floor(dt / samplingPeriod)
			,buffer.data:getSampleCount()
		)

	elseif device.renderMode == 'Buffer' then
		if source.queue:getFreeBufferCount() == 0 then return end
		samplesToMix = math.min(
			math.floor(tickPeriod / samplingPeriod),
			buffer.data:getSampleCount()
		)
	end

	if samplesToMix == 0 then return end

	for i=0, samplesToMix-1 do
		local smpL, smpR = 0.0, 0.0
		for v=0, 15 do
			local L, R = 0.0, 0.0

			-- Render each voice, and mix them together.
			if not voice[v].muted then
				L, R = voice[v]:render()
				smpL, smpR = smpL + L, smpR + R
			end

			if not voice[v].disabled then
				-- Pizzicato mode length processing.
				if voice[v].pizzicato == 1 then
					voice[v].ticksLeft = voice[v].ticksLeft - 1 -- samplepoints
					if voice[v].ticksLeft == 0 and voice[v].type ~= 'melodic'
					then
						-- TODO: Figure out whether or not non-sustained
						--       melodics should be retriggered like this too.
						voice[v].currentOffset = 0
					end
				end
				
			end
		end

		-- Normalize output.
		smpL, smpR = smpL / normRatio, smpR / normRatio

		-- Write samples to buffer.
		buffer.data:setSample(buffer.offset  , smpL)
		buffer.data:setSample(buffer.offset+1, smpR)

		-- Advance buffer position, if it's full, queue it and reset buffer.
		buffer.offset = buffer.offset + 2
		if buffer.offset >= buffer.data:getSampleCount() *
			buffer.data:getChannels()
		then
			buffer.offset = 0
			source.queue:queue(buffer.data)
			source.queue:play()
		end

		-- This tracking mode should be the most precise, since it's updated
		-- each time an smp (or two, because stereo...) gets rendered.
		if device.trackingMode == 'Buffer' then
			tickAccumulator = tickAccumulator + samplingPeriod
			if tickAccumulator >= tickPeriod then
				-- If a tick was rendered fully, process the next tick, and
				-- advance the playback position.
				routine.process()
				routine.step()
				tickAccumulator = tickAccumulator - tickPeriod
			end
		end
	end
end



routine.update = function(dt)
	-- Render sound.
	routine.render(dt)

	-- This one's less precise, but it doesn't consume as much processing time.
	if device.trackingMode == 'CPU' then
		tickAccumulator = tickAccumulator + dt
		if tickAccumulator >= tickPeriod then
			-- If a tick was rendered fully, process the next tick, and advance
			-- the playback position.
			routine.process()
			routine.step()
			tickAccumulator = tickAccumulator - tickPeriod
		end
	end
end



routine.draw = function()
	-- TODO: Use window library for testing and benchmark purposes.
	love.graphics.setBackgroundColor(0.2,0.2,0.3)

	-- Playback tracking related "window"
	love.graphics.setColor(0.1,0.1,0.2)
	love.graphics.rectangle('fill',0,0,30*8,108)
	love.graphics.setColor(1,1,1)
	love.graphics.print(("tick:  %8X"):format(currentTick),0,0)
	love.graphics.print(("tock:       %3d"):format(currentBeatTick),0,12)
	love.graphics.print(("step:    %6d"):format(currentBeat),0,24)
	love.graphics.print(("beat:       %3d"):format(currentBarBeat),0,36)
	love.graphics.print(("Bar:       %4d"):format(currentBar),0,48)
	love.graphics.print(("t/b:        %3d"):format(module.tickPerBeat),0,60)
	love.graphics.print(("b/B:        %3d"):format(module.beatPerBar),0,72)
	love.graphics.print(("tempo:    %5d BPM"):format(module.tempo),0,84)
	love.graphics.print(("events:    %4X"):format(module.eventSum),0,96)

	-- Realtime "voice properities" "matrix" "window"
	love.graphics.push()
	love.graphics.translate(31*8,0)
	love.graphics.setColor(0.1,0.1,0.2)
	love.graphics.rectangle('fill',0,0,49*8,17*12)
	love.graphics.setColor(1,1,1)
	love.graphics.print("fine in pi indx ncnt position nt ln vl pn tc offs",
		0, 0)
	for v=0, 15 do
		local stats = {voice[v]:getStatistics()}
		love.graphics.print(
			("%4X %2X %2X %4X %4X %8X %2X %2X %2X %2X %2X %4X"):format(
			unpack(stats)), 0, (v+1) * 12
		)
	end
	love.graphics.pop()
end



do
	local voices = {
		'1','2','3','4','5','6','7','8','q','w','e','r','t','y','u','i'
	}
	local ivoices = {}; for i=1,#voices do ivoices[voices[i]] = i end
	routine.keypressed = function(k,s)
		if ivoices[s] then
			voice[ivoices[s]-1].muted = not voice[ivoices[s]-1].muted
		end
	end
end



--------------
return routine