local samplingRate
local bitdepth
local channelCount

local bufferSize
local buffer
local bufferPos

local qsource
local maxBuffers

local play

local routine = {}
local module

routine.init = function(mod)
	-- These are for the playroutine.
	samplingRate = 44100
	bitdepth     = 16
	channelCount = 1

	bufferSize = 1024
	buffer     = love.sound.newSoundData(bufferSize, 44100, 16, 1) -- buffsize,smplrate,bitdepth,channels
	bufferPos = 0

	qsource    = love.audio.newQueueableSource(44100,16,1)
	maxBuffers = qsource:getFreeBufferCount()

	-- These are for the channels' runtime status.
	routine.channel = {}
	for i=0,31 do
		local chnl = {}

		chnl.lastInstrument = nil
		chnl.baseNote       = nil
		chnl.sampleOffset   = 0.0
		chnl.vibOffset      = nil
		chnl.livePeriod     = 0.0
		chnl.slidetoPeriod  = nil
		chnl.stablePeriod   = 0.0
		chnl.liveHz         = 0
		chnl.volume         = nil
		chnl.arpeggio       = 0

		-- command caches
		chnl.lastVolumeSlide = nil
		chnl.lastPitchSlide  = nil
		chnl.lastVibratoHigh, chnl.lastVibratoLow = nil, nil
		chnl.lastTremoloHigh, chnl.lastTremoloLow = nil, nil
		chnl.lastPortamento  = nil
		chnl.lastArpeggio    = nil

		routine.channel[i] = chnl
	end

	-- Get a handle for that.
	module = mod

	-- Further Playroutine processing vars.
	routine.Txx = module.initialTempo
	routine.Axx = module.initialSpeed

	-- Alternatively, once per frame; but ST3 does it like this.
	routine.arpeggioInterval = samplingRate / 50.0

	-- Each row is 2.5 * Axx / Txx seconds long. I.e. 2.5 * samplingRate * Axx / Txx samples long. 
	routine.frameDuration = 2.5 * samplingRate / routine.Txx

	routine.hertzRatio = 14317056.0 / samplingRate 

	routine.volumeNormalizer = module.masterVolume * module.globalVolume / 1048576.0

	routine.currentTime = 0

	routine.noteHzTable = {}
	for i=0, 15 do routine.noteHzTable[i] = math.exp(i * 0.0577622650466621) end -- for effects proc.
	routine.inverseNoteHzTable = {}
	for i=0, 194 do routine.inverseNoteHzTable[i] = math.exp(i * -0.0577622650466621) end -- log(2)/-12

	routine.currentRow = 0 -- "row"
	routine.nextOrder = 0

	play = true
end

local currentPattern

