-- LöveTracker Audio Device Object
-- by zorg @ 2017 § ISC

local Device = {}

local renderModes   = {['Buffer'] = true, ['CPU'] = true}
local trackingModes = {['Buffer'] = true, ['CPU'] = true}

-- Getters are unimportant here, but setters are.

Device.resetBuffer = function(dev)
	if not dev.buffer then dev.buffer = {} end
	dev.buffer.data   = nil
	dev.buffer.offset = 0
	dev.buffer.size   = dev.bufferSize
	dev.buffer.data   = love.sound.newSoundData(
		dev.buffer.size,
		dev.samplingRate, 
		dev.bitDepth, 
		dev.channelCount
	)
end

Device.resetSource = function(dev)
	if not dev.source then dev.source = {} end
	dev.source.queue = nil
	dev.source.queue = love.audio.newQueueableSource(
		dev.samplingRate,
		dev.bitDepth,
		dev.channelCount
	)
end

Device.setSamplingRate = function(dev, samplingRate)
	if dev.samplingRate == samplingRate then return true end
	dev.samplingRate = samplingRate
	dev.resetBuffer()
	dev.resetSource()
	return true
end

Device.setBitDepth = function(dev, bitDepth)
	if dev.bitDepth == bitDepth then return true end
	dev.bitDepth = bitDepth
	dev.resetBuffer()
	dev.resetSource()
	return true
end

Device.setChannelCount = function(dev, channelCount)
	if dev.channelCount == channelCount then return true end
	dev.channelCount = channelCount
	dev.resetBuffer()
	dev.resetSource()
	return true
end

Device.setBufferSize = function(dev, bufferSize)
	if dev.bufferSize == bufferSize then return true end
	dev.bufferSize = bufferSize
	dev.resetBuffer()
	return true
end

Device.setRenderMode = function(dev, mode)
	if not renderModes[mode]  then return false end
	if dev.renderMode == mode then return true end
	dev.renderMode = mode
	return true
end

Device.setTrackingMode = function(dev, mode)
	if not trackingModes[mode]  then return false end
	if dev.trackingMode == mode then return true end
	dev.trackingMode = mode
	return true
end

local mtDevice = {__index = Device}

local new = function(samplingRate, bitDepth, channelCount, bufferSize,
	renderMode, trackingMode)
	local dev = setmetatable({}, mtDevice)

	dev.samplingRate = samplingRate or 44100 -- Hz (1/seconds)
	dev.bitDepth     = bitDepth     or    16 -- bits
	dev.channelCount = channelCount or     2 -- channels
	dev.bufferSize   = bufferSize   or  2048 -- smp

	dev.renderMode   = renderMode   or 'CPU'
	dev.trackingMode = trackingMode or 'Buffer'

	dev:resetBuffer()
	dev:resetSource()

	return dev
end

----------
return new