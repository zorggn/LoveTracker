-- Scream Tracker 3 "S3M" playroutine
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

local tickPeriod, samplingPeriod, midiPPQ, actualTempo
local timeSigNumer, timeSigDenom

--
local normalizer, normRatio, samplesToMix
local interpolation

local tickAccumulator, currentTick, currentRow, currentOrder, currentPattern
local time
local smoothScrolling

local speed, tempo
local loopRow, loopCnt, patternLoop, filterSet
local positionJump, patternBreak, patternDelay, glissando, globalVolume
local vibratoWaveform, tremoloWaveform

-- Constants

-- TODO: do dim. analysis on these numbers so we can reason about them better.

local ARPEGGIOPERIOD = 1 / 50 -- Hz; ST3's arp isn't tied to the speed...

local C4SPEEDFINETUNES = {
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

local DEFAULTC4SPEED = C4SPEEDFINETUNES[ 0x08 ]

-- Hz = DEFAULTC4SPEED * C4PERIOD / NOTEPERIOD

local OCTAVE4PERIOD = {
	1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 907
}

local NOTEPERIOD = {}
for octave = 0, 10 do for note = 1, 12 do
		NOTEPERIOD[octave*12+(note-1)] =
			(16 * (OCTAVE4PERIOD[note] / 2^octave))
end end

local BASECLOCK  = DEFAULTC4SPEED * OCTAVE4PERIOD[1] -- C4
local FIXEDCLOCK = BASECLOCK / device.samplingRate

local FIXTIMING = function(tempo, speed, tsn, tsd)
	local tick =  2.5 / tempo
	local ppq  =  speed *  tsn * (4.0 / tsd)
	local tempo = 60.0 / (tick * ppq)
	return tick, ppq, tempo
end

-- Voice objects

local Voice = {}

Voice.getStatistics = function(v)
	-- TODO: Used for matrix display
	--[[
A A A A B B C D -- notePeriod n noteDelayTicks noteCutTicks
E E F F G G H H -- i v c d
I I I I J J J J -- glisPeriod instPeriod
K K L L M M 0 0 -- fxSlotGeneric fxSlotPortamento fxSlotVibrato
O P Q Q N N R 0 -- tremorOnTicks tremorOffTicks tremorIndex arpOffsets arpIndex
V V W W X X X X -- currVolume currPanning currOffset
Y Y Y Y Z Z Z Z -- sample.c4speed sample.length
@ @ @ @ & & & & -- sample.loopStart sample.loopEnd
	--]]
	return v.notePeriod, v.n, v.noteDelayTicks, v.noteCutTicks,
		v.i, v.v, v.c, v.d,
		v.glisPeriod, v.instPeriod, math.floor(v.currOffset)
end

Voice.setNote = function(v, note)
	v.n_ = note
end

Voice.setInstrument = function(v, instrument)
	v.i_ = instrument
end

Voice.setVolume = function(v, volume)
	v.v_ = volume
end

Voice.setEffect = function(v, effectCommand, effectData)
	v.c_, v.d_ = effectCommand, effectData
end

Voice.setPeriod = function(v, pitch)
	-- Voice.process calls this; set raw note period, and the fixed value
	-- modified by the instrument c4speed.
	if pitch == -1 then
		v.notePeriod = 0
		v.instPeriod = 0
		return
	end
	v.notePeriod = NOTEPERIOD[pitch]
	if v.instrument then
		v.instPeriod = v.notePeriod * (DEFAULTC4SPEED / v.instrument.c4speed)
	end
end

Voice.process = function(v, currentTick)
	local N, I, V, C, D = false, false, false, false, false
	local Dx, Dy

	-- Handle inputs
	if v.n_ then
		if v.n_ == 255 then
			-- Note continue
			N = false
		elseif v.n_ == 254 then
			-- Note cut
			v.notePeriod = 0
			N = -1
		elseif v.n_ < 254 then
			-- Note trigger
			N = math.floor(v.n_ / 0x10) * 12 + (v.n_ % 0x10)
		end
		v.n = v.n_
	end

	if v.i_ then
		if v.i_ == 0 then
			-- Instrument undefined
			I = false
		elseif v.i_ > 0 then
			-- Instrument defined
			I = v.i_ - 1
		end
		v.i = v.i_
	end

	if v.v_ then
		V = v.v_
		v.v = v.v_
	end

	if v.c_ then
		v.currEffect = C
		v.c, v.d = v.c_, v.d_
	else
		v.currEffect = false
		v.c, v.d = 0, 0
	end
	C = string.char(v.c + 0x40)
	D = v.d
	Dx = math.floor(D / 16)
	Dy =            D % 16

	if currentTick == 0 then
		-- Combinatorics...
		if         N and     I then
			-- Apply instrument
			v.instrument = module.sample[I]
			if C ~= 'G' then
				-- Set note and reset offset to 0.
				v:setPeriod(N)
				v.currOffset = 0
			end
			-- Handle volume
			if V then
				v.currVolume = V / 0x40
			else
				if v.instrument then
					v.currVolume = v.instrument.volume / 0x40
				end
			end
		elseif     N and not I then
			if C ~= 'G' then
				-- Set note and reset offset to 0.
				v:setPeriod(N)
				v.currOffset = 0
			end
			-- Handle volume
			if V then
				v.currVolume = V / 0x40
			else
				-- Do nothing here.
			end
		elseif not N and     I then
			-- Apply instrument
			v.instrument = module.sample[I]
			-- Handle volume
			if V then
				v.currVolume = V / 0x40
			else
				if v.instrument then
					v.currVolume = v.instrument.volume / 0x40
				end
			end
		elseif not N and not I then
			-- Handle volume
			if V then
				v.currVolume = V / 0x40
			else
				-- Do nothing here.
			end
		end
	end

	if currentTick == 0 then
		-- T0 Effects.
		if     C == 'D' then
			-- Volume SLide
			if D > 0x00 then
				v.fxSlotGeneric = D
			end
			local x = math.floor(v.fxSlotGeneric / 0x10)
			local y =            v.fxSlotGeneric % 0x10
			-- If we have a fine slide, then process it here.
			-- Note that in the case of DFF, we prioritize by fine sliding up.
			if     y == 0xF then
				-- up x units
				v.currVolume = math.min(1.0, v.currVolume + (x / 0x40))
			elseif x == 0xF then
				-- down y untis
				v.currVolume = math.max(0.0, v.currVolume - (y / 0x40))
			end
			-- "Fast Volume Slide" bug handling
			if module.fastVolSlides then
				if     y == 0x0 then
					-- up x units
					v.currVolume = math.min(1.0, v.currVolume + (x / 0x40))
				elseif x == 0x0 then
					-- down y units
					v.currVolume = math.max(0.0, v.currVolume - (y / 0x40))
				end
			end
		elseif C == 'E' then
			-- Portamento Down
			if D > 0x00 then
				v.fxSlotPortamento = D
			end
			local x = math.floor(v.fxSlotPortamento / 0x10)
			local y =            v.fxSlotPortamento % 0x10
			if     x == 0xF then
				-- Fine porta
				v.instPeriod = v.instPeriod + y * 4
			elseif x == 0xE then
				-- Extra fine porta
				v.instPeriod = v.instPeriod + y
			end
			-- TODO: Period Clamping...
		elseif C == 'F' then
			-- Portamento Up
			if D > 0x00 then
				v.fxSlotPortamento = D
			end
			local x = math.floor(v.fxSlotPortamento / 0x10)
			local y =            v.fxSlotPortamento % 0x10
			if     x == 0xF then
				-- Fine porta
				v.instPeriod = v.instPeriod - y * 4
			elseif x == 0xE then
				-- Extra fine porta
				v.instPeriod = v.instPeriod - y
			end
			-- TODO: Period Clamping...
		elseif C == 'G' then
			-- Tone portamento
			if D > 0x00 then
				v.fxSlotPortamento = D
			end
			if N and v.instrument then
				v.glisPeriod = NOTEPERIOD[N] *
					(DEFAULTC4SPEED / v.instrument.c4speed)
			end
		elseif C == 'O' then
			-- Set Offset
			v.fxSlotGeneric = D
			v.fxSetOffset   = D * 0x100
		end
	else 
		-- Tn Effects.
		if     C == 'D' then
			local x = math.floor(v.fxSlotGeneric / 0x10)
			local y =            v.fxSlotGeneric % 0x10
			if     y == 0x0 then
				-- up x units
				v.currVolume = math.min(1.0, v.currVolume + (x / 0x40))
			elseif x == 0x0 then
				-- down y units
				v.currVolume = math.max(0.0, v.currVolume - (y / 0x40))
			end
		elseif C == 'E' then
			local x = math.floor(v.fxSlotPortamento / 0x10)
			if x < 0xE then
				v.instPeriod = v.instPeriod + v.fxSlotPortamento * 4
			end
			-- TODO: Period Clamping...
		elseif C == 'F' then
			local x = math.floor(v.fxSlotPortamento / 0x10)
			if x < 0xE then
				v.instPeriod = v.instPeriod - v.fxSlotPortamento * 4
			end
			-- TODO: Period Clamping...
		elseif C == 'G' then
			if not glissando then
				if     v.instPeriod > v.glisPeriod then
					v.instPeriod = v.instPeriod - v.fxSlotPortamento * 4
					if v.instPeriod < v.glisPeriod then
						v.instPeriod = v.glisPeriod
					end
				elseif v.instPeriod < v.glisPeriod then
					v.instPeriod = v.instPeriod + v.fxSlotPortamento * 4
					if v.instPeriod > v.glisPeriod then
						v.instPeriod = v.glisPeriod
					end
				end
			else
				-- TODO: Implement semitone-glissando.
			end
		end
	end
end

Voice.render = function(v)
	if v.instPeriod == 0 then return 0.0, 0.0 end
	if not v.instrument or v.instrument.type == 0 then return 0.0, 0.0 end

	local smpL, smpR = 0.0, 0.0

	if v.instrument.type == 1 then
		-- Sampler.
		v.currOffset = v.currOffset + (FIXEDCLOCK / v.instPeriod)

		if v.fxSetOffset > 0 then
			-- Add setOffset parameter.
			v.currOffset = v.currOffset + v.fxSetOffset
			v.fxSetOffset = 0
		end

		if v.instrument.looped then
			local addend = v.currOffset - v.instrument.loopEnd
			if addend >= 0 then
				v.currOffset = v.instrument.loopStart + addend
			end
		else
			if v.currOffset > v.instrument.data:getSampleCount() *
				v.instrument.data:getChannels()
			then
				v.currOffset = 0.0
				v.instPeriod = 0 -- Only play the sample once.
				return 0.0, 0.0
			end
		end

		v.currOffset = v.currOffset % (v.instrument.data:getSampleCount() *
			v.instrument.data:getChannels())

		-- Interpolation
		if interpolation == 'nearest' then
			-- 0th order interpolation: nearest neighbour (piecewise constant)
			if v.instrument.channelCount == 1 then
				local p = math.floor(v.currOffset)
				smpL = v.instrument.data:getSample(p)
				smpR = smpL
			else
				-- Stereo is not standard ST3, but implementable.
				local p = math.floor(v.currOffset)
				p = p % 2 == 1 and p - 1 or p
				smpL = v.instrument.data:getSample(p)
				smpR = v.instrument.data:getSample(p + 1)
			end
		else
			-- TODO: Other methods.
		end

		smpL = smpL * v.currVolume * (1.0 - v.currPanning)
		smpR = smpR * v.currVolume *        v.currPanning
		return smpL, smpR

	elseif v.instrument.type == 2 then
		-- TODO: AdLib melodics.
	end
end

local mtVoice = {__index = Voice}

Voice.new = function(pan)
	local v = setmetatable({}, mtVoice)

	-- Processing related.
	v.disabled = false -- Whether or not the voice is processed.
	v.muted    = false -- Whether or not the voice output is muted.

	-- Per-event inputs.
	v.n,  v.i,  v.v,  v.c,  v.d  = 0x00, 0x00, 0x00, 0x00, 0x00 -- Curr.
	v.n_, v.i_, v.v_, v.c_, v.d_ = 0x00, 0x00, 0x00, 0x00, 0x00 -- Temp.

	-- Calculated values.
	v.instrument       = false  -- Reference to the current instrument.
	v.notePeriod       = 0x0000 -- Base period value as taken from note data.
	v.instPeriod       = 0x0000 -- True period value calc.-ed w/ the current instrument.
	v.glisPeriod       = 0x0000 -- Final (true) period value of Gxx glissando effects.
	v.currOffset       = 0.0    -- Current sample offset. (floored -> matrix displayable)
	v.arpIndex         = 0x0    -- Running index for arpeggio effect.
	v.arpOffset1       = 0x0    -- Arpeggio offsets.
	v.arpOffset2       = 0x0    -- -"-
	v.tremorIndex      = 0x00   -- Running index for tremor effect.
	v.tremorOnTicks    = 0x0    -- Ticks while sound is unmuted.
	v.tremorOffTicks   = 0x0    -- Ticks while sound is muted.
	v.currVolume       = 0.0    -- Current volume.
	v.currPanning      = pan/0xF-- Current panning.
	v.noteDelayTicks   = 0x0    -- Ticks to delay note onsets.
	v.noteCutTicks     = 0x0    -- Ticks to cut note sound after.

	-- Emulate ST3 limited effect memory.
	v.currEffect       = false  -- Current effect in effect.
	v.fxSlotGeneric    = 0x00   -- Generic effect parameter slot.
	v.fxSlotPortamento = 0x00   -- Portamento effect parameter slot.
	v.fxSlotVibrato    = 0x00   -- Vibrato effect parameter slot.

	-- These are so that we don't recalculate everything in :render().
	v.fxSetOffset      = 0     -- Oxx setOffset


	return v
end

-- The playroutine

local routine = {}



routine.load = function(mod)
	module = mod

	time = 0.0
	samplesToMix = 0

	loopRow, loopCnt = {}, {}
	for ch = 0, module.channelCount-1 do
		loopRow[ch] = 0
		loopCnt[ch] = 0 
	end
	patternLoop = false
	filterSet = false

	interpolation = 'nearest'
	smoothScrolling = true

	positionJump, patternBreak, patternDelay = false, false, 0
	glissando, globalVolume = false, module.globalVolume
	vibratoWaveform, tremoloWaveform = 0, 0 -- Sine by default

	timeSigNumer, timeSigDenom = 4, 4
	speed = module.initialSpeed
	tempo = module.initialTempo

	tickPeriod, midiPPQ, actualTempo = FIXTIMING(
		tempo, speed, timeSigNumer, timeSigDenom)

	samplingPeriod = 1.0 / device.samplingRate

	voice = {}
	for ch=0, 31 do --module.channelCount-1 do
		if module.channel[ch].map then
			voice[module.channel[ch].map] = Voice.new(module.channel[ch].pan)
		end
		--voice[ch] = Voice.new(module.channel[ch].pan)
	end
	normalizer = module.channelCount
	normRatio = math.sqrt(10.0^((normalizer-1.0)/10.0)) -- dB, probably.

	tickAccumulator = 0.0
	currentTick     = 0
	currentRow      = 0
	currentOrder    = 0
	currentPattern  = module.order[currentOrder]

	love.timer.step()
end



routine.process = function()
	-- Process tracks
	if currentPattern < 254 then
		-- Reverse-iteration is needed to correctly process some effects.
		for ch = module.channelCount-1, 0, -1 do
			local cell = module.pattern[currentPattern][currentRow][ch]
			-- Set cell data for voices.
			voice[ch]:setNote(cell.note)
			voice[ch]:setInstrument(cell.instrument)
			voice[ch]:setVolume(cell.volume)
			voice[ch]:setEffect(cell.effectCommand, cell.effectData)
			-- After we set everything in the voice, process it.
			voice[ch]:process(currentTick)
			-- Handle playback modification and other globals locally here.
			if currentTick == 0 and cell.effectCommand then
				if     string.char(cell.effectCommand + 0x40) == 'A' then
					-- Set Speed
					if cell.effectData >= 0x01 and cell.effectData <= 0xFF then
						speed = cell.effectData
					end
				elseif string.char(cell.effectCommand + 0x40) == 'T' then
					-- Set Tempo
					if cell.effectData >= 0x20 and cell.effectData <= 0xFF then
						tempo = cell.effectData
					end
				elseif string.char(cell.effectCommand + 0x40) == 'B' then
					-- Position Jump
					positionJump = cell.effectData
					-- Invalidate patternLoops that happened in a "later" 
					-- channel.
					patternLoop = false
				elseif string.char(cell.effectCommand + 0x40) == 'C' then
					-- Pattern Break
					if cell.effectData <= 0x3F then
						patternBreak = math.floor(cell.effectData/16)*10 +
							cell.effectData%16
						-- Invalidate patternLoops that happened in a "later" 
						-- channel.
						patternLoop = false
					end
				elseif string.char(cell.effectCommand + 0x40) == 'S' and
					math.floor(cell.effectData/16) == 0x1 then
						-- Glissando Control
						local x = cell.effectData%16
						if x == 0 then 
							glissando = false
						elseif x == 1 then
							glissando = true
						end
				elseif string.char(cell.effectCommand + 0x40) == 'S' and
					math.floor(cell.effectData/16) == 0x3 then
						-- Vibrato Waveform
						local x = cell.effectData%16
						if x < 8 then
							vibratoWaveform = x
						end
				elseif string.char(cell.effectCommand + 0x40) == 'S' and
					math.floor(cell.effectData/16) == 0x4 then
						-- Tremolo Waveform
						local x = cell.effectData%16
						if x < 8 then
							tremoloWaveform = x
						end
				elseif string.char(cell.effectCommand + 0x40) == 'S' and
					math.floor(cell.effectData/16) == 0xB then
						-- Pattern Loop
						local x = cell.effectData%16
						if x == 0 then
							loopRow[ch] = currentRow
						else
							if loopCnt[ch] == 0 then
								loopCnt[ch] = x
							else
								loopCnt[ch] = loopCnt[ch] - 1
							end
							patternLoop = true
							-- Invalidate positionJumps and patternBreaks that
							-- happened in a "later" channel.
							positionJump, patternBreak = false, false
						end
				elseif string.char(cell.effectCommand + 0x40) == 'S' and
					math.floor(cell.effectData/16) == 0xE then
						-- Pattern Delay
						local x = cell.effectData%16
						patternDelay = x
				elseif string.char(cell.effectCommand + 0x40) == 'V' then
					-- Global Volume
					if cell.effectData <= 0x40 then
						globalVolume = cell.effectData
					end
				end
			end
		end
		-- Fix timing, since we may have modified it in one of the tracks.
		tickPeriod, midiPPQ, actualTempo = FIXTIMING(
			tempo, speed, timeSigNumer, timeSigDenom)
	end
end



routine.step = function()
	-- Advance playback position.

	-- Default handling
	if currentTick + 1 < speed + patternDelay then
		currentTick = currentTick + 1
	else
		if patternDelay > 0 then patternDelay = 0 end
		currentTick = 0
		if currentRow + 1 < 64 then -- Row # constant & hardcoded in s3m.
			currentRow = currentRow + 1
		else
			currentRow = 0
			if currentOrder + 1 < module.orderCount then
				currentOrder   = currentOrder + 1
				currentPattern = module.order[currentOrder]
			else
				currentOrder   = 0 -- No song restart marker in s3m.
				currentPattern = module.order[currentOrder]
			end
			-- Invalidate loop points if we leave a pattern
			for ch = 0, module.channelCount-1 do
				loopRow[ch] = 0
				loopCnt[ch] = 0 
			end
		end
	end
	-- Loop handling
	if patternLoop and currentTick == 0 then 
		for ch = 0, module.channelCount-1 do
			-- TODO: Check if this processing order is right or wrong.
			if loopCnt[ch] > 0 then
				currentRow = loopRow[ch]
				patternLoop = false
				break
			end
		end
	end
	-- Jump handling
	if positionJump or patternBreak then
		if currentTick == 0 then
			if positionJump and not patternBreak then
				-- Jump to 0th row of given order.
				currentOrder   = positionJump % module.orderCount
				currentPattern = module.order[currentOrder]
				currentRow     = 0
			elseif not positionJump and patternBreak then
				-- Jump to given row of next order.
				currentOrder   = (currentOrder + 1) % module.orderCount
				currentPattern = module.order[currentOrder]
				if currentPattern < 254 then
					currentRow = patternBreak % 64 -- See above.
				end
			else
				-- Jump to given row of given order.
				currentOrder   = positionJump % module.orderCount
				currentPattern = module.order[currentOrder]
				if currentPattern < 254 then
					currentRow = patternBreak % 64 -- See above.
				end
			end
			positionJump, patternBreak = false, false
		end
	end
	-- Marker/Empty pattern skips
	if currentPattern >= 254 then
		for ord = currentOrder, module.orderCount-1 do
			if module.order[ord] < 254 then
				currentOrder   = ord
				currentPattern = module.order[currentOrder]
				currentRow     = 0
				currentTick    = 0
				break
			end
		end
		if currentPattern >= 254 then
			-- Restart from beginning.
			currentOrder   = 0
			currentPattern = module.order[currentOrder]
			currentRow     = 0
			currentTick    = 0
			time = 0
		end
	end
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
		for v=0, module.channelCount-1 do
			local L, R = 0.0, 0.0
			-- Render each voice, and mix them together.
			if not voice[v].muted then
				L, R = voice[v]:render()
				smpL, smpR = smpL + L, smpR + R
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
				time = time + tickPeriod
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
			time = time + tickPeriod
		end
	end
end



local noteTf = function(n)
	local symbol = {[0] = '-','#','-','#','-','-','#','-','#','-','#','-'}
	local letter = {[0] = 'C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A',
		'A', 'B'}
	if n == 254 then
		return '^^ '
	elseif n == 255 then
		return '...'
	else
		local class = n % 0x10
		local oct = math.floor(n / 0x10) - 1
		return ("%1s%1s%1X"):format(letter[class], symbol[class], oct)
	end
end
local textCP, textPP, textNP
textCP = love.graphics.newText(love.graphics.getFont())
textPP = love.graphics.newText(love.graphics.getFont())
textNP = love.graphics.newText(love.graphics.getFont())
routine.draw = function()
	love.graphics.setBackgroundColor(0.1,0.2,0.4)

	-- Patterns
	love.graphics.push()
	love.graphics.translate(0, 300+(-12*currentRow))

	textPP:clear()
	textCP:clear()
	textNP:clear()

	local prev, curr, next, color
	curr = module.pattern[module.order[currentOrder]]
	prev = module.pattern[module.order[(currentOrder - 1) % module.orderCount]]
	next = module.pattern[module.order[(currentOrder + 1) % module.orderCount]]

	local subOffset = 0
	if smoothScrolling then
		subOffset = -math.floor((currentTick / (speed + patternDelay)) * 12)
	end

	-- 227*8 == 1816 horizontal width would be needed to show 16 s3m channels.

	for row = 0, 63 do
		if prev then
			color = {0.5,0.5,0.25}
			textPP:add({color, ("%02X"):format(row)},
				0, 84+(row-64)*12+subOffset)
			for ch = 0, module.channelCount-1 do
				textPP:add({color, ("|%3s %2s %2s %1s%2s"):format(
					prev[row][ch].note and
						noteTf(prev[row][ch].note) or '...',
					prev[row][ch].instrument and
						("%02X"):format(prev[row][ch].instrument) or '..',
					prev[row][ch].volume and
						("%02X"):format(prev[row][ch].volume) or '..',
					prev[row][ch].effectCommand and
						string.char(prev[row][ch].effectCommand + 0x40) or '.',
					prev[row][ch].effectData and
						("%02X"):format(prev[row][ch].effectData) or '..')},
					2*8+ch*14*8, 84+(row-64)*12+subOffset)
			end
			textPP:add({color, "|"},
				2*8+module.channelCount*14*8, 84+(row-64)*12+subOffset)
		end

		if curr then
			if row ~= currentRow then
				color = {0.75,0.75,0.75}
			elseif currentTick == 0 then
				color = {1.0,1.0,1.0}
			else
				color = {0.75,0.75,0.25}
			end
			textCP:add({color, ("%02X"):format(row)}, 0, 84+row*12+subOffset)
			for ch = 0, module.channelCount-1 do
				textCP:add({color, ("|%3s %2s %2s %1s%2s"):format(
					curr[row][ch].note and noteTf(curr[row][ch].note) or '...',
					curr[row][ch].instrument and ("%02X"):format(curr[row][ch].instrument) or '..',
					curr[row][ch].volume and ("%02X"):format(curr[row][ch].volume) or '..',
					curr[row][ch].effectCommand and string.char(string.byte('A') + curr[row][ch].effectCommand - 1) or '.',
					curr[row][ch].effectData and ("%02X"):format(curr[row][ch].effectData) or '..')},
					2*8+ch*14*8, 84+row*12+subOffset)
			end
			textCP:add({color, "|"}, 2*8+module.channelCount*14*8, 84+row*12+subOffset)
		end

		if next then
			color = {0.5,0.25,0.75}
			textNP:add({color, ("%02X"):format(row)}, 0, 84+(row+64)*12+subOffset)
			for ch = 0, module.channelCount-1 do
				textNP:add({color, ("|%3s %2s %2s %1s%2s"):format(
					next[row][ch].note and noteTf(next[row][ch].note) or '...',
					next[row][ch].instrument and ("%02X"):format(next[row][ch].instrument) or '..',
					next[row][ch].volume and ("%02X"):format(next[row][ch].volume) or '..',
					next[row][ch].effectCommand and string.char(string.byte('A') + next[row][ch].effectCommand - 1) or '.',
					next[row][ch].effectData and ("%02X"):format(next[row][ch].effectData) or '..')},
					2*8+ch*14*8, 84+(row+64)*12+subOffset)
			end
			textNP:add({color, "|"}, 2*8+module.channelCount*14*8, 84+(row+64)*12+subOffset)
		end
	end

	love.graphics.draw(textPP, 0, 0)
	love.graphics.draw(textCP, 0, 0)
	love.graphics.draw(textNP, 0, 0)

	love.graphics.pop()

	-- Stats
	love.graphics.push()
	love.graphics.setColor(0,0,0.3)
	love.graphics.rectangle('fill',0,0,73*8,60)
	love.graphics.setColor(1,1,1)
	love.graphics.translate(0,-2)
	local i,f
	local y, w = 0, 12
	love.graphics.print(("order:   0x%02X / 0x%02X"):format(
		currentOrder, module.orderCount),   0, y)
	y = y + w
	love.graphics.print(("pattern: 0x%02X / 0x%02X"):format(
		currentPattern, module.patternCount), 0, y)
	y = y + w
	love.graphics.print(("row:     0x%02X / 0x%02X"):format(
		currentRow, 64),     0, y)
	y = y + w
	love.graphics.print(("tick:    0x%02X / 0x%02X"):format(
		currentTick, speed),    0, y)
	y = y + w
	local h,m
	h = math.floor(time/3600)
	m = math.floor((time/60)%60)
	i = math.floor(time%60)
	f = math.floor((time%1)*1000000)
	love.graphics.print(("elapsed time: %02d:%02d:%02d.%06d"):format(
		h, m, i, f), 0, y)
	y = 0
	love.graphics.print(("tempo (T): %3d"):format(tempo), 23*8, y)
	y = y + w
	love.graphics.print(("speed (A): %3d"):format(speed+1), 23*8, y)
	y = y + w
	i = math.floor(samplingPeriod*1000000)
	f = math.floor(samplingPeriod*10000000000) - (i * 10000)
	love.graphics.print(("s-period: %4d.%04d μs"):format(i, f), 23*8, y)
	y = y + w
	i = math.floor(tickPeriod*1000)
	f = math.floor(tickPeriod*10000000) - (i * 10000)
	love.graphics.print(("t-period: %4d.%04d ms"):format(i, f), 23*8, y)
	y = 0
	i = math.floor(actualTempo)
	f = math.floor(actualTempo*10000) - (i * 10000)
	love.graphics.print(("true tempo: %4d.%04d BPM"):format(i, f), 48*8, y)
	y = y + w
	love.graphics.print(("mixed smp-s: %4d"):format(samplesToMix), 48*8, y)
	y = y + w
	love.graphics.print(("Timing:   %s"):format(device.renderMode), 48*8, y)
	y = y + w
	love.graphics.print(("Tracking: %s"):format(device.trackingMode), 48*8, y)
	love.graphics.pop()

	-- Matrix
	love.graphics.push()
	love.graphics.translate(74*8, 0)
	love.graphics.setColor(0,0,0.25)
	love.graphics.rectangle('fill',0,0,73*8,(module.channelCount+1)*12)
	love.graphics.setColor(1,1,1)
	love.graphics.translate(0,-2)
	love.graphics.print(
		'Ch nPer Nx d c | Ix Vx Cx Dx | gPer iPer | smpO',
		 0, 0)
--love.graphics.print(
--	"Ch | Nx Ix Vx Cx Dx | nPer gPer iPer | cOfs smpL smpS smpE Cspd | cV cP | FX Fg Fp Fv | DC T+- A12",
--	0, 0)
	for ch = 0, module.channelCount-1 do
		-- A A A A B B C D -- notePeriod n noteDelayTicks noteCutTicks
		-- E E F F G G H H -- i v c d
		-- I I I I J J J J -- glisPeriod instPeriod
		local stats = {voice[ch]:getStatistics()}
		love.graphics.print((
			"%02X %04X %02X %1X %1X | %02X %02X %02X %02X | %04X %04X | %04X"
			):format(ch, unpack(stats)), 0, (ch+1)*12)
	end
	love.graphics.pop()
end

--------------
return routine