routine.process = function()
	if play then

		if qsource:getFreeBufferCount() == 0 then return end

		-- Load pattern pointer.
		if routine.nextOrder >= module.ordNum then
			routine.nextOrder = 0
			return
		end

		currentPattern = module.orders[routine.nextOrder]
		routine.nextOrder = routine.nextOrder + 1

		if currentPattern == 255 then
			routine.nextOrder = 0
			return
		end
		if currentPattern == 254 then -- the loader strips these markers, so this is moot.
			return
		end

		-- Skipping to current row not needed; this isn't loaded in realtime, like bisqwit's code reference.

		local patPtr = module.patterns[currentPattern]
		local patLoop = patPtr
		local loopsRemain = 0
		local loopRow = 0

		-- Play pattern until its end.
		local rowFinishStyle = 0
		while routine.currentRow < #patPtr do

			local rowRepeatCount = 0

			-- Parse current row
			for rowRepeat = 0, rowRepeatCount do
				for tick = 0, routine.Axx do
					local row = patPtr[routine.currentRow]

					-- Parse channels in one row
					for ch = 0, module.chnNum-1 do

						local slot = row[ch]

						-- DEBUG
						--print(routine.currentRow, ch, slot)
						if not slot then break end
						-- /DEBUG

						local noteOnTick = 0; local noteCutTick = 999;
						local sample_offset = 0
						local portamento = 0
						-- ...

						-- Do a table instead of this if-horridness.
						if     slot.effectcmd == string.byte('A')-64 then -- Set Speed
							routine.Axx = slot.effectprm
						elseif slot.effectcmd == string.byte('B')-64 then -- Position Jump
							rowFinishStyle     = 2
							routine.currentRow = 0
							routine.nextOrder = slot.effectprm
						elseif slot.effectcmd == string.byte('C')-64 then -- Pattern Break
							rowFinishStyle     = 2
							routine.currentRow = math.floor(slot.effectprm/16)*10 + (slot.effectprm%16)
						elseif slot.effectcmd == string.byte('T')-64 then -- Set Tempo
							routine.Txx = slot.effectprm
							routine.frameDuration = 2.5 * samplingRate / routine.Txx
						elseif slot.effectcmd == string.byte('S')-64 then -- ...
							if tick == 0 then
								local sub = slot.effectprm - (slot.effectprm%16)
								if sub == 0xB0 then -- Pattern Loop
									if slot.effectprm == 0xB0 then
										patLoop = patPtr
										loopRow = routine.currentRow
									elseif loopsRemain == 0 then
										rowFinishStyle = 1
										loopsRemain = slot.effectprm%16
									elseif loopsRemain-1 > 0 then -- (--loops_remain > 0) ...
										rowFinishStyle = 1
									end
								end
							end
						end

						if tick == noteOnTick then
							if slot.note == '^^' then
								noteCutTick = tick
							elseif type(slot.note) == 'number' or slot.instrument then
								if type(slot.note) == 'number' then
									routine.channel[ch].baseNote = slot.note -- already preprocessed to >>4*12+&0F
								end
								if slot.instrument then routine.channel[ch].lastInstrument = slot.instrument - 1 end
								if slot.instrument and slot.volumecmd == 255 then
									routine.channel[ch].volume = module.instruments[routine.channel[ch].lastInstrument].volume
								end
								-- st3 period = 8363 * 16 * 171 / 2^(note/12) / c4spd
								--            = 229079296 * exp(note * log(2)/-12)
								routine.channel[ch].slidetoPeriod = routine.inverseNoteHzTable[routine.channel[ch].baseNote] *
									(229079296.0 / module.instruments[routine.channel[ch].lastInstrument].c4speed) -- ???
								if portamento > 0 then 
									routine.channel[ch].stablePeriod = routine.channel[ch].slidetoPeriod
									routine.channel[ch].sampleOffset = sample_offset
								end
							end

							if slot.volumecmd ~= 255 then
								routine.channel[ch].volume = slot.volumecmd or 0
							end
						end

						if tick == noteCutTick then
							routine.channel[ch].baseNote = false -- 255
						end

						-- TODO Portamento pt.2

						routine.channel[ch].livePeriod = routine.channel[ch].stablePeriod
						-- TODO Vibrato
						-- TODO PitchSlide
						-- TODO VolSlide

						if routine.channel[ch].livePeriod ~= 0.0 then
							print(routine.channel[ch].livePeriod)
							routine.channel[ch].liveHz = routine.hertzRatio / routine.channel[ch].livePeriod
						end

					end

					-- Mix the tick

					local tickEndsAt = routine.currentTime + routine.frameDuration
					local samplesToMix = math.floor(tickEndsAt - routine.currentTime) -- or just floor frameDuration...

					for n=0, samplesToMix do
						local result = 0.0
						for ch = 0, 31 do
							if routine.channel[ch].baseNote then

								if routine.channel[ch].sampleOffset
									< module.instruments[routine.channel[ch].lastInstrument].smpLen then

									local hz = routine.channel[ch].liveHz

									if routine.channel[ch].arpeggio > 0 then
										local pos = math.floor((routine.currentTime/routine.arpeggioInterval)%3)
										hz = hz * routine.noteHzTable[(routine.channel[ch].arpeggio/16)%16]
									end

									local insVal
									if routine.channel[ch].sampleOffset >= module.instruments[routine.channel[ch].lastInstrument].smpLen then
										insVal = 0
									else
										insVal = module.instruments[routine.channel[ch].lastInstrument].data:getSample(
											routine.channel[ch].sampleOffset)
									end
									routine.channel[ch].sampleOffset = routine.channel[ch].sampleOffset + hz
									if module.instruments[routine.channel[ch].lastInstrument].looping and
										routine.channel[ch].sampleOffset > 
											module.instruments[routine.channel[ch].lastInstrument].smpLoopEnd then
												routine.channel[ch].sampleOffset = 
													module.instruments[routine.channel[ch].lastInstrument].smpLoopStart +
														(routine.channel[ch].sampleOffset -
															module.instruments[routine.channel[ch].lastInstrument].smpLoopStart)
														%
														(module.instruments[routine.channel[ch].lastInstrument].smpLoopEnd -
															module.instruments[routine.channel[ch].lastInstrument].smpLoopStart)
									end

									result = result + routine.channel[ch].volume * insVal

								else
									routine.channel[ch].baseNote = false
								end
							end
						end

						local value = result --math.floor(result * routine.volumeNormalizer)
						value = value<-128 and -128 or value
						value = value>127 and 127 or value

						local samplepointvalue = ((((value+128)/255)-.5)*2)

						buffer:setSample(bufferPos, samplepointvalue)
						bufferPos = bufferPos + 1
						if bufferPos == bufferSize then
							--print "PUSHED BUFFER!"
							qsource:queue(buffer)
							qsource:play()
							bufferPos = 0
						end
						routine.currentTime = routine.currentTime + 1.0
					end
				end
			end

			-- Go to next row
			if rowFinishStyle == 1 then -- loop
				patPtr = patLoop -- .... basically, the pattern we are in
				routine.currentRow = loopRow
			elseif rowFinishStyle == 2 then -- jump to different pattern
				break
			else -- go to next row
				routine.currentRow = routine.currentRow + 1
			end
		end
		-- End of pattern
		if rowFinishStyle == 0 then
			currentPattern = currentPattern + 1
			routine.currentRow = 0
		end
	end
end

routine.draw = function()
	if module and currentPattern and module.patterns and module.patterns[currentPattern] then
		for i=0, #module.patterns[currentPattern] do
			if i ~= routine.currentRow then
				love.graphics.setColor(0.75,0.75,0.75)
			else
				love.graphics.setColor(1.0,1.0,0.80)
			end
			love.graphics.print(("%02d"):format(i), 0, i*12)
			love.graphics.print(module.printRow(module.patterns[currentPattern][i], module.chnNum),16,i*12)
		end
	end
end

--------------
return routine

-- ins.c4spd_factor = 229079296.0 / ins.c4spd; -- ???????