-- Scream Tracker 3 "S3M" module file importer
-- by zorg @ 2016-2017 § ISC

local log = function(str,...)
	--print(string.format(str,...))
end
local util = require('util')

-- The structure of the module kept in memory:
--[[
	string - fileType     -- The extension of the module. (Added in loader.lua)
	string - moduleType   -- What tracker was the possible culprit that created this module;
	                      -- For s3m files, it'll always be "Scream Tracker 3", appended by a version number.

	string - title        -- Title of the module. (27 or 28 characters maximum)
	number - ordNum       -- Number of pattern orders. (0-based) 
	number - insNum       -- Number of instruments. (Samplers or AdLib OPL2 synth patches) (0-based)
	string - version      -- CWT/V value as a string; gets concatenated to the end of moduleType.
	number - globalVolume -- ~/64 [0,1] - Global volume multiplier.
	number - initialSpeed -- Row subdivision count, number of ticks under each row.
	number - initialTempo -- Speed of the interrupt handler; TimerRate = 1193180 / (Tempo * 2 / 5), magic number is
	                      -- PC timer (oscillator) rate in Hz.
	bool   - isStereo     -- If false, then every channel is panned to center.
	number - masterVolume -- Sample premultiplication. (only on SB, so probably everywhere now, iirc OpenMPT uses it
	                      -- as such)
	bool   - defaultPan   -- If true, panning values are stored, else they aren't. (which means what, exactly?
	                      -- center if false?)
	n : n  - channelMap   -- Correlates absolute channel ordinals with relative indices.
	                      -- (map[in-tracker index] -> file ch pos.)
	n : n  - channelPan   -- Uses same relative indices as above but stores 'L' or 'R' as panning values...
	                      -- probably amiga limits.
	number - chnNum       -- Number of actually used channels. (0-based)
	n : n  - orders       -- Array holding the order data.
	number - patNum       -- Number of distinct patterns. (0-based)

	instruments  -- Array holding instrument data
			type          -- 1 then sampler, 0 then empty, else OPL2.
			filename      -- DOS filename of sample.
			memPos        -- Position of the actual sample data in the file. (need to be multiplied by 16 first)
			smpLen        -- Length of the actual sample data.
			smpLoopStart  -- .
			smpLoopEnd    -- .
			volume        -- Sample volume.
			packingScheme -- Usually 0 for unpacked, can be 1 for DP30 ADPCM encoded...
			looping       -- If true, the sample loops.
			c4speed       -- "Base" playback rate of the sample.
			name          -- The sample name.
			data          -- Loaded samplepoints, the sample proper.

	patterns     -- Array holding pattern data.
			row            -- Holds column data from one row.
				channel       -- Holds cell data from one column. (and row)
					note         -- false, '^^', or numeric (12*15 possible values for 12 notes and 15 octaves...)
					instrument   -- Number.
					volumecmd    -- Volume column value.
					effectcmd    -- Effect column command.
					effectprm    -- Effect column parameter.

--]]

-- Expose this inside the structure...
local printp_s3m = function(row, nchan, console)

	local NOTE = {[0] = 'C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-'}

	local numcols = 0; for k,v in pairs(row) do numcols = numcols + 1 end

	if numcols > 0 then
		local vis = {}
		for k = 0, nchan-1 do
			if not row[k] then
				table.insert(vis,'|')
				table.insert(vis, '... .. .. ...')
			else
				table.insert(vis, '|')
				if row[k].note then
					if type(row[k].note) == 'string' then
						table.insert(vis, row[k].note)
					else
						local note = NOTE[row[k].note%12] .. tostring(math.floor(row[k].note/12)+1)
						table.insert(vis, note)
					end
				else
					table.insert(vis, '...')
				end
				table.insert(vis, ' ')
				if row[k].instrument then
					table.insert(vis, (('%02d'):format(row[k].instrument)))
				else
					table.insert(vis, '..')
				end
				table.insert(vis, ' ')
				if row[k].volumecmd then
					table.insert(vis, (('%02d'):format(row[k].volumecmd)))
				else
					table.insert(vis, '..')
				end
				table.insert(vis, ' ')
				if row[k].effectcmd then
					table.insert(vis, string.char(string.byte('A')+row[k].effectcmd-1))
				else
					table.insert(vis, '.')
				end
				if row[k].effectprm then
					table.insert(vis, (('%02X'):format(row[k].effectprm)))
				else
					table.insert(vis, '..')
				end
			end
		end
		table.insert(vis, '|')

		if console then
			log(table.concat(vis))
		else
			return table.concat(vis)
		end
	else
		-- visualize an empty row
		local vis = {}
			for i = 0, nchan-1 do
				table.insert(vis,'|')
				table.insert(vis, '... .. .. ...')
			end
			table.insert(vis,'|')

		if console then
			log(table.concat(vis))
		else
			return table.concat(vis)
		end
	end
