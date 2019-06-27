-- Scream Tracker 3 "S3M" importer/parser
-- by zorg @ 2017 § ISC
-- Original format by Future Crew (Probably based on the ProTracker format,
-- which, in turn was based on Ultimate Soundtracker by Karsten Obarski.)

-- Note: The below implementation allows unknown pattern cell data into the
--       internal representation of the loaded modules; the playroutine itself
--       doesn't bork on such things, and they get shown graphically as such.



--[[ TODO: Check implementation against the following sources:
	https://source.openmpt.org/svn/openmpt/trunk/OpenMPT/soundlib/Load_s3m.cpp
	https://github.com/schismtracker/schismtracker/blob/master/fmt/s3m.c#L1013
	https://wiki.openmpt.org/Development:_Formats/S3M
	https://wiki.openmpt.org/Development:_Test_Cases/S3M
--]]



--[[
	Structure definition:
		title                      - string[27+1]
		orderCount                 - 0x00..0xFF
		sampleCount                - 0x00..0x63
		patternCount               - 0x00..0x64
		killSilentLoops            - boolean
		amigaNoteLimits            - boolean
		fastVolSlides              - boolean
		created w/ tracker+version - string[4]
		sampleFormat               - Signed, Unsigned
		globalVolume               - 0x00..0x40
		initialSpeed               - 0x00..0x1F
		initialTempo               - 0x20..0xFF
		isStereo                   - boolean
		masterVolume               - 0x00..0x40
		channelCount               - calculated

		channel[]                  - 0x00..0x1F
			enabled                - boolean
			map                    - 0x00..0x1F
			type                   - 'Sampler', 'AdLib Melody', 'AdLib Drum',
			                         'Unknown'
			pan                    - 0x0..0xF

		order[]                    - 0x00..orderCount
			*                      - 0x00..patternCount

		sample[]                   - 0x00..sampleCount
			type                   - 0 (Empty),1 (Sampler),2 (AdLib Melody), ?
			filename               - string[12]
			volume                 - 0x00..0x40
			c4speed                - 0x0000..0xFFFF
			name                   - string[27+1]
			-- type == 1 (Sampler)
			wfOffset               - memory offset not important for p.routine
			length                 - length of waveform data
			loopStart              - 0x0000..0xFFFF
			loopEnd                - 0x0000..0xFFFF
			packingScheme          - Unpacked (0), DP30ADPCM (1), Unknown (...)
			looped                 - boolean
			channelCount           - 1, 2
			bitDepth               - 8, 16
			data                   - SoundData
			-- type == 2 (AdLib Melodic)
			additiveSynthesis      - TBD
			modulationFeedback     - TBD
			carFrequencyMultiplier - TBD
			carEnvelopeScaling     - TBD
			carSustainSound        - TBD
			carVibrato             - TBD
			carTremolo             - TBD
			carVolume              - TBD
			carLevelScale          - TBD
			carAttack              - TBD
			carDecay               - TBD
			carSustain             - TBD
			carRelease             - TBD
			carWaveform            - TBD
			modFrequencyMultiplier - TBD
			modEnvelopeScaling     - TBD
			modSustainSound        - TBD
			modVibrato             - TBD
			modTremolo             - TBD
			modVolume              - TBD
			modLevelScale          - TBD
			modAttack              - TBD
			modDecay               - TBD
			modSustain             - TBD
			modRelease             - TBD
			modWaveform            - TBD

		pattern[]                  - 0x00..patternCount
			row[]                  - 0x00..0x3F
				channel[]          - 0x00..channelCount
					note           - 0x00..0xFF
					instrument     - 0x00..0xFF
					volume         - 0x00..0x3F
					effectCommand  - 0x00..0xFF
					effectData     - 0x00..0xFF
--]]

local util = require('util')
local log = require('log')

local errorString = {
	--[[1]] "File FourCC at 0x2C isn't 'SCRM'.",
	--[[2]] "Early end-of-file in header.",
	--[[3]] "Invalid module sample format.",
	--[[4]] "Early end-of-file in channel properities.",
	--[[5]] "Early end-of-file in order list.",
	--[[6]] "Early end-of-file in sample parapointer list.",
	--[[7]] "Early end-of-file in pattern parapointer list.",
	--[[8]] "Early end-of-file in default panning definition list.",
	--[[9]] "Early end-of-file in sample blocks.",
	--[[A]] "Sampler block signature was not SCRS.",
	--[[B]] "Sampler block alignment failure.",
	--[[C]] "AdLib block signature was not SCRI.",
	--[[D]] "AdLib block alignment failure.",
	--[[E]] "Early end-of-file in pattern blocks.",
	--[[F]] "Early end-of-file in sample waveform data blocks.",
}

-- Probable tracker that created the module.
local cwtStrings = {
	--[[1]] "Scream Tracker",
	--[[2]] "Imago Orpheus",
	--[[3]] "Impulse Tracker",
	--[[4]] "Schism Tracker", -- different after v0.50 (12bit delta timestamp)
	--[[5]] "OpenMPT",
	--[[6]] "BeRo Tracker", -- Used 4100 previously; can clash w/ schism tstmp.
	--[[7]] "CreamTracker",
			false,false,false,false,
	--[[C]] "Camoto / libgamemusic", -- Only ever CA00.
}

local load_s3m = function(file)
	log("--  Scream Tracker 3 S3M loader  --\n\n")
	local structure = {}
	file:open('r')

	-- This is the universe having a giggle.
	local isPixPlay = false

	--[[Header]]--

	file:seek(44)
	local formatstring = file:read(4)
	if formatstring ~= "SCRM" then return false, errorString[1] end
	log("SCRM FourCC detected at 0x2C.\n")

	local v,n

	file:seek(0)
	v, n = file:read(28); if n ~= 28 then return false, errorString[2] end
	structure.title = v
	log("Title: '%s' (%s)\n", structure.title,
		util.str2hex(structure.title, ' '))

	v, n = file:read(1); if n ~= 1 then return false, errorString[2] end
	if v ~= '\x1A' then
		log("DOS TYPE command EOF marker was '0x%s'; should have been 0x1A.\n",
			util.str2hex(v))
	end

	v, n = file:read(1); if n ~= 1 then return false, errorString[2] end
	if v ~= '\x10' then
		log("File type was '0x%s'; should have been 0x10.\n",
			util.str2hex(v))
	end

	v, n = file:read(2); if n ~= 2 then return false, errorString[2] end
	if v ~= "\0\0" then
		log("Unused expansion bytes '0x%s 0x%s' not the expected 0x00 0x00.\n",
			util.str2hex(v:sub(1,1)), util.str2hex(v:sub(2,2)))
	end

	v, n = file:read(2); if n ~= 2 then return false, errorString[2] end
	structure.orderCount = util.bin2num(v, 'LE')
	log("Order count:      0x%04X", structure.orderCount)
	if structure.orderCount > 255 then
		log(" (larger than the maximum of 0xFF)") -- TODO: Verify this #.
	end
	if structure.orderCount % 2 ~= 0 then
		log(" (not even!)") -- TODO: Can ST3 load odd-order count modules?
	end
	log("\n")

	v, n = file:read(2); if n ~= 2 then return false, errorString[2] end
	structure.sampleCount = util.bin2num(v, 'LE')
	log("Sample count: 0x%04X", structure.sampleCount)
	if structure.sampleCount > 99 then
		log(" (larger than the maximum of 0x63)") -- TODO: Verify this #.
	end
	log("\n")

	v, n = file:read(2); if n ~= 2 then return false, errorString[2] end
	structure.patternCount = util.bin2num(v, 'LE')
	log("Pattern count:    0x%04X", structure.patternCount)
	if structure.patternCount > 100 then
		log(" (larger than the maximum of 0x64)") -- TODO: Verify this #.
	end
	log("\n")

	v, n = file:read(2); if n ~= 2 then return false, errorString[2] end
	v = util.bin2flags(v)
	structure.st2vibrato      = v[1]
	structure.st2tempo        = v[2]
	structure.amigaslides     = v[3]
	structure.killSilentLoops = v[4]
	structure.amigaNoteLimits = v[5]
	structure.SBFilterEffects = v[6]
	structure.fastVolSlides   = v[7]
	structure.customdata      = v[8]
	log("Flag   1 - ST2 Vibrato:            %s\n", (v[1]==true and 'Y' or 'N'))
	log("Flag   2 - ST2 Tempo:              %s\n", (v[2]==true and 'Y' or 'N'))
	log("Flag   4 - Amiga Slides:           %s\n", (v[3]==true and 'Y' or 'N'))
	log("Flag   8 - 0-Vol. Optimalizations: %s\n", (v[4]==true and 'Y' or 'N'))
	log("Flag  16 - Amiga Note Limits:      %s\n", (v[5]==true and 'Y' or 'N'))
	log("Flag  32 - Enable SB Filter/SFX:   %s\n", (v[6]==true and 'Y' or 'N'))
	log("Flag  64 - Fast ST 3.00 VolSlides: %s\n", (v[7]==true and 'Y' or 'N'))
	log("Flag 128 - Custom Data Defined:    %s\n", (v[8]==true and 'Y' or 'N'))

	-- Flags 1,2,4,32 for v3.00 fileformat only, not supported above...
	-- meaning they should just be zero if the cwt/v field implies otherwise.
	-- Flag 64 might be an OpenMPT addition?

	v, n = file:read(2); if n ~= 2 then return false, errorString[2] end
	v = util.bin2num(v, 'LE')
	log("Created with tracker/version %X\n", v)
	local cwt = math.floor(v / 0x1000)
	local version = v % 0x1000
	-- Unraveling of this field done later.

	v, n = file:read(2); if n ~= 2 then return false, errorString[2] end
	v = util.bin2num(v, 'LE')
	if  v == 1 then structure.sampleFormat = 'Signed' elseif
		v == 2 then structure.sampleFormat = 'Unsigned' else
		return false, errorString[3]
	end
	log("Sample format: %s\n", structure.sampleFormat)

	-- Skip FourCC
	file:read(4)

	v, n = file:read(1); if n ~= 1 then return false, errorString[2] end
	structure.globalVolume = util.bin2num(v)
	log("Global volume:  0x%02X", structure.globalVolume)
	if structure.globalVolume > 0x40 then
		log(" (larger than the maximum of 64)")
	end
	log("\n")

	v, n = file:read(1); if n ~= 1 then return false, errorString[2] end
	structure.initialSpeed = util.bin2num(v)
	log("Initial speed:  0x%02X", structure.initialSpeed)
	if structure.initialSpeed >= 0x1F then -- TODO: Get value limits!
		log(" (larger than the maximum of 32)")
	end
	log("\n")

	v, n = file:read(1); if n ~= 1 then return false, errorString[2] end
	structure.initialTempo = util.bin2num(v)
	log("Initial tempo:  0x%02X", structure.initialTempo)
	if structure.initialTempo <= 0x20 then
		log(" (smaller than the minimum of 33)")
	end
	log("\n")

	v, n = file:read(1); if n ~= 1 then return false, errorString[2] end
	v = util.bin2num(v)
	structure.isStereo     = (math.floor(v/128)==1)
	structure.masterVolume = (v>127 and v-128 or v)
	log("Master volume:  0x%02X\n", structure.masterVolume)
	log("Output channels: %s\n", (structure.isStereo and 'Stereo' or 'Mono'))

	-- UltraClick removal (Used only for tracker detection)
	v, n = file:read(1); if n ~= 1 then return false, errorString[2] end
	v = util.bin2num(v)
	local ucremoval = v

	local initialPanning
	v, n = file:read(1); if n ~= 1 then return false, errorString[2] end
	if v == '\xFC' then initialPanning = true else initialPanning = false end
	log("Initial channel panning values %s.\n\n",
		(initialPanning and 'defined' or 'undefined'))

	-- Skip Expansion bytes
	file:read(8)

	-- Special pointer (Used only for tracker detection)
	v, n = file:read(2); if n ~= 2 then return false, errorString[2] end
	v = util.bin2num(v, 'LE')
	local specptr = v

	--[[Channel structure]]--

	structure.channel = {}
	local position = 0
	for ch = 0, 31 do
		local channel = {}
		v, n = file:read(1); if n ~= 1 then return false, errorString[4] end
		v = util.bin2num(v)
		channel.enabled = (math.floor(v/128)==0)
		if channel.enabled then
			channel.map = position; position = position + 1
		else
			channel.map = false
		end
		v = v%128
		if     v <  16 then
			channel.type = 'Sampler'
			channel.pan = (v<8 and 0x3 or 0xC)
		elseif v <  32 then -- 30, actually.
			channel.type = (v<=24 and 'AdLib Melody' or 'AdLib Drum')
			channel.pan = 0x7
		else
			channel.type = 'Unknown'
			channel.pan = 0x7
		end
		log("Channel 0x%02X (%s) panning 0x%01X mapped to ",
			ch, channel.type, channel.pan)
		if channel.map then
			log("0x%02X\n", channel.map)
		else
			log("nothing\n")
		end
		structure.channel[ch] = channel
	end
	structure.channelCount = position
	log("Total enabled channels: %d\n\n", structure.channelCount)

	--[[Order list]]--

	structure.order = {}
	log("Orders:\n")
	local cols = 0
	for ord = 0, structure.orderCount-1 do
		v, n = file:read(1); if n ~= 1 then return false, errorString[5] end
		structure.order[ord] = util.bin2num(v)
		log("0x%02X ", structure.order[ord])
		cols = cols + 1; if cols == 16 then log("\n") cols = 0 end
	end
	log("\n\n")

	--[[Pointer lists]]--

	local headerEnd = 64 + 32 + structure.orderCount +
	                            structure.sampleCount +
	                            structure.patternCount

	-- Read paragraph (16-byte aligned) pointers; stored as byte offsets.
	local paraptrSmp = {}
	for i = 0, structure.sampleCount-1 do
		v, n = file:read(2); if n ~= 2 then return false, errorString[6] end
		paraptrSmp[i] = util.bin2num(v, 'LE') * 0x10
		log("Sample 0x%04X offset at %06X", i, paraptrSmp[i])
		if paraptrSmp[i] < headerEnd then
			log(" (Offset less than end of header!)")
		end
		log("\n")
	end
	log("\n")
	local paraptrPat = {}
	for i = 0, structure.patternCount-1 do
		v, n = file:read(2); if n ~= 2 then return false, errorString[7] end
		paraptrPat[i] = util.bin2num(v, 'LE') * 0x10
		log("Pattern 0x%04X offset at %06X", i, paraptrPat[i])
		if paraptrPat[i] < headerEnd then
			log(" (Offset less than end of header!)")
		end
		log("\n")
	end
	log("\n")

	--[[Channel Panning list]]--

	if initialPanning then for ch = 0, 31 do
		v, n = file:read(1); if n ~= 1 then return false, errorString[8] end
		v = util.bin2num(v) % 0x10 -- High nibble is garbage.
		structure.channel[ch].pan = structure.isStereo and v or 0x7
		log("Channel 0x%02X fixed panning value to 0x%01X\n",
			ch, structure.channel[ch].pan)
	end log("\n\n") end

	--[[Samples]]--

	local sampleType = {[0] = 'Unused', 'Sampler', 'AdLib Melody',
		'AdLib Bassdrum', 'AdLib Snare', 'AdLib Tom', 'AdLib Cymball',
		'AdLib Hihat'}

	local packingScheme = {[0] = 'Unpacked', 'DP30ADPCM'}

	structure.sample = {}
	for smp = 0, structure.sampleCount-1 do
		local sample = {}
		file:seek(paraptrSmp[smp])
		log("Sample 0x%04X at 0x%06X\n", smp, paraptrSmp[smp])
		v, n = file:read(1); if n ~= 1 then return false, errorString[9] end
		sample.type = util.bin2num(v)
		log("    %s\n",
			sample.type < 8 and sampleType[sample.type] or 'Unknown')
		v, n = file:read(12); if n ~= 12 then return false, errorString[9] end
		sample.filename = v
		log("    DOS filename '%s' (%s)\n", sample.filename,
			util.str2hex(sample.filename, ' '))
		if sample.type == 0 then
			-- Empty slot
		elseif sample.type == 1 then
			-- Sampler
			file:seek(paraptrSmp[smp] + 0x4C)
			v, n = file:read(4)
			if n ~= 4 then return false, errorString[9] end
			if v ~= 'SCRS' then
				--return false, errorString[10]
				-- Some modules might not correctly include this...
				log("    Warning: Subheader wasn't 'SCRS'; was '%s'!\n", v)
			end
			file:seek(paraptrSmp[smp] + 13)
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			sample.wfOffset = util.bin2num(v) * 0x10000
			v, n = file:read(2)
			if n ~= 2 then return false, errorString[9] end
			sample.wfOffset = sample.wfOffset + util.bin2num(v, 'LE')
			-- Needs a multiplication by 0x10 to be correct.
			sample.wfOffset = sample.wfOffset * 0x10 
			log("    Waveform Offset 0x%06X\n", sample.wfOffset)
			v, n = file:read(4) -- Format only uses first two bytes though.
			if n ~= 4 then return false, errorString[9] end
			sample.length = util.bin2num(v, 'LE')
			log("    Length          0x%08X", sample.length)
			if sample.length > 64000 then
				-- Virt's V-CF2.S3M has one sample going above 65535 though.
				-- Maybe just don't truncate? Specs say we should though...
				--sample.length = 64000
				--log(" (truncated to 64k)")
				log(" (longer than 64k!)")
			end
			log("\n")
			v, n = file:read(4) -- Format only uses first two bytes though.
			if n ~= 4 then return false, errorString[9] end
			sample.loopStart = util.bin2num(v, 'LE')
			log("    LoopStart:      0x%08X", sample.loopStart)
			if sample.loopStart > 0xFFFF then
				log(" (Larger than 2 bytes) ")
			end
			log("\n")
			v, n = file:read(4) -- Format only uses first two bytes though.
			if n ~= 4 then return false, errorString[9] end
			sample.loopEnd = util.bin2num(v, 'LE')
			log("    LoopEnd:        0x%08X", sample.loopEnd)
			if sample.loopStart > 0xFFFF then
				log(" (Larger than 2 bytes)")
			end
			log("\n")
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			sample.volume = util.bin2num(v)
			log("    Volume:         0x%02X\n", sample.volume)
			file:read(1) -- Skip unused byte.
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			sample.packingScheme = util.bin2num(v)
			log("    Packing scheme '%s'\n",
				sample.packingScheme < 2 and
				packingScheme[sample.packingScheme] or 'Unknown')
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2flags(v)
			sample.looped       = v[1]
			sample.channelCount = v[2] and  2 or 1
			sample.bitDepth     = v[3] and 16 or 8
			log("    Flag   1 - Looped: %1s \n", (v[1]==true and 'Y' or 'N'))
			log("    Flag   2 - Stereo: %1s \n", (v[2]==true and 'Y' or 'N'))
			log("    Flag   4 - 16-bit: %1s \n", (v[3]==true and 'Y' or 'N'))
			log("    Flag   8 - Unused (%1s)\n", (v[4]==true and 'Y' or 'N'))
			log("    Flag  16 - Unused (%1s)\n", (v[5]==true and 'Y' or 'N'))
			log("    Flag  32 - Unused (%1s)\n", (v[6]==true and 'Y' or 'N'))
			log("    Flag  64 - Unused (%1s)\n", (v[7]==true and 'Y' or 'N'))
			log("    Flag 128 - Unused (%1s)\n", (v[8]==true and 'Y' or 'N'))
			v, n = file:read(4)
			if n ~= 4 then return false, errorString[9] end
			sample.c4speed = util.bin2num(v, 'LE') -- C2spd originally.
			log("    C4 speed: 0x%08X (%d)\n", sample.c4speed, sample.c4speed)
			file:read(4) -- Skip unused bytes.
			v, n = file:read(2)
			if n ~= 2 then return false, errorString[9] end
			log("    Gravis U.S. memory address:  0x%04X\n",
				util.bin2num(v, 'LE'))
			v, n = file:read(2)
			if n ~= 2 then return false, errorString[9] end
			log("    SoundBlaster loop expansion: 0x%04X\n",
				util.bin2num(v, 'LE'))
			v, n = file:read(4)
			if n ~= 4 then return false, errorString[9] end
			log("    SoundBlaster last used pos.: 0x%08X\n",
				util.bin2num(v, 'LE'))
			v, n = file:read(28)
			if n ~= 28 then return false, errorString[9] end
			sample.name = v
			log("    Sample name '%s' (%s)\n", sample.name,
			util.str2hex(sample.name, ' '))
			-- Verification
			-- v, n = file:read(4);
			-- if n ~= 4 then return false, errorString[9] end
			-- if v ~= 'SCRS' then return false, errorString[11] end
		elseif sample.type == 2 then
			-- AdLib
			file:seek(paraptrSmp[smp] + 0x4C)
			v, n = file:read(4)
			if n ~= 4 then return false, errorString[9] end
			if v ~= 'SCRI' then
				-- return false, errorString[12]
				-- Some modules might not correctly include this...
				log("    Warning: Subheader wasn't 'SCRI'; was '%s'!\n", v)
			end
			file:seek(paraptrSmp[smp] + 13)
			v, n = file:read(3)
			if n ~= 3 then return false, errorString[9] end
			if v ~= '\0\0\0' then
				log("    Mem offset wasn't zeroed: (%s)", util.str2hex(v, ' '))
			end
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2num(v)
			sample.modFrequencyMultiplier = v % 0x10; v = math.floor(v / 0x10)
			sample.modEnvelopeScaling     = v % 0x2;  v = math.floor(v / 0x2)
			sample.modSustainSound        = v % 0x2;  v = math.floor(v / 0x2)
			sample.modVibrato             = v % 0x2;  v = math.floor(v / 0x2)
			sample.modTremolo             = v % 0x2;
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2num(v)
			sample.carFrequencyMultiplier = v % 0x10; v = math.floor(v / 0x10)
			sample.carEnvelopeScaling     = v % 0x2;  v = math.floor(v / 0x2)
			sample.carSustainSound        = v % 0x2;  v = math.floor(v / 0x2)
			sample.carVibrato             = v % 0x2;  v = math.floor(v / 0x2)
			sample.carTremolo             = v % 0x2;
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2num(v)
			sample.modVolume = 0x3F - (v % 0x40); v = math.floor(v / 0x40)
			local l2 = v % 0x2; v = math.floor(v / 0x2)
			local l1 = v % 0x2;
			sample.modLevelScale = l2 * 0x2 + l1
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2num(v)
			sample.carVolume = 0x3F - (v % 0x40); v = math.floor(v / 0x40)
			local l2 = v % 0x2; v = math.floor(v / 0x2)
			local l1 = v % 0x2;
			sample.carLevelScale = l2 * 0x2 + l1
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2num(v)
			sample.modAttack = v % 0x10; v = math.floor(v / 0x10)
			sample.modDecay  = v % 0x10;
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2num(v)
			sample.carAttack = v % 0x10; v = math.floor(v / 0x10)
			sample.carDecay  = v % 0x10;
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2num(v)
			sample.modSustain = 0xF - (v % 0x10); v = math.floor(v / 0x10)
			sample.modRelease = v % 0x10;
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2num(v)
			sample.carSustain = 0xF - (v % 0x10); v = math.floor(v / 0x10)
			sample.carRelease = v % 0x10;
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			sample.modWaveform = util.bin2num(v)
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			sample.carWaveform = util.bin2num(v)
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			v = util.bin2num(v)
			sample.additiveSynthesis  = v % 0x2;  v = math.floor(v / 0x2)
			sample.modulationFeedback = v % 0x10; v = math.floor(v / 0x2)
			v, n = file:read(1) -- Unused.
			log("    Additive synthesis:  %s\n",
				sample.additiveSynthesis == 1 and 'Y' or 'N')
			log("    Modulation Feedback: %s\n",
				sample.modulationFeedback == 1 and 'Y' or 'N')
			log("             Carrier Modulator\n")
			log("    Attack:     %02X       %02X\n",
				sample.carAttack, sample.modAttack)
			log("    Decay:      %02X       %02X\n",
				sample.carDecay, sample.modDecay)
			log("    Sustain:    %02X       %02X\n",
				sample.carSustain, sample.modSustain)
			log("    Release:    %02X       %02X\n",
				sample.carRelease, sample.modRelease)
			log("    Sustain:    %s        %s\n",
				sample.carSustainSound == 1 and 'Y' or 'N',
				sample.modSustainSound == 1 and 'Y' or 'N')
			log("    Volume:     %02X       %02X\n",
				sample.carVolume, sample.modVolume)
			log("    EnvScale:   %s        %s\n",
				sample.carEnvelopeScaling == 1 and 'Y' or 'N',
				sample.modEnvelopeScaling == 1 and 'Y' or 'N')
			log("    LvScale:    %01X        %01X\n",
				sample.carLevelScale, sample.modLevelScale)
			log("    FreqMul:    %02X       %02X\n",
				sample.carFrequencyMultiplier, sample.modFrequencyMultiplier)
			log("    Waveform:   %01X        %01X\n",
				sample.carWaveform, sample.modWaveform)
			log("    Vibrato:    %s        %s\n",
				sample.carVibrato == 1 and 'Y' or 'N',
				sample.modVibrato == 1 and 'Y' or 'N')
			log("    Tremolo:    %s        %s\n",
				sample.carTremolo == 1 and 'Y' or 'N',
				sample.modTremolo == 1 and 'Y' or 'N')
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			sample.volume = util.bin2num(v)
			log("    Volume:  0x%02X\n", sample.volume)
			v, n = file:read(1)
			if n ~= 1 then return false, errorString[9] end
			log("    DSK (?): 0x%02X\n", util.bin2num(v))
			file:read(2) -- Skip unused bytes.
			v, n = file:read(4)
			if n ~= 4 then return false, errorString[9] end
			sample.c4speed = util.bin2num(v, 'LE') -- C2spd originally.
			log("    C4 speed: 0x%08X (%d)\n",
				sample.c4speed, sample.c4speed)
			file:read(12) -- Skip unused bytes.
			v, n = file:read(28)
			if n ~= 28 then return false, errorString[9] end
			sample.name = v
			log("    Sample name '%s' (%s)\n", sample.name,
			util.str2hex(sample.name, ' '))
			-- Verification
			-- v, n = file:read(4);
			-- if n ~= 4 then return false, errorString[9] end
			-- if v ~= 'SCRI' then return false, errorString[13] end
		end
		-- The SSG Drums aren't implemented in ST3 either.
		-- Neither are the second set of 9 FM OPs.
		log("\n")
		structure.sample[smp] = sample
	end
	log("\n")

	--[[Patterns]]--

	-- There's a bug here with having disabled channels before enabled ones makes the enabled ones be empty...

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

	structure.pattern = {}
	for pat = 0, structure.patternCount-1 do
		local pattern = {}
		-- Safety if a "fake" pattern is included that points to 0x000000
		if paraptrPat[pat] == 0 then
			structure.pattern[pat] = {}
			for row = 0, 63 do
				structure.pattern[pat][row] = {}
				for ch = 0, structure.channelCount-1 do
					structure.pattern[pat][row][structure.channel[ch].map] = {}
				end
			end
		else
			file:seek(paraptrPat[pat])
			log("Pattern 0x%04X at 0x%06X ", pat, paraptrPat[pat])
			v, n = file:read(2)
			if n ~= 2 then return false, errorString[14] end
			local packedSize = util.bin2num(v, 'LE')
			log("Packed Size: %04X bytes\n", packedSize)
			packedSize = packedSize - 2 -- Don't count length short.
			v, n = file:read(packedSize)
			if n ~= packedSize then return false, errorString[14] end
			local packedData = v
			local ptr = 1
			local row = 0
			for row = 0, 63 do
				pattern[row] = {}
				for ch = 0, structure.channelCount-1 do
					pattern[row][structure.channel[ch].map] = {}
				end
			end
			while ptr <= packedSize do
				local byte = util.bin2num(packedData:sub(ptr,ptr))
				if byte ~= 0 then
					local ch = byte % 0x20
					byte = math.floor(byte / 0x20)
					local cell = {}
					local ni = byte % 0x2
					byte = math.floor(byte / 0x2)
					if ni == 1 then
						if ch <= structure.channelCount-1 then
							cell.note = util.bin2num(
								packedData:sub(ptr+1,ptr+1))
							cell.instrument = 
								util.bin2num(packedData:sub(ptr+2,ptr+2))
						end
						ptr = ptr + 2
					end
					local vl = byte % 0x2
					byte = math.floor(byte / 0x2)
					if vl == 1 then
						if ch <= structure.channelCount-1 then
							cell.volume = util.bin2num(
							packedData:sub(ptr+1,ptr+1))
						end
						ptr = ptr + 1
					end
					local fx = byte
					if fx == 1 then
						if ch <= structure.channelCount-1 then
							cell.effectCommand =
								util.bin2num(packedData:sub(ptr+1,ptr+1))
							cell.effectData =
								util.bin2num(packedData:sub(ptr+2,ptr+2))

							--[[ Quoting the OpenMPT source verbatim:
Try to find out if Zxx commands are supposed to be panning commands (PixPlay).
Actually I am only aware of one module that uses this panning style, namely
"Crawling Despair" by $volkraq and I have no idea what PixPlay is, so this code
is solely based on the sample text of that module. We won't convert if there
are not enough Zxx commands, too "high" Zxx commands or there are only "left"
or "right" pannings (we assume that stereo should be somewhat balanced), and
modules not made with an old version of ST3 were probably made in a tracker
that supports panning anyway. --]]
							-- That said, this doesn't support most OpenMPT
							-- specific additions to modules anyway, so Zxx can
							-- only be PixPlay 16-valued panning, and not
							-- MIDI macros.
							if cell.effectCommand == 26 and
								cell.effectData < 0x10 then
									isPixPlay = true
									-- Convert to S8x
									cell.effectCommand = 19
									cell.effectData = cell.effectData + 0x80
							end
						end
						ptr = ptr + 2
					end
					pattern[row][structure.channel[ch].map] = cell
					ptr = ptr + 1
				else
					row = row + 1
					ptr = ptr + 1
				end
			end
			for row = 0, 63 do
				log("    |")
				for ch = 0, structure.channelCount-1 do
					local cell = pattern[row][structure.channel[ch].map]
					log("%3s %2s v%2s %1s%2s|",
						cell.note and
							noteTf(cell.note) or '...',
						cell.instrument and
							("%02X"):format(cell.instrument) or '..',
						cell.volume and
							("%02X"):format(cell.volume) or '..',
						cell.effectCommand and
							string.char(string.byte('A') +
								cell.effectCommand - 1)
							or '.',
						cell.effectData and
							("%02X"):format(cell.effectData) or '..')
				end
				log("\n")
			end
			structure.pattern[pat] = pattern
		end
	end
	log("\n")

	--[[Sample Waveform Data]]--

	for wfm = 0, structure.sampleCount-1 do
		if structure.sample[wfm].type == 1 then
			file:seek(structure.sample[wfm].wfOffset)
			log("Sample 0x%04X waveform at 0x%06X: ",
				wfm, structure.sample[wfm].wfOffset)
			if structure.sample[wfm].length > 0 then
				structure.sample[wfm].data = love.sound.newSoundData(
					structure.sample[wfm].length,
					8000, -- Doesn't matter.
					structure.sample[wfm].bitDepth,
					structure.sample[wfm].channelCount)
				local z = structure.sample[wfm].bitDepth / 8
				v, n = file:read(structure.sample[wfm].length * z);
				if n ~= structure.sample[wfm].length * z then
					return false, errorString[15]
				end
				for smp = 0, structure.sample[wfm].length-1 do
					if structure.sample[wfm].packingScheme == 0 then
						local ofs = smp * z
						if structure.sampleFormat == 'Signed' then
							local x = util.bin2num(v:sub(ofs+1, ofs+1+(z-1)),
								'LE')
							x = x >= ((2^(8*z))/2) and -((2^(8*z))-x) or x
							structure.sample[wfm].data:setSample(smp, (x/128))
						elseif structure.sampleFormat == 'Unsigned' then
							local x = util.bin2num(v:sub(ofs+1, ofs+1+(z-1)),
								'LE')
							structure.sample[wfm].data:setSample(smp,
								(x-((2^(8*z))/2))/(2^(8*z))
							)
						end
					else --if structure.sample[wfm].packingScheme == 1 then
						-- TODO: Figure out the specific DP30ADPCM format.
					end
				end
				log("Loaded.\n")
			else
				log("Was empty.\n")
			end
		end
	end

	--[[Finalization]]--

	-- Build moduletype string
	local cwtinfo = {}

	if cwtStrings[cwt] then
		if cwt == 0xC then
			table.insert(cwtinfo, cwtStrings[cwt])
			table.insert(cwtinfo, "")
		elseif cwt == 0x4 then
			if version <  0x020 then
				-- Proper Schism version
				table.insert(cwtinfo, cwtStrings[cwt])
			elseif version == 0x020 then
				table.insert(cwtinfo, cwtStrings[cwt])
				table.insert(cwtinfo, " v0.2a+ (2005-2007)")
			elseif version == 0x050 then
				table.insert(cwtinfo, cwtStrings[cwt])
				table.insert(cwtinfo, " v?.?? (2007-2009)")
			elseif version == 0x100 then
				-- 4100 can be BeRoTracker circa 2004-2012
				table.insert(cwtinfo, "BeRoTracker")
				table.insert(cwtinfo, " v1.00 (2004-2012)")
			elseif version >= 0x050 then
				-- SchismTracker timestamps
				table.insert(cwtinfo, cwtStrings[cwt])
				local epoch = os.time{year=2009, month=10, day=31}
				local ts = os.date("%Y.%m.%d", epoch + (version - 0x050)*86400)
				if version == 0xfff then
					table.insert(cwtinfo, "Timestamp: 2020.10.27+")
				else
					table.insert(cwtinfo, "Timestamp: " .. ts)
				end
			end
		elseif cwt == 0x1 then
			if version == 0x300 then
				structure.fastVolSlides = true
				table.insert(cwtinfo, cwtStrings[cwt])
			elseif version == 0x320 and
				--specptr == 0x0 and
				initialPanning and ucremoval == 0 and
				structure.orderCount % 16 == 0 and
				not structure.st2vibrato and
				not structure.st2tempo and
				not structure.amigaslides and
				not structure.killSilentLoops and
				not structure.SBFilterEffects and
				not structure.customdata
			then
				table.insert(cwtinfo, "ModPlug Tracker")
				table.insert(cwtinfo, "")
			elseif version == 0x320 and
				--specptr == 0x0 and
				not initialPanning and ucremoval == 0 and
				not structure.st2vibrato and
				not structure.st2tempo and
				not structure.amigaslides and
				not structure.killSilentLoops and
				not structure.amigaNoteLimits and
				not structure.SBFilterEffects and
				not structure.fastVolSlides and
				not structure.customdata
			then
				table.insert(cwtinfo, "Velvet Studio")
				table.insert(cwtinfo, "")
			elseif not (ucremoval == 8 or ucremoval == 12 or
				ucremoval == 16 or ucremoval == 24)
			then
				table.insert(cwtinfo, "Other ST320 compatible Tracker")
				table.insert(cwtinfo, "")
			end
		else
			table.insert(cwtinfo, cwtStrings[cwt])
		end
	else
		table.insert(cwtinfo, "Unknown Tracker")
	end

	if #cwtinfo == 1 then
		-- Generic version number
		table.insert(cwtinfo, " v" .. math.floor(version / 0x100) ..
			"." .. version % 0x100)
	end

	if isPixPlay then
		cwtinfo[1] = "PixPlay (CRAWLING.S3M)"
		cwtinfo[2] = ""
	end
	
	structure.moduleType = ("Scream Tracker 3 module" ..
			"(Created with %s)"):format(table.concat(cwtinfo))

	structure.fileType = 's3m'

	log("-- /Scream Tracker 3 S3M loader/ --\n\n")
	return structure
end

---------------
return load_s3m