-- Basic org playroutine skellington
-- by zorg @ 2017 § ISC

-- See doc/orgspecs_v1_1.txt for references.

-------------------------------

-- Audio Parameters
-- References: N/A

local Audio = {}
Audio.samplingRate = 44100             -- Hz (1/seconds)
Audio.bitDepth     =     8             -- bits
Audio.channelCount =     2             -- channels
-------------------------------

-- Sound Buffer
-- References: Audio Parameters

local Buffer = {}
Buffer.offset =    0                   -- samplepoints
Buffer.size   = 1024                   -- samplepoints
Buffer.data   = love.sound.newSoundData(
					Buffer.size,
					Audio.samplingRate, 
					Audio.bitDepth, 
					Audio.channelCount
					)                  -- SoundData
-------------------------------

-- Queuable Source
-- References: Audio Parameters

local QSource = love.audio.newQueueableSource(
						Audio.samplingRate,
						Audio.bitDepth,
						Audio.channelCount
						)
-------------------------------

-- Module
-- References: N/A (External)

local Module

-------------------------------

-- Constants

local drumkit = {
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

local smpIncrement  = {   1,  1,  2,  4, 8,16,32,64}
local smpMultiplier = {   4,  2,  2,  2, 2, 2, 2, 2}
local periodSize    = {1024,512,256,128,64,32,16, 8}
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
-- Frequency(inst, pc, oct) = (pitchClass[pc] + (voice[inst].finetune - 1000)) / periodSize[oct]
local volCurve = function(v) return 10^(v-1) end
local panLaw   = function(p)
	local l = (p >= 0.0 and p <= 0.5) and 1.0 or 20^(1-2*p)
	local r = (p >= 0.5 and p <= 1.0) and 1.0 or 20^(2*p-1)
	return l, r
end
local pizzicato  = function(o) return o*4 end -- wave periods for octaves 1-8 if pizzicato is enabled for a track... might not be correct.
-- alternative pizzicato note lengths: 1024 / (frequency / sampling rate)

-------------------------------

-- Instruments

-- We'll need to load in the necessary ones, as dictated by the data read in from the module... though the voices should trigger this.
-- Or we could just waste 25600+61644 bytes to statically store all the instrument data; if this wasn't just a player, we should do just that.

-------------------------------

-- Voices

local Voice = {}

Voice.getStatistics = function(v)
	return v.finetune, v.instrument, v.pizzicato,
		v.currentEvent, v.noteCount,
		v.position,
		v.note, v.length, v.volume, v.panning,
		v.ticksLeft, v.currentOffset
end

Voice.setNote = function(v, note)
	v.note = note
	if v.note < 0xFF then -- else no change
		v.pitchClass = (v.note % 12)+1
		v.octave     = math.floor(v.note / 12)+1
		v.frequency  = (pitchClass[v.pitchClass] + (v.finetune - 1000)) / periodSize[v.octave]
		if not v.type == 'melodic' then
			v.currentOffset = 0
		end
	end
end

Voice.setLength = function(v, len)
	-- Don't process continuations if the previous note wasn't as long...
	if v.note == 0xFF and v.ticksLeft == 0 then return end
	-- if the voice is pizzicated, we need to set the lengths a bit differently
	if v.pizzicato == 0 then
		v.ticksLeft = len -- ticks...
	else
		v.ticksLeft = pizzicato(v.octave) -- samplepoints... not the best solution, but it should work.
	end
end

Voice.setVolume = function(v, vol)
	v.volume = vol
	if v.volume < 0xFF then -- else no change
		-- Apply org volume curve transformation
		v.amplitude = volCurve(v.volume / 255)
	end
end

Voice.setPanning = function(v, pan)
	v.panning = pan
	if v.panning < 0xFF then -- else no change; also, legit range is 0-13
		-- Apply org panning law
		v.balanceL, v.balanceR = panLaw(v.panning / 13)
	end
end

Voice.process = function(v)
	if not v.processed  then return 0.0, 0.0 end
	if v.frequency == 0 then return 0.0, 0.0 end
	if v.octave    == 0 then return 0.0, 0.0 end
	if v.ticksLeft == 0 then return 0.0, 0.0 end
	local smp
	-- Get samplepoint
	if v.interpolation == 'nearest' then
		smp = v.data:getSample(math.floor(v.currentOffset))
	elseif v.interpolation == 'linear' then
		-- TODO
	elseif v.interpolation == 'lanczos' then
		-- TODO
	end
	-- Increment offset
	--v.phaseAccum = v.phaseAccum + (v.frequency / Audio.samplingRate) -- smp probably
	
	-- freq * oct-based-periodsize => correct point frequency
	-- / sampling rate => smp playback rate ratio
	if v.type == 'melodic' then

		v.offsetAccum = v.offsetAccum + ((v.frequency * periodSize[v.octave]) / Audio.samplingRate) * (1 / smpMultiplier[v.octave])

		while v.offsetAccum >= 1 do
			v.currentOffset = (v.currentOffset + smpIncrement[v.octave]) % v.data:getSampleCount()
			v.offsetAccum = v.offsetAccum - 1
		end

	else

		v.offsetAccum = v.offsetAccum + (((v.frequency / 2) * periodSize[v.octave]) / Audio.samplingRate) * (1 / smpMultiplier[v.octave])
		
		while v.offsetAccum >= 1 do
			v.currentOffset = (v.currentOffset + smpIncrement[v.octave])
			v.offsetAccum = v.offsetAccum - 1
		end

		--if v.currentOffset + math.floor(v.offsetAccum)*smpIncrement[v.octave] > v.data:getSampleCount() then
		if v.currentOffset >= v.data:getSampleCount() then
			v.currentOffset = 0
			v.ticksLeft = 0 -- drums are one-shot.
		end
	end

	-- Adjust volume and panning
	smp = smp * v.amplitude * (v.type == 'melodic' and 0.20 or 1.0)
	return smp * v.balanceL, smp * v.balanceR
end

local mtVoice = {__index = Voice}

local newVoice = function(vtype, instr, finetune, pi)
	local v = setmetatable({},mtVoice)

	-- Processing related.
	v.processed = true  -- whether the voice should be processed or not
	v.muted     = false -- whether the output of the voice should be silenced or not

	--v.phaseAccum    = 0.0
	v.offsetAccum   = 0
	v.currentOffset = 0
	v.currentEvent  = 0 -- Needed because of how the data is stored
	v.ticksLeft     = 0 -- Needed to count down until the note should stop playing

	-- May be set per-event.
	v.position      = 0 -- not REALLY needed
	v.note          = 0
	v.length        = 0
	v.volume        = 0
	v.panning       = 0

	-- Calculated values
	v.pitchClass = 0
	v.octave     = 0
	v.frequency  = 0.0
	v.amplitude  = 0.0
	v.balanceL, v.balanceR = 0.0, 0.0

	-- Set only at the beginning.
	v.type          = vtype -- 'melodic' or 'percussive'
	v.looping       = v.type == 'melodic' and true or false
	v.instrument    = instr or 0
	v.finetune      = finetune or 1000
	v.pizzicato     = pi or 0

	v.noteCount     = 0
	v.interpolation = 'nearest'

	if v.type == 'melodic' then
		-- Load in necessary waveform points from wave100 file.
		local path = 'fmt/org/wave100'
		local file = love.filesystem.newFile(path)
		file:open('r')
		file:seek(v.instrument*256)
		local buffer = file:read(256)
		v.data = love.sound.newSoundData(
			256,
			Audio.samplingRate, -- doesn't matter.
			8, 
			1
		)
		local smp = 0
		for c in buffer:gmatch('.') do
			-- Signed?
			local b = (127 - string.byte(c))/128
			--local b = (string:byte(c) - 127)/128
			v.data:setSample(smp, b)
			smp = smp + 1
		end
	else
		-- Load in raw percussion data from separate files.
		if not drumkit[v.instrument] then
			-- Fake sounddata containing one smp of silence...
			v.data = love.sound.newSoundData(
				1,
				Audio.samplingRate, -- doesn't matter.
				8, 
				1
			)
		else
			local path = 'fmt/org/' .. drumkit[v.instrument]
			local file = love.filesystem.newFile(path)
			file:open('r')
			local buffer = file:read()
			v.data = love.sound.newSoundData(
				#buffer,
				Audio.samplingRate, -- doesn't matter.
				8, 
				1
			)
			local smp = 0
			for c in buffer:gmatch('.') do
				-- Unsigned?
				local b = (string.byte(c) - 127)/128
				--local b = (127 - string:byte(c))/128
				v.data:setSample(smp, b)
				smp = smp + 1
			end
		end
	end

	return v
end

-------------------------------

-- Runtime
-- References: Audio Parameters

--[[
local timeSigNumer                           -- rows per beat (For actual BPM calculation)
local timeSigDenom                           -- row type (note lengths, for "midi")

local actualBPM                              -- beats per minute (This one is the real deal.)

local cpuTime        = 0.0                   -- seconds (based on love.timer)
local bufferTime     = 0.0                   -- seconds (based on processed smp-s)

local trackingMode   = 'cpu'              -- cpu or buffer based playback cursor positioning
local samplesMixed   = 0                     -- smp (samples mixed current frame)
local samplesTotal   = 0                     -- smp (samples mixed total)
--]]

local routine = {}

-- Player variables --

routine.samplingPeriod = 1 / Audio.samplingRate

-- Playback tracking
--routine.tickPeriod
--routine.tickAccum
--routine.currentTick
--routine.currentStep
--routine.currentBeat
--routine.currentMeasure

-- Available modes: "nearest", "linear", "lanczos" (sinc) resampling.
routine.interpolation = 'nearest'

-- Table holding all voices
routine.voices = {}


routine.load = function(mod)

	-- Get a local handle for the song.
	Module = mod

	-- Set timings.
	routine.tickPeriod = Module.tempo / 1000 -- ms, converted to seconds

	-- Set up volume normalizer.
	routine.normalizer = 0.0

	-- Create all voices for all tracks.
	for v=0, 15 do
		local trck = Module.instruments[v]
		routine.voices[v] = newVoice(
			v<8 and 'melodic' or 'percussive',
			trck.instrument,
			trck.finetune,
			trck.pizzicato
		)
		routine.voices[v].interpolation = routine.interpolation
		routine.voices[v].noteCount = trck.noteCount
		if trck.noteCount > 0 then
			routine.normalizer = routine.normalizer + 1.0
		end
	end

	if routine.normalizer == 0.0 then routine.normalizer = 1.0 end

	-- Start from the beginning of the song.
	routine.tickAccum      = 0.0
	routine.currentTick    = 0
	routine.currentStep    = 0
	routine.currentBeat    = 0
	routine.currentMeasure = 0

	-- Step the timer since startup may spike the dt, which
	-- is bad news for any time-sensitive code.
	love.timer.step()

end

routine.update = function(dt)

	routine.tickAccum = routine.tickAccum + dt

	if routine.tickAccum >= routine.tickPeriod then

		routine.tickAccum = routine.tickAccum - routine.tickPeriod

		-- Process tracks.
		for v=0, 15 do
			local track = Module.song[v]
			local voice = routine.voices[v]
			local event = track[voice.currentEvent]
			if event and event.position == routine.currentTick  then
				-- set data
				voice.position = event.position
				voice:setNote(event.pitch)
				voice:setLength(event.length)
				voice:setVolume(event.volume)
				voice:setPanning(event.panning)
				-- increment event ctr
				voice.currentEvent = voice.currentEvent + 1
			else
				-- decrease the length of the note if one's playing
				-- but only if the track is not set to pizzicato mode
				-- since that's set in the rendering code...
				if voice.pizzicato == 0 then
					if voice.ticksLeft > 0 then
						voice.ticksLeft = voice.ticksLeft - 1
					end
					if voice.ticksLeft == 0 and voice.type ~= 'melodic' then
						voice.currentOffset = 0
					end
				end
			end
		end

		-- Advance playback position.
		routine.currentTick = routine.currentTick + 1
		if routine.currentTick == Module.loopEnd then
			routine.currentTick = Module.loopStart
			-- we should reset the event counters here:
			-- this is involved, since we need to find the first event for each track that
			-- starts on or after the loop point.
			for v=0, 15 do
				local voice = routine.voices[v]
				if voice.noteCount > 0 then
					local event = 0
					while event <= Module.loopEnd do
						if Module.song[v][event].position >= Module.loopStart then
							break
						end
						event = event + 1
					end
					voice.currentEvent = event
				end
			end
		end
		-- This is only used for graphical output.
		routine.currentStep = routine.currentTick % Module.beatsPerStep -- naming is stupid, refactor later.
		routine.currentBeat = math.floor(routine.currentTick / Module.beatsPerStep % Module.stepsPerBar)
		routine.currentMeasure = math.floor(routine.currentTick / (Module.beatsPerStep * Module.stepsPerBar))

	end

	-- Render samplepoint(s).

	local samplesToMix = math.ceil(dt / routine.samplingPeriod)
	for i = 0, samplesToMix - 1 do
		-- Render each voice, and mix them together
		-- |output| <= 1.0 * N -> Normalize to [-1,1]
		local smpL, smpR = 0.0, 0.0
		for v = 0, 15 do
			local L, R = 0.0, 0.0
			if not routine.voices[v].muted then
				L, R = routine.voices[v]:process()
				-- If pizzicato mode is on for the track, then 
				-- decrease note length accordingly...
				if routine.voices[v].pizzicato == 1 then
					routine.voices[v].ticksLeft = routine.voices[v].ticksLeft - 1 -- samplepoints
					if routine.voices[v].ticksLeft == 0 and routine.voices[v].type ~= 'melodic' then
						routine.voices[v].currentOffset = 0
					end
				end
				smpL, smpR = smpL + L, smpR + (R or 0.0)
			end
		end
		smpL, smpR = smpL / routine.normalizer, smpR / routine.normalizer

		Buffer.data:setSample(Buffer.offset  , smpL)
		Buffer.data:setSample(Buffer.offset+1, smpR)
		-- Advance buffer pointer, flush buffer if full.
		Buffer.offset = Buffer.offset + 2
		if Buffer.offset >= Buffer.data:getSampleCount()*Buffer.data:getChannels() then
			Buffer.offset = 0
			QSource:queue(Buffer.data)
			QSource:play() -- For safety.
		end
	end
end

routine.draw = function()

	love.graphics.setBackgroundColor(0.2,0.2,0.3)

	love.graphics.setColor(0.1,0.1,0.2)
	love.graphics.rectangle('fill',0,0,10*8,48)

	love.graphics.setColor(1,1,1)
	love.graphics.print(("tick: %d"):format(routine.currentTick),0,0)
	love.graphics.print(("step: %d"):format(routine.currentStep),0,12)
	love.graphics.print(("beat: %d"):format(routine.currentBeat),0,24)
	love.graphics.print(("meas: %d"):format(routine.currentMeasure),0,36)

	-- Experimental realtime "voice properities" "matrix"
	love.graphics.push()
	love.graphics.translate(11*8,0)
	love.graphics.setColor(0.1,0.1,0.2)
	love.graphics.rectangle('fill',0,0,48*8,17*12)
	love.graphics.setColor(1,1,1)
	love.graphics.print("fine in pi indx ncnt position nt ln vl pn tc offs",0,0)
	for v=0, 15 do
		local stats = {routine.voices[v]:getStatistics()}
		love.graphics.print(("%4X %2X %2X %4X %4X %8X %2X %2X %2X %2X %2X %4X"):format(unpack(stats)),0,(v+1)*12)
	end
	love.graphics.pop()

end

love.keypressed = function(k,s)
	local voices = {'1','2','3','4','5','6','7','8','q','w','e','r','t','y','u','i'}
	local ivoices = {}; for i=1,#voices do ivoices[voices[i]] = i end
	if ivoices[s] then
		routine.voices[ivoices[s]-1].muted = not routine.voices[ivoices[s]-1].muted
	end
end

--------------
return routine