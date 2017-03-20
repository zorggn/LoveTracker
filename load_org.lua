-- Organya "Org" importer/parser
-- by zorg @ 2017 § ISC
-- Original format by Pixel (天谷 大輔 〜 Amaya Daisuke)

-- Note: The given per-track event format is not suited for editing, since each
--       edit could potentially reorder the events; nevertheless, for a simple
--       playback routine, it is sufficient.

--[[
	Structure definition:
		version            - 1,2,3
		tickRate           - 1..2000 ms
		beatPerBar         - beats
		tickPerBeat        - ticks
		loopStart          - 0x0..0xFFFFFFFF tick
		loopEnd            - 0x0..0xFFFFFFFF tick
		tempo              - calculated, BPM
		eventSum           - events
		track[]            - 0..15
			finetune       - 100..1900
			instrument     - 0..99 (melodic) or 0..11 (percussive)
			pizzicato      - 0,1
			eventCount     - 0..4096 events
		event[]            - 0..15
			firstLoopEvent - calculated, tick
			[]             - eventCount (per-track, see above)
				position   - 0x00........0xFFFFFFFF, tick
				pitch      - 0x00..0x2D..0x5F, 0xFF continue
				length     - 0x00........0xFE, 0xFF continue, ticks
				volume     - 0x00..0xC8..0xFE, 0xFF continue
				panning    - 0x00..0x06..0x0C, 0xFF continue
--]]

local util = require('util')
local log = function(str,...) io.write(string.format(str,...)) end

local definedTimeSignatures = {
	['4/4'] = true, ['3/4'] = true, ['4/3'] = true, ['3/3'] = true,
	['6/4'] = true, ['6/3'] = true, ['2/4'] = true, ['8/4'] = true,
}

local errorString = {
	--[[1]] "File header did not start with 'Org-'.",
	--[[2]] "Unsupported format version.",
	--[[3]] "Early end-of-file in header.",
	--[[4]] "Early end-of-file in track properities.",
	--[[5]] "Early end-of-file in event list.",
}

local load_org = function(file)
	log("--  Organya ORG loader  --\n\n")
	local structure = {}
	file:open('r')



	local formatstring = file:read(6)
	if formatstring:sub(1,4) ~= "Org-" then return false, errorString[1] end
	structure.version  = formatstring:sub(-2)
	log("Format string:   %s\n", formatstring)

	local allowed = {['01'] = true, ['02'] = true, ['03'] = true}
	if not allowed[structure.version] then return false, errorString[2] end
	structure.version = tonumber(structure.version)
	log("Format version: %2d\n", structure.version)

	local v,n

	v,n = file:read(2); if n ~= 2 then return false, errorString[3] end
	structure.tickRate    = util.bin2num(v, 'LE')
	log("Tick rate:    %4d ms\n", structure.tickRate)

	v,n = file:read(1); if n ~= 1 then return false, errorString[3] end
	structure.beatPerBar  = string.byte(v)
	log("Beats/Bar:     %3d\n",   structure.beatPerBar)

	v,n = file:read(1); if n ~= 1 then return false, errorString[3] end
	structure.tickPerBeat = string.byte(v)
	log("Ticks/Beat:    %3d\n",   structure.tickPerBeat)

	if not definedTimeSignatures[('%d/%d'):format(
		structure.tickPerBeat, structure.beatPerBar)]
	then
		log("Time signature not one of the predefined ones; file probably " ..
			"not made with OrgMaker.\n")
	end

	v,n = file:read(4); if n ~= 4 then return false, errorString[3] end
	structure.loopStart   = util.bin2num(v, 'LE')
	log("Loop start:  %5d. beat / %3d. bar\n", structure.loopStart,
		structure.loopStart / structure.beatPerBar / structure.tickPerBeat)

	v,n = file:read(4); if n ~= 4 then return false, errorString[3] end
	structure.loopEnd     = util.bin2num(v, 'LE')
	log("Loop end:    %5d. beat / %3d. bar\n", structure.loopEnd,
		structure.loopEnd   / structure.beatPerBar / structure.tickPerBeat)

	if  ((structure.loopStart / structure.beatPerBar / structure.tickPerBeat)
		% 1.0 ~= 0.0) or
		((structure.loopEnd   / structure.beatPerBar / structure.tickPerBeat)
		% 1.0 ~= 0.0) 
	then
		log("One or both loop points not bar-aligned; file probably " ..
			"not made with OrgMaker.\n")
	end

	structure.tempo       = 6e4 / (structure.tickRate * structure.tickPerBeat)
	log("Tempo:        %9.4f BPM (calculated)\n\n", structure.tempo)



	structure.eventSum    = 0
	structure.track = {}
	for i=0, 15 do
		local inst = {}

		log("Track %1X %s ", i, (i<8 and "(Melodic)   " or "(Percussive)"))

		v,n = file:read(2); if n ~= 2 then return false, errorString[4] end
		inst.finetune   = util.bin2num(v, 'LE')
		log("Finetune %4d ", inst.finetune)
		--if finetune > 1999 then return false end

		v,n = file:read(1); if n ~= 1 then return false, errorString[4] end
		inst.instrument = string.byte(v)
		log("Instrument %2d ", inst.instrument)
		--if (i>7 and inst.instrument > 11) or (inst.instrument > 99) then
			--return false
		--end

		v,n = file:read(1); if n ~= 1 then return false, errorString[4] end
		inst.pizzicato  = string.byte(v)
		log("Pi %1d ", inst.pizzicato)
		--if inst.pizzicato > 1 then return false end

		v,n = file:read(2); if n ~= 2 then return false, errorString[4] end
		inst.eventCount = util.bin2num(v, 'LE')
		log("Events %4d (%4d remaining)\n", inst.eventCount,
			16^3 - inst.eventCount)
		--if inst.eventCount > 4095 then return false end

		structure.eventSum = structure.eventSum + inst.eventCount
		structure.track[i] = inst
	end

	log("Total events: %5d (%5d remaining)\n\n", structure.eventSum,
		16^4 - structure.eventSum)



	structure.event = {}
	local fields = {'pitch', 'length', 'volume', 'panning'}
	for i=0, 15 do
		local track = {}

		for j=0, structure.track[i].eventCount-1 do
			track[j] = {}
			v,n = file:read(4); if n ~= 4 then return false, errorString[5] end
			track[j].position = util.bin2num(v, 'LE')
			if not track.firstLoopEvent and
				track[j].position >= structure.loopStart
			then
				track.firstLoopEvent = j
			end
		end
		if not track.firstLoopEvent then
			track.firstLoopEvent = math.max(structure.track[i].eventCount-1, 0)
		end

		for k=1, #fields do	
			for j=0, structure.track[i].eventCount-1 do
				v,n = file:read(1)
				if n ~= 1 then return false, errorString[5] end
				track[j][fields[k]] = string.byte(v)
			end
		end

		for j=0, structure.track[i].eventCount-1 do
			log("Track %0.1X Event %0.3X Position %0.8X Pitch %0.2X " .. 
				"Length %0.2X Volume %0.2X Panning %0.2X\n",
				i, j, track[j].position, track[j].pitch, track[j].length,
				track[j].volume, track[j].panning)
		end

		if structure.track[i].eventCount > 0 then log("\n") end
		structure.event[i] = track
	end



	structure.moduleType = ("Organya Org-%0.2d"):format(structure.version)
	log("\n\n-- /Organya ORG loader/ --\n\n")
	return structure
end

---------------
return load_org