end

function load_s3m(file)

	-- The table where all the data will live.
	local structure = {}

	-- Here on through comes the fun part!
	file:open('r')

	---------------------------------------------------------------------------
	-- Read in general information.
	---------------------------------------------------------------------------

	-- Check for s3m header.
	file:seek(44) -- 0x2C
	local header = file:read(4)
	if header ~= 'SCRM' then
		log("Invalid header '%s' (%s)", header, util.str2hex(header))
		return false
	end

	-- 0x00: Module title.
	file:seek(0)
	structure.title = file:read(28)
	log("Title: '%s' (%s)", structure.title, util.str2hex(structure.title))

	-- Other miscellanous information; these aren't retained in memory. (0x1C, 0x1D)
	local eof = file:read(1)
	log("Should be 0x1A, DOS TYPE command EOF marker: (%s)", util.str2hex(eof))

	local typ = file:read(1)
	log("If 0x10 then it is a ScreamTracker 3 module: (%s)", util.str2hex(typ))

	-- Ignore the next two bytes (or one short), they were for an expansion that never came...
	-- TODO: Should we actually see if they're 0x00 0x00 ?
	file:read(2)

	-- 0x20: Number of orders.
	structure.ordNum = util.ansi2number(file:read(2), 'LE')
	log("Number of orders: %d", structure.ordNum)
	if structure.ordNum > 256 then
		log("Number of orders greater than 256, fixing value to 256.")
		structure.ordNum = 256
	end

	-- 0x22: Number of instruments. Technical limit is 99, but as far as i read back, no tracker ever supported more
	-- than 32 back then.
	structure.insNum = util.ansi2number(file:read(2), 'LE')
	log("Number of samples: %d", structure.insNum)
	if structure.insNum > 99 then
		log("Number of samples greater than 99, fixing value to 99.")
		structure.insNum = 99
	end

	-- 0x24: Number of patterns.
	structure.patNum = util.ansi2number(file:read(2), 'LE')
	log("Number of patterns: %d", structure.patNum)
	if structure.patNum > 100 then
		log("Number of patterns greater than 100, fixing value to 100.")
		structure.patNum = 100
	end

	-- 0x26: Miscellaneous flags, most of them are ST3 specific, that doesn't affect playback. TODO
	--   1 - st2vibrato (not supported in st3.01)
	--   2 - st2tempo (not supported in st3.01)
	--   4 - amigaslides (not supported in st3.01) //probably logarithmic slides instead of linear? -zorg
	--   8 - 0-volume optimalizations: Automatically turn off looping notes whose volume is 0 for >2 note rows. Nope.
	--  16 - amiga limits + amiga compat issues...
	--  32 - enable filter/sfx (not supported) //amiga filter (simulation/emulation)? -zorg
	--  64 - ST3.00 volslides (a cwt value of 1300 also should set this if it isn't...) - Dxx -> 0th tick enabled too.
	-- 128 - 
	local flags = util.bin2bitfield(file:read(2), 'LE')

	-- 0x28: Created with tracker / version (CWT/V)
	-- 0x1300 - ST3.00 - volslides happen on every frame, not just non-T0 frames!
	-- 0x1301, 03, 20 -- ST3.01, 03, 20 - otherwise.
	local cwtv = util.ansi2number(file:read(2), 'LE')
	log("%X",cwtv)
	if  cwtv == 0x1300 then structure.version = '3.00' elseif
		cwtv == 0x1301 then structure.version = '3.01' elseif
		cwtv == 0x1303 then structure.version = '3.03' elseif
		cwtv == 0x1320 then structure.version = '3.20' else
		structure.version = 'unknown'
	end

	-- 0x2A: Sample Format -- 1: signed, 2: unsigned (2 is the usual case)
	-- We don't necessarily need to store this info. //Especially since it's module-global :/ -zorg
	local smpf = util.ansi2number(file:read(2), 'LE')
	if smpf == 1 then
		log("Sample format:   signed")
	elseif smpf == 2 then
		log("Sample format: unsigned")
	else
		log("Sample format unknown or errorenous; setting to unsigned.")
		smpf = 2
	end

	-- 0x2C: Skip header, since we already dealt with it.
	file:read(4)

	-- 0x30: Global volume: finalvol = vol[track] * (globalvol / 64)
	structure.globalVolume = util.ansi2number(file:read(1))
	log("Global volume: %d", structure.globalVolume)

	-- 0x31: Initial speed. (6 in mods)
	structure.initialSpeed = util.ansi2number(file:read(1))
	log("Initial speed: %d", structure.initialSpeed)

	-- 0x32: Initial tempo. (125 in mods)
	structure.initialTempo = util.ansi2number(file:read(1))
	log("Initial tempo: %d", structure.initialTempo)

	-- 0x33: Master volume: lower 7 bits are the volume, the 8th is whether mono (0) or stereo (1).
	-- TODO: is this correct?
	local mvol = util.ansi2number(file:read(1))
	structure.isStereo = math.floor(mvol / 128) == 1 and true or false
	structure.masterVolume = mvol>127 and mvol-128 or mvol -- This could probably be expressed in a nicer way.
	log("Master volume: %d", structure.masterVolume)
	log("Panning mode:  %s", (structure.isStereo and 'Stereo' or 'Mono'))

	-- 0x34: UltraClick removal: st3 specific, forget it.
	file:read(1)

	-- 0x35: Default panning: misleading name, if 252, then values are stored for each channel, else skip.
	local dpan = util.ansi2number(file:read(1))
	if dpan == 252 then
		structure.defaultPan = true
	else
		structure.defaultPan = false
	end
	log("Per-channel panning: %s", (structure.defaultPan and 'defined' or 'not defined'))

	-- 0x36: Expansion bytes, ignorable.
	file:read(8)

	-- 0x3E: Special pointer, not really used, flag usually not set either.
	file:read(2)

	---------------------------------------------------------------------------
	-- Calculate channel map.
	---------------------------------------------------------------------------

	-- Channels: Oh boy... so, count is not stored, but the state of them is... separately.
	-- Is it okay to not store the data for all channels? not like it uses THAT much memory...?
	-- (runtime channels use 35bytes worth of useful data, maybe a bit less...)
	-- In other words, even disabled channels may get stored in s3m files, but they won't be present in this field.
	-- Question is, why shouldn't we load in the disabled channels' data as well?
	-- Maybe we'd find some neat things hidden there...
	structure.channelMap = {}
	structure.channelPan = {}
	log('Loading channel map...\n')
	local pos = 0
	for i = 0, 31 do
		local n = util.ansi2number(file:read(1))
		-- OPL stuff if >= 16... 255 means it's disabled.
		if n < 16 then
			structure.channelMap[i] = pos
			log("    Channel %d mapped to %d.", i, pos)
			pos = pos + 1
			-- Not panning levels, only "orientation"...
			if n <= 7 then
				structure.channelPan[i] = 'L' -- 0x33 according to OpenMPT source, 0x3 according to FireLight tutorial.
			else
				structure.channelPan[i] = 'R' -- 0xCC according to OpenMPT source 0xC according to FireLight tutorial.
			end
		end
		-- Non-valid ones don't map to any channel, so they be nil... that is, until it's revealed that the code
		-- should support OPL stuff...
	end
	structure.chnNum = pos
	log("Channel count: %d", structure.chnNum)

	log('')

	---------------------------------------------------------------------------
	-- Order data loading and pattern count verification.
	---------------------------------------------------------------------------

	-- Initialize order list.
	structure.orders = {}
	for i=0,255 do
		structure.orders[i] = 255
	end
	log("Order list initialized, loading in order data...")

	-- Load in order data. (254 is skip, 255 is empty)
	for i = 0, structure.ordNum-1 do
		structure.orders[i] = util.ansi2number(file:read(1))
		log("Order #%d (%X): %d", i, i, structure.orders[i])
	end

	-- Fix pattern count. (Needed? Playroutine could just skip over marker (254) patterns, and stop at the first (255).)
	local oldPatNum = structure.patNum -- Needed for parapointer traversal.
	local oldOrdNum = structure.ordNum -- Not really needed anymore, just for comparing below.
	local actual = 0
	structure.patNum = 0
	for i = 0, structure.ordNum-1 do
		if structure.orders[i] < 254 then
			structure.orders[actual] = structure.orders[i]
			actual = actual + 1
			if structure.orders[i] > structure.patNum then
				structure.patNum = structure.orders[i]
			end
		end
	end
	structure.ordNum = actual
	log("Fixed order #:   %d (was %d)", structure.ordNum, oldOrdNum)
	log("Fixed pattern #: %d (was %d)", structure.patNum, oldPatNum)

	log('')

	---------------------------------------------------------------------------
	-- Read in parapointers.
	---------------------------------------------------------------------------

	-- Read instrument parapointers.
	local pptrSmp = {} -- max.  99, as before
	for i = 0, structure.insNum-1 do
		pptrSmp[i] = util.ansi2number(file:read(2), 'LE') * 16 -- <<4 (*16) for true seekable locations.
	end
	log("Loaded instrument parapointers.")

	-- Read pattern parapointers.
	local pptrPat = {} -- max. 100, as before
	for i = 0, oldPatNum-1 do
		pptrPat[i] = util.ansi2number(file:read(2), 'LE') * 16 -- Same as above.
	end
	log("Loaded pattern parapointers.")

	-- If defined, read default pan positions for each channel; [0,F]
	if structure.defaultPan then
		structure.defaultPan = {} -- //OpenMPT seems to treat both pan tables as one... -zorg
		for i = 0, 31 do
			structure.defaultPan[i] = util.ansi2number(file:read(1)) % 16 -- == x && 0xF, top nibble is garbage.
			-- If we previously detected that the module is mono, overrule panning to center.
			if not structure.isStereo then structure.defaultPan[i] = 7 end -- bit off to the left tho...
			log("Channel %d (%X) panning set to %d (%X).", i, i, structure.defaultPan[i], structure.defaultPan[i])
		end
	else
		log("Default panning table  doesn't exist.")
	end

	log('')

	---------------------------------------------------------------------------
	-- Read in instrument data.
	---------------------------------------------------------------------------

	structure.instruments = {}
	log('Loading in instrument data...')

	for i = 0, structure.insNum-1 do
		
		local instrument = {}
		log('')

		-- Go to start of instrument block.
		file:seek(pptrSmp[i])
		log("Seeked to %X", pptrSmp[i])

		-- +0x00: Instrument format.
		instrument.type = util.ansi2number(file:read(1))
		log("Sample %d type: %d (%s)", i, instrument.type,
			instrument.type == 1 and "Sampler" or (
				instrument.type == 0 and "Empty" or "Other"))
		
		if instrument.type == 1 then -- Sampler

			-- Validate that we're really inside an instrument block.
			file:seek(pptrSmp[i] + 76)
			local header = file:read(4)
			log("Instrument header should be SCRS: %s", header)
			if header ~= 'SCRS' then
				-- Invalid header, set instrument to empty, and go to next one...
				instrument.type = 0
				structure.instruments[i] = instrument
				break
			end

			-- We already read in the type byte.
			file:seek(pptrSmp[i] + 1)

			-- +0x01: DOS filename.
			instrument.filename = file:read(12)
			log("Sample #%d (%X) DOS filename: %s", i, i, instrument.filename)

			-- +0x0D: Sample position.
			local a,b,c = util.ansi2number(file:read(1)), util.ansi2number(file:read(1)), util.ansi2number(file:read(1))
			-- sample_pos = (a SHL 16) + ((c SHL 8) + b)
			instrument.memPos = b * 0x10 + c * 0x1000 + a * 0x100000 -- UL -> 32bit ok FIX LATER
			-- This one doesn't need to be multiplied by 16 / shifted left by 4!
			log("Sample position: (%X)", instrument.memPos)

			-- +0x10: Sample length.
			instrument.smpLen = util.ansi2number(file:read(2), 'LE')
			file:read(2) -- This short is not used since st3 only supports 64k max samplesizes.
			if instrument.smpLen > 64000 then
				log("Sample length of %d is bigger than 64k! Truncating...", instrument.smpLen)
				instrument.smpLen = 64000
			else
				log("Sample length: %d", instrument.smpLen)
			end

			-- +0x14: Sample loop start point.
			instrument.smpLoopStart = util.ansi2number(file:read(2), 'LE')
			file:read(2) -- This short is not used since st3 only supports 64k max samplesizes.
			log("Loop start point: %d", instrument.smpLoopStart)

			-- +0x18: Sample loop end point.
			instrument.smpLoopEnd = util.ansi2number(file:read(2), 'LE')
			file:read(2) -- This short is not used since st3 only supports 64k max samplesizes.
			log("Loop end point:   %d", instrument.smpLoopEnd)

			-- +0x1C: Sample volume.
			instrument.volume = util.ansi2number(file:read(1))
			log("Sample volume: %d (%X)", instrument.volume, instrument.volume)

			-- +0x1D: Unused, skip.
			file:read(1)

			-- +0x1E: Packing scheme. (should always be 0)
			instrument.packingScheme = util.ansi2number(file:read(1))
			-- if 1 then DP30ADPCM else unpacked (raw).
			log("Packing scheme: %s",
				instrument.packingScheme == 0 and 'Unpacked' or (
					instrument.packingScheme == 1 and 'DP30ADPCM' or 'Unknown'))

			-- +0x1F: Flags
			local flags = util.ansi2number(file:read(1))
			log("Flags: %X", flags)
			-- only one is implemented, looping.
			-- 1 looping
			-- 2 stereo sample (unsupported)
			-- 4 16bit sample (unsupported)
			if flags % 1 == 1 then
				instrument.looping = true
			else
				instrument.looping = false
			end
			log("Sample loop: %s", instrument.looping and 'Enabled' or 'Disabled')

			-- +0x20: c2spd (c4spd in reality)
			instrument.c4speed = util.ansi2number(file:read(2), 'LE')
			file:read(2) -- This short is not used.
			log("C4 Speed: %d", instrument.c4speed)

			-- Skip more irrelevant (nowadays anyway) bytes. (GUS sample data positioning, etc.)
			file:read(12)

			-- +0x30:Sample name
			instrument.name = file:read(28)
			log("Sample name: %s", instrument.name)

			-- Verification
			--print(("Should be the header again: %s"):format(file:read(4)))

			-- We read in the actual sample data after the patterns.

		elseif instrument.type == 0 then
			-- Empty.
		else
			-- Skip OPL2 for now.
		end

		-- Assign the local to our module structure table.
		structure.instruments[i] = instrument
		
	end

	log('')

	---------------------------------------------------------------------------
	-- Read in pattern data.
	---------------------------------------------------------------------------

	log("Loading in pattern data...")

	-- structure: 1-1 bytes for note, inst, vol, fx func, fx param (5 in total)
	-- * 64 rows
	-- * structure.chnNum channels
	-- * structure.numPtr patterns, in all

	structure.patterns = {}

	for i = 0, oldPatNum-1 do -- patterns

		local pattern = {}

		-- Go to start of pattern block.
		file:seek(pptrPat[i])
		log("Pat %X; Seeked to %X", i, pptrPat[i])

		-- We don't really need the packed size of the pattern blocks...
		local pps = util.ansi2number(file:read(2), 'LE')
		log("Packed pattern size: %X", pps)

		for j = 0, 63 do -- rows

			--log("Row %X", j)

			-- Holds row data
			local row = {}

			-- if r is 0, we reached the end of the row, else cols...
			repeat

				-- Read in the fields
				local r  = util.ansi2number(file:read(1))

				-- If the byte is not empty...
				if r ~= 0 then

					local ch  = bit.band(r,  0x1F) -- % 32 -- channel #
					--log("Chn %d", ch)

					-- Check for data in unused channels
					local dummy = false
					if ch > structure.chnNum-1 then
						--log("Data found in unused channel (%d)! Max is %d.", structure.channelMap[ch],
						--     structure.chnNum)
						dummy = true -- reads bytes but doesn't store them
					end

					-- Create entry for column (channel)
					if not dummy then
						row[structure.channelMap[ch]] = {}
					end
	
					local ni  = bit.band(r,  32) -- further read note, instrument bytes
					if ni == 32 then
						--log("Found note & instrument byte!")
						local note = util.ansi2number(file:read(1))
						local inst = util.ansi2number(file:read(1))
						if not dummy then
							if note == 255 then
								row[structure.channelMap[ch]].note = false
							elseif note == 254 then
								row[structure.channelMap[ch]].note = '^^ ' -- note cut (key off)
							else
								-- true note
								row[structure.channelMap[ch]].note = bit.rshift(note,4)*12 +
									bit.band(note, 0xF)
							end
							row[structure.channelMap[ch]].instrument = inst ~= 0 and inst or false  -- ...
						end
					else
						-- No data
						if not dummy then
							row[structure.channelMap[ch]].note = false
							row[structure.channelMap[ch]].instrument = false
						end
					end
	
					local vo  = bit.band(r,  64) -- further read volume col byte
					if vo == 64 then
						--log("Found volume column byte!")
						local volc = util.ansi2number(file:read(1))
						if not dummy then
							row[structure.channelMap[ch]].volumecmd = volc -- number, simple
						end
					else
						-- No data
						if not dummy then
							row[structure.channelMap[ch]].volumecmd = false
						end
					end
	
					local fx  = bit.band(r, 128) -- further read fx col command and param bytes
					if fx == 128 then
						--log("Found effect column byte!")
						local cmmnd = util.ansi2number(file:read(1))
						local param = util.ansi2number(file:read(1))
						if not dummy then
							row[structure.channelMap[ch]].effectcmd = cmmnd -- number...for now
							row[structure.channelMap[ch]].effectprm = param -- number, simple
						end
					else
						-- No data
						if not dummy then
							row[structure.channelMap[ch]].effectcmd = false
							row[structure.channelMap[ch]].effectprm = false
						end
					end
				end

			until (r == 0) -- Read in all channel data present in current row.

			pattern[j] = row

			-- This is for show.
			printp_s3m(row, structure.chnNum, true)

		end -- rows

		structure.patterns[i] = pattern

	end -- patterns

	log("Patterns loaded!")

	log('')

	---------------------------------------------------------------------------
	-- Read in sample data.
	---------------------------------------------------------------------------

	for i = 0, structure.insNum-1 do

		if structure.instruments[i].type == 1 then

			file:seek(structure.instruments[i].memPos)
			log("Seeked to %X", structure.instruments[i].memPos)

			local len = structure.instruments[i].smpLen > 0 and structure.instruments[i].smpLen or 1 -- merp
			structure.instruments[i].data = love.sound.newSoundData(len, 44100, 8, 1)

			-- Faster to process inside RAM than to read in from disk byte-by-byte.
			local buffer, cnt = file:read(len)

			-- Fill up sounddata with samplepoint values.
			for j = 0, structure.instruments[i].smpLen-1 do
				if smpf == 2 then
					-- Unsigned
					local x = util.ansi2number(buffer:sub(j,j))
					structure.instruments[i].data:setSample(j, (x-128)/256) -- normalize to [-1,1]
				elseif smpf == 1 then
					-- Signed -> convert to unsigned (x>127&-(256-x)|x)
					local x = util.ansi2number(buffer:sub(j,j))
					x = x > 127 and -(256-x) or x
					structure.instruments[i].data:setSample(j, (x/128)) -- normalize to [-1,1]
				end
			end
		end
	end

	log("Samples loaded!")

	log('')

	---------------------------------------------------------------------------
	-- Finalization
	---------------------------------------------------------------------------

	-- Only one type possible, so no heuristics needed; do append the version though.
	structure.moduleType = 'Scream Tracker 3 (v' .. structure.version .. ')'

	-- Expose row printing function
	structure.printRow = printp_s3m

	-- We're done! no lie! \o/                          ...yes lie, no AdLib OPL2 support for now.
	return structure
end

---------------
return load_s3m