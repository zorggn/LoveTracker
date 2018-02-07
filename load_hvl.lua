-- Hively Tracker HVL importer/parser
-- by zorg @ 2017 § ISC
-- Format by Xeron/IRIS;
-- Also supports Abyss' Highest Experience AHX/THX modules.
-- Original format by Pink/Abyss, Dexter/Abyss, though the format started with
-- a 'T' instead of an 'A' originally; inspired by the C64's SID chip.

-- Note: Since Dexter is not inclined to release the source code for his own
--       playroutine, and i have zero inclination of reverse-engineering his
--       THX library (even though IDA gives back a pretty clean disassembly),
--       the playroutine will instead be based sorely on Hively Tracker code,
--       which, judging from the function names, came from the same angle. :3

-- Note: As seen by the below comments, some variables are 1-based, while other
--       ones are 0-based... errors galore if one's not careful. Thanks, Dex.

--[[
	Structure definition:
		id                             - [0,2]; what replayer we need to use.

		speed                          - [0,3]; speed multiplier (50Hz * (x+1))

		orderCount                     - [1,999]; position list length.
		orderRestart                   - [0,orderCount-1]; restart position.
		rowCount                       - [1,64]; rows in a track.
		trackCount                     - [0,255]; 0-based, but it has a flag!
		instrumentCount                - [0,63]
		subSongCount                   - [0,255]; 0 means no sub-songs defined!

		subSong[]                      - List of sub-songs.
			*                          - [1,orderCount]
		order[]                        - List of orders.
			*[]
				order                  - [0,trackCount]
				transpose              - [-0x80,0x7F] or signed byte...
		track[]                        - List of tracks.
			*[]
				note                   -
				instrument             -
				command                -
				data                   -
		instrument[]                   - List of instruments
			*[]
				.


--]]

local util = require('util')
local log = require('log')
local bit = require('bit')

-- Used here for debug purposes.
local noteToString
do
	local N = {'C-','C#','D-','D#','E-','F-','F#','G-','G#','A-','A#','B-'}
	noteToString = function(note)
		if note == 0 then
			return '---'
		elseif note <=60 then
			local n = note - 1
			local oct = math.floor(n / 12) + 1
			local ptc = n % 12
			return ('%2s%1s'):format(N[ptc+1], oct)
		end
		return '!!!'
	end
end

local errorString = {
	--[[1]] "Early end-of-file in header.",
	--[[2]] "Format ID not known.",
	--[[3]] "Invalid track length.",
	--[[4]] "Invalid instrument count.",
	--[[5]] "Early end-of-file in sub-song list.",
	--[[6]] "Early end-of-file in order list.",
	--[[7]] "Invalid track index in order list.",
	--[[8]] "Early end-of-file in track list.",
	--[[9]] "Invalid note value in track.",
	--[[A]] "Invalid parameter for command 0x0.",
	--[[B]] "Invalid command 0x4 for AHX0 subtype.",
	--[[C]] "Invalid parameter for command 0x4.",
	--[[D]] "Invalid parameter for command 0x9.",
	--[[E]] "Invalid parameter for command 0xC.",
	--[[F]] "Invalid parameter for command 0xE.",
	--[[G]] "Invalid parameter for command 0xD for AHX0 subtype.",
	--[[H]] "Parameter not legal BCD for command 0xD.",
	--[[I]] "Invalid parameter for command 0xD.",
	--[[J]] "Parameter not legal BCD for command 0xB.",
	--[[K]] "Invalid parameter for command 0xB.",
	--[[L]] "Invalid command detected.",
	--[[M]] "Early end-of-file in instrument list.",
	--[[N]] "Early end-of-file in instrument's playlist.",
	--[[O]] "Early end-of-file in names list.",
	--[[P]] "Illegal character found in names list.",
}

local acceptedID = {
	['THX\0'] = 0,
	['AHX\0'] = 0,
	['THX\1'] = 1,
	['AHX\1'] = 1,
	['HVL\0'] = 2,
}

