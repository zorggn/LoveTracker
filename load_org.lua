-- Organya "ORG" not-quite-module file importer/parser
-- by zorg @ 2017 § ISC

-- See doc/orgspecs_v1_1.txt for references.

local log = function(str,...)
	print(string.format(str,...))
end
local util = require('util')

-- The structure of the file kept in memory:
--[[

	string - fileType       -- The extension of the file. (Added in loader.lua)
	string - moduleType     -- What subtype this file is;
	                        -- For org files, it'll always be "Organya Org-", appended by a two-character version number.
	number - version        -- The version number.

	number - Tempo          -- Tickrate in ms
	number - Steps/Bar      --
	number - Beats/Step     --
	number - Loop beginning --
	number - Loop End       --

	table  - Instruments    -- A table of 16 instrument properity definitions; first 8 melodic, last 8 percussive.
		number  - Pitch
		number  - Instrument
		boolean - Pizzicato
		number  - Number of Notes

	table - Song            -- A table containing the song data.
		table - Track
			table - position events
			table - pitch events
			table - length events
			table - volume events
			table - pan events

	-- Note that this is the format the serialized files have; it might make more sense to store the data a bit differently in memory...

--]]

local load_org = function(file)

	-- The table where all the data will live.
	local structure = {}

	-- Here on through comes the fun part!
	file:open('r')

	---------------------------------------------------------------------------
	-- Read in global info from header
	---------------------------------------------------------------------------

	-- Format version.

	local formatstring = file:read(6)

	log("Format string: %s", formatstring)

	structure.version = tonumber(formatstring:sub(-2)) -- Last two characters.

	log("Format version: %d\n", structure.version)

	-- Tempo in milliseconds.

	structure.tempo = util.ansi2number(file:read(2), 'LE')

	log("Tempo (ms): %d", structure.tempo)

	-- Steps per Bar & Beats per Step

	structure.stepsPerBar  = string.byte(file:read(1))
	structure.beatsPerStep = string.byte(file:read(1))

	-- 92 ms -> 108 BMP (4/6)
	-- 1 beat == 92 ms/beat
	-- 6 beats / step
	-- 1 step == 92 ms * 6 = 552 ms/step
	-- ^-1 -> 1/552 step/ms
	-- 60000 ms/min / 552 step/ms ~ 108(.69) BPM

	log("BPM (Calculated): %f\n", 60000 / (structure.tempo * structure.beatsPerStep))

	log("Steps per Bar  (Beat in OrgMaker): %d", structure.stepsPerBar)
	log("Beats per Step (Step in OrgMaker): %d", structure.beatsPerStep)

	log("")

	-- Loop beginning and end

	structure.loopStart = util.ansi2number(file:read(4), 'LE')
	structure.loopEnd   = util.ansi2number(file:read(4), 'LE')

	log("Loop beginning (steps/bars): %5d, %3d", structure.loopStart, structure.loopStart /structure.stepsPerBar/structure.beatsPerStep)
	log("Loop end       (steps/bars): %5d, %3d", structure.loopEnd,   structure.loopEnd   /structure.stepsPerBar/structure.beatsPerStep)

	---------------------------------------------------------------------------
	-- Read in per-track instrument info from header
	---------------------------------------------------------------------------

	log("")

	local noteCountSum = 0

	structure.instruments = {}

	for i=0, 15 do

		local inst = {}

		inst.finetune   = util.ansi2number(file:read(2), 'LE')
		inst.instrument = string.byte(file:read(1))
		inst.pizzicato  = string.byte(file:read(1))
		inst.noteCount  = util.ansi2number(file:read(2), 'LE')

		noteCountSum = noteCountSum + inst.noteCount

		log("Instrument %2d (%s) finetune: %4d instrument: %2d pizzicato: %1d note count: %4d remaining: %4d",
			i, (i<8 and "Melo." or "Perc."), inst.finetune, inst.instrument, inst.pizzicato, inst.noteCount, 4096-inst.noteCount)

		structure.instruments[i] = inst
	end

	log("Total note count: %5d remaining: %5d", noteCountSum, 65536 - noteCountSum)

	---------------------------------------------------------------------------
	-- Read in song data
	---------------------------------------------------------------------------

	-- Thankfully we don't need to seek anywhere, since the data is neatly laid out sequentially... more or less.

	log("")

	structure.song = {}

	-- Only for the byte-sized parameters.
	local fields = {'pitch', 'length', 'volume', 'panning'}

	-- Tracks
	for i=0, 15 do

		local track = {}

		for j=0, structure.instruments[i].noteCount-1 do
			track[j] = {}
			track[j].position = util.ansi2number(file:read(4), 'LE')
		end

		for k=1, #fields do	
			for j=0, structure.instruments[i].noteCount-1 do
				track[j][fields[k]] = string.byte(file:read(1))
			end
		end

		for j=0, structure.instruments[i].noteCount-1 do
			--log("Track %0.1X Event %0.3X Position %0.8X Pitch %0.2X Length %0.2X Volume %0.2X Panning %0.2X",
			--	i, j, track[j].position, track[j].pitch, track[j].length, track[j].volume, track[j].panning)
		end

		structure.song[i] = track

	end

	---------------------------------------------------------------------------
	-- Finalization
	---------------------------------------------------------------------------

	structure.moduleType = string.format("Organya Org-%0.2d", structure.version)

	return structure
end

---------------
return load_org