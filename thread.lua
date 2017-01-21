require('love.timer')
require('love.sound')
require('love.audio')

print('thread started!')







local sample = love.sound.newSoundData("160219_lovesplashident.ogg")
local i = 0









local sd = select(3, ...)
local sdCurr = 0

local qs = love.audio.newQueueableSource(44100,16,1)
local maxBuffers = qs:getFreeBufferCount()
local frameDuration = 2.5 * 44100 * 6 / 120 -- magic * smplrate * speed / tempo -> samplepoints per frame

print(frameDuration) -- 5512 smp @ 44.1kHz, 1000 smp @ 8000Hz

while true do

	local samplesToMix = math.ceil(frameDuration) -- let's be optimistic for once.

	if qs:getFreeBufferCount() > 0 then

		for n=0, samplesToMix-1 do

			i = i + 1/44100*44100*2 -- inverse of oals mixing rate, sample sampling rate, channels
			i = math.floor(i)%2==0 and i or i+1 -- fixme: stereo processing...

			--local val = 0.0 + math.sin(440.0 * i * math.pi * 2 / 44100)

			-- interpolate sample - linear
				--local int = math.floor(i)
				--local frac = i-int
				--local val = (sample:getSample((int)%(sample:getSampleCount()*2))*(1.0-frac)
				--	+ sample:getSample((int+1)%(sample:getSampleCount()*2))*(frac))
			-- interpolate sampel - nearest
				local val = sample:getSample(math.floor(i)%(sample:getSampleCount()*2))
			--

			sd:setSample(sdCurr, val)

			-- If at any time we'd go over the last indice of our buffer (the SoundData), flush it and begin anew.
			sdCurr = sdCurr + 1
			if sdCurr >= sd:getSampleCount() then
				print(i)
				qs:queue(sd)
				qs:play()
				sdCurr = 0
			end

		end

	end

	--print("Free buffers: " .. qs:getFreeBufferCount() .. "/" .. maxBuffers)

end