local validTrackCommands = {
	[ 0x0 ] = true,    -- 0x00 - 0x09
	[ 0x1 ] = true,    -- 0x00 - 0xFF
	[ 0x2 ] = true,    -- 0x00 - 0xFF
	[ 0x3 ] = true,    -- 0x00 - 0xFF
	[ 0x4 ] = true,    -- 0x01 - 0x3F / 0x41 - 0x7F
	[ 0x5 ] = true,    -- 0x00 - 0xFF
	-- 0x6 doesn't exist.
	-- 0x7 doesn't exist.
	[ 0x8 ] = true,    -- 0x00 - 0xFF
	[ 0x9 ] = true,    -- 0x00 - 0x3F
	[ 0xA ] = true,    -- 0x00 - 0xFF
	[ 0xB ] = true,    -- (BCD value)
	[ 0xC ] = true,    -- 0x00 - 0x40 / 0x50 - 0x90 / 0xA0 - 0xE0
	[ 0xD ] = true,    -- (BCD value)
	[ 0xE ] = true,    -- 0xC0 - 0xCF / 0xD1 - 0xDF
	[ 0xF ] = true,    -- 0x00 - 0xFF
}

local Wavelength = {[0] = 0x04, 0x08, 0x10, 0x20, 0x40, 0x80}

local load_hvl = function(file)
	log("--  Abyss' Highest Experience AHX / Hively Tracker HVL loader  --\n\n")

	local structure = {}
	file:open('r')

	local v,n

	--[[Header]]--

	v, n = file:read(4); if n ~= 4 then return false, errorString[1] end
	if not acceptedID[v] then return false, errorString[2] end
	structure.id = acceptedID[v]
	log("ID detected at 0x00: %s\n", v)

	v, n = file:read(2); if n ~= 2 then return false, errorString[1] end
	-- We don't really need this loaded, it's the offset to the song title and
	-- sample names modulo 0xFFFF... meaning it's wrong for larger files.
	log("Song title offset at 0x%X\n", util.bin2num(v, 'BE'))

	v, n = file:read(1); if n ~= 1 then return false, errorString[1] end
	local temp = math.floor(string.byte(v) / 0x10)
	-- If bit is set, then the 0th track is not saved, the spec is wrong.
	local zerothTrackSaved = (math.floor(temp / 0x8) == 0)
	structure.speed = temp % 0x8 -- CIA timing multiplier, values 0-3 are valid.
	log("Zeroth track %s.\n", (zerothTrackSaved and 'saved' or 'not saved'))
	log("CIA multiplier: %dx (%d Hz)\n", (2 ^ structure.speed),
		(2 ^ structure.speed) * 50)
	if structure.id == 0 and structure.speed ~= 0 then
		log("Warning: AHX v1.00-v1.27 module with non-zero CIA multiplier.\n")
	end

	temp = string.byte(v) % 0x10
	v, n = file:read(1); if n ~= 1 then return false, errorString[1] end
	temp = temp * 0x100 + string.byte(v)
	structure.orderCount = temp
	if temp > 999 then
		temp = " (higher than allowed maximum of 999.)"
	elseif temp < 1 then
		temp = " (lower than allowed minimum of 1.)"
	else
		temp = ""
	end
	log("Order count: %d/999%s\n", structure.orderCount, temp)

	v, n = file:read(2); if n ~= 2 then return false, errorString[1] end
	structure.orderRestart = util.bin2num(v, 'BE')
	if structure.orderRestart > structure.orderCount - 1 then
		log("Invalid restart position, resetting to zero.\n")
		structure.orderRestart = 0
	end
	log("Restart point: %d\n", structure.orderRestart)

	v, n = file:read(1); if n ~= 1 then return false, errorString[1] end
	structure.rowCount = string.byte(v)
	if structure.rowCount < 1 or structure.rowCount > 64 then
		return false, errorString[3]
	end
	log("Row count (Track length): %d/64\n", structure.rowCount)

	v, n = file:read(1); if n ~= 1 then return false, errorString[1] end
	structure.trackCount = string.byte(v)
	-- Since we read in a byte, and the valid range is 0-255, this will always
	-- succeed.
	log("Track count: %d/%d\n", structure.trackCount,
		zerothTrackSaved and 256 or 255)

	v, n = file:read(1); if n ~= 1 then return false, errorString[1] end
	structure.instrumentCount = string.byte(v)
	if structure.instrumentCount > 63 then
		return false, errorString[4]
	end
	log("Instrument count: %d/64\n", structure.instrumentCount+1)

	v, n = file:read(1); if n ~= 1 then return false, errorString[1] end
	structure.subSongCount = string.byte(v)
	-- Since we read in a byte, and the valid range is 0-255, this will always
	-- succeed; 0 means no sub-songs!
	log("Sub-song count: %d/255\n", structure.subSongCount)

	log("\n")

	--[[Sub-song list]]--

	structure.subSong = {}
	log("Sub-songs: ")
	-- 0 entries is valid, meaning there are no sub-songs whatsoever.
	if structure.subSongCount > 0 then
		for i = 0, structure.subSongCount - 1 do
			v, n = file:read(2); if n ~= 2 then return false, errorString[5] end
			local ss = util.bin2num(v, 'BE')
			if ss > structure.orderCount - 1 then
				return false, errorString[6]
			end
			structure.subSong[i] = ss
			log("0x%2X, ", ss)
		end
	end

	log('\n\n')

	--[[Order list]]--

	structure.order = {}
	log("Orders:\n")
	for i = 0, structure.orderCount - 1 do
		local ord = {}
		-- 8 byte entry definition: 4 sets of track index + transpose value.
		for j = 0, 3 do
			ord[j] = {}
			v, n = file:read(1); if n ~= 1 then return false, errorString[6] end
			v = string.byte(v)
			-- Even if the 0th track is not saved, the indexing goes up to
			-- trackCount - 1... though this may be wrong, since
			-- Electric City has a 0th track used, with data, in its orders...
			-- in both AHX and hivelytracker.
			if v > structure.trackCount then
				return false, errorString[7]
			end
			ord[j].order = v

			v, n = file:read(1); if n ~= 1 then return false, errorString[6] end
			v = string.byte(v)
			-- The specs say that this value is signed [-0x80,0x7F], but
			-- AHX v2.3d-sp3 displays them as unsigned hex bytes...
			ord[j].transpose = v -- - 0x80
		end
		structure.order[i] = ord
		log("    %03d [%03d-%02X %03d-%02X %03d-%02X %03d-%02X]\n", i,
			ord[0].order, ord[0].transpose, ord[1].order, ord[1].transpose,
			ord[2].order, ord[2].transpose, ord[3].order, ord[3].transpose)
	end

	log('\n\n')

	--[[Track list]]--

	local param0 = 0

	structure.track = {}

	-- Init the zeroth as well, for safety.
	structure.track[0] = {}

	log("Tracks:\n")

	for i = 0, structure.trackCount - (zerothTrackSaved and 0 or 1) do
		local track = {}
		log("    Track %03d:\n", i)
		for j = 0, structure.rowCount - 1 do
			local row = {}

			-- Each row entry is 3 bytes long.
			-- NNNNNNII IIIICCCC DDDDDDDD
			-- Note Instrument Command Data
			v, n = file:read(3); if n ~= 3 then return false, errorString[8] end
			v = util.bin2num(v, 'BE')
			row.note       = math.floor(v / 0x40000)
			row.instrument = math.floor(v / 0x1000 ) % 0x40
			row.command    = math.floor(v / 0x100  ) % 0x10
			row.param      =            v            % 0x100

			log("        %2d|%3s %02d %1X%02X|\n", j,
				noteToString(row.note),
				row.instrument,
				row.command,
				row.param)

			if row.note > 60 then
				return false, errorString[9]
			end

			-- TODO: Modify these from errors to warnings... be more lenient.
			--       Or at least quadruple-check already working impl.-s.
			if validTrackCommands[row.command] then
				if     row.command == 0x0 then
					if row.param > 0x09 then
						-- Cactoos' 2 worki za malo has 090...
						--return false, errorString[10]
					else
						-- Needed for command 0xB check.
						param0 = row.param
					end
				elseif row.command == 0x4 then
					-- Electric City also contradicts the spec here,
					-- by using a 440 and a 400.
					if structure.id == 0 then
						--return false, errorString[11]
					--elseif (row.param > 0x7F) or
					-- Cactoos' 2 worki za malo has 4E0...
					--	(row.param > 0x3F and row.param < 0x40) then
					--	return false, errorString[12]
					end
				elseif row.command == 0x9 then
					if row.param > 0x3F then
						--return false, errorString[13]
					end
				elseif row.command == 0xC then
					if (row.param > 0x40 and row.param < 0x50) or
						(row.param > 0x90 and row.param < 0xA0) or
						(row.param > 0xE0) then
						-- Plastic Fools by Pink/Abyss has CEF...
						--return false, errorString[14]
					end
				elseif row.command == 0xE then
					-- This seems to be wrong in the spec... or
					-- Electric City by JazzCat uses an illegal E21 effect.
					--if (row.param < 0xC0) or (row.param > 0xDF) or
					--	(row.param > 0xCF and row.param < 0xD1) then
					--	return false, errorString[15]
					--end
				elseif row.command == 0xD then
					if structure.id == 0 and row.param ~= 0x00 then
						--return false, errorString[16]
					else
						local hi = math.floor(row.param / 0x10)
						local lo =            row.param % 0x10
						if hi > 9 or lo > 9 then
							--return false, errorString[17]
						elseif hi*10+lo >= structure.rowCount then
							--return false, errorString[18]
						end
					end
				elseif row.command == 0xB then
					local hi = math.floor(row.param / 0x10)
					local lo =            row.param % 0x10
					if hi > 9 or lo > 9 then
						--return false, errorString[19]
					elseif param0*100+hi*10+lo >= structure.trackCount then
						--return false, errorString[20]
					end
					-- reset the saved 0x0 command parameter.
					param0 = 0
				end
			else
				return false, errorString[21]
			end
			track[j] = row
		end
		structure.track[i] = track
	end

	log('\n\n')

	--[[Instrument list]]--

	structure.instrument = {}
	log('Instruments:\n')

	for i = 1, structure.instrumentCount do

		local ins = {}
		log('\t%2d:\n', i)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.masterVolume = string.byte(v)
		log('\tMaster Volume: %02d\n', ins.masterVolume)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.filterModulationSpeed = math.floor(string.byte(v) / 0x8)
		ins.wavelength = string.byte(v) % 0x8
		log('\tWavelength: %02X\n', Wavelength[ins.wavelength])

		-- ADSR
		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.attackLength = string.byte(v)
		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.attackVolume = string.byte(v)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.decayLength = string.byte(v)
		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.decayVolume = string.byte(v)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.sustainVolume = string.byte(v)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.releaseLength = string.byte(v)
		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.releaseVolume = string.byte(v)

		log('\tADSR Envelope data: %02X %02d | %02X %02d | %02X | %02X %02d\n',
			ins.attackLength, ins.attackVolume,
			ins.decayLength, ins.decayVolume,
			ins.sustainVolume,
			ins.releaseLength, ins.releaseVolume)

		-- Unused in AHX 0 and 1, they should be 0.
		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		log('\tUnused: %02X\n', string.byte(v))
		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		log('\tUnused: %02X\n', string.byte(v))
		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		log('\tUnused: %02X\n', string.byte(v))

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.filterModulationSpeed      = ins.filterModulationSpeed + 0x10 *
		                                 math.floor(string.byte(v) / 0x80) 
		ins.filterModulationLowerLimit = string.byte(v) % 0x80
		log('\tFilter mod lo limit: %02X\n', ins.filterModulationLowerLimit + 1)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.vibratoDelay = string.byte(v)
		log('\tVibrato delay: %03d\n', ins.vibratoDelay)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.releaseCut   = (math.floor(string.byte(v) / 0x80)) == 1
		ins.hardCut      = math.floor(string.byte(v) / 0x10) % 0x8
		ins.vibratoDepth =            string.byte(v) % 0x10
		log('\tCut: %02X (mode: %s)\n', ins.hardCut,
			(ins.releaseCut and 'release' or 'hard'))

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.vibratoSpeed = string.byte(v)
		log('\tVibrato speed: %02X\n', ins.vibratoSpeed)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.squareModulationLowerLimit = string.byte(v)
		log('\tSquare mod lo limit: %02X\n', ins.squareModulationLowerLimit)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.squareModulationUpperLimit = string.byte(v)
		log('\tSquare mod hi limit: %02X\n', ins.squareModulationUpperLimit)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.squareModulationSpeed = string.byte(v)
		log('\tSquare mod speed: %03d\n', ins.squareModulationSpeed)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.filterModulationSpeed      = ins.filterModulationSpeed + 0x20 *
		                                 math.floor(string.byte(v) / 0x80)
		ins.filterModulationUpperLimit = string.byte(v) % 0x80
		log('\tFilter mod hi limit: %02X\n', ins.filterModulationUpperLimit + 1)
		log('\tFilter mod speed: %02X\n', ins.filterModulationSpeed)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.playlistDefaultSpeed = string.byte(v)
		log('\tPlaylist default speed: %02X\n', ins.playlistDefaultSpeed)

		v, n = file:read(1); if n ~= 1 then return false, errorString[22] end
		ins.playlistEntryCount = string.byte(v)
		log('\tPlaylist entry count: %02X\n', ins.playlistEntryCount)

		-- Load in entries in the instrument's playlist... bad terminology :c
		ins.playlistEntry = {}
		log('\tEntries:\n')
		for j=1, ins.playlistEntryCount do
			local entry = {}
			log('\t\t')

			v,n = file:read(2); if n ~= 2 then return false,errorString[23] end
			v = util.bin2num(v, 'BE')
			--log("Instrument " .. j .. ": " .. ('%04X'):format(v)) log('\t\t')
			entry.command1  =  math.floor(v / 0x2000)
			entry.command0  =  math.floor(v / 0x400 ) % 0x8
			entry.waveform  =  math.floor(v / 0x80  ) % 0x8
			entry.fixedNote =  bit.band(math.floor(v / 0x40  ), 0x1) == 1
			entry.note      =             v % 0x40
			--log("\tfixed: " .. entry.fixedNote .. "\tnote: " .. entry.note)
			--log('\n\t\t')

			v,n = file:read(1); if n ~= 1 then return false,errorString[23] end
			entry.data0 = string.byte(v)

			v,n = file:read(1); if n ~= 1 then return false,errorString[23] end
			entry.data1 = string.byte(v)

			-- Command 6 is actually C, 7 is F, although since it's represented
			-- as 3 bits, it stays.

			log('%03d|%3s%1s|%1d|%1X%02X|%1X%02X\n',
				j-1,
				noteToString(entry.note),
				(entry.fixedNote and '*' or ' '),
				entry.waveform,
				entry.command0 == 6 and 0xC or (entry.command0 == 7 and 0xF
					or entry.command0),
				entry.data0,
				entry.command1 == 6 and 0xC or (entry.command1 == 7 and 0xF
					or entry.command1),
				entry.data1)

			ins.playlistEntry[j] = entry
		end

		log('\n')

		structure.instrument[i] = ins

	end

	log('\n\n')

	--[[Comment list]]--

	log('Comment list:\n')

	-- TODO: validate chars (0,[32-126],[128-255])
	local pattern = '[^%z\32-\126\128-\255]'

	for i = 0, structure.instrumentCount do
		local text = {}

		while true do
			v,n = file:read(1); if n ~= 1 then return false,errorString[24] end
			if string.find(v, pattern) then
				return false, errorString[25]
			end
			text[#text+1] = v
			if v == '\0' then break end
		end

		-- The zeroth is the actual title of the song.
		if i == 0 then
			structure.songTitle = table.concat(text)
			log('\tSong Title: %s\n', structure.songTitle)
		else
			structure.instrument[i].name = table.concat(text)
			log('\t%2d. instrument name: %s\n', i, structure.instrument[i].name)
		end
	end

	log('\n\n')

	-- Tha E'd.

	structure.fileType = 'ahx'

	log("-- /Abyss' Highest Experience AHX / Hively Tracker HVL loader/ --\n\n")
	return structure
end

---------------
return load_hvl