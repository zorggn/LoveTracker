-- ..."MOD" importer/parser
-- by zorg @ 2017 § ISC
-- Original format by various people, ultimately based on
-- Ultimate Soundtracker by Karsten Obarski.



--[[ References used:
	https://source.openmpt.org/svn/openmpt/trunk/OpenMPT/soundlib/Load_mod.cpp
	https://github.com/schismtracker/schismtracker/blob/master/fmt/mod.c
	https://source.openmpt.org/svn/openmpt/trunk/OpenMPT/soundlib/Tables.cpp
	modland ftp format specs
	justsolvethefileformatproblem wiki
--]]



-- Note: The below implementation allows unknown pattern cell data into the
--       internal representation of the loaded modules; the playroutine itself
--       doesn't bork on such things, and they get shown graphically as such.

-- Note: Out of the four biggest tracker formats (mod,s3m,xm,it), the mod
--       format was technically first, so it should be the easiest to
--       implement... however, since it was the first, it was the prime format
--       for hacking/modifications to it. The result is that "mod" files are,
--       while similar in their stored state, a clusterfuck when considering
--       actual playback. The worst part's that the playback differences aren't 
--       even saved in the files themselves, meaning heuristics need to be
--       involved, and not even that can detect the correct playback mode 100%
--       of the time; some players/trackers may even do "fingerprinting",
--       determining the options from hard-coded lists of known module files...
--       ...which is definitely insane enough for me not to even attempt.

-- Note: Also, unlike the other loaders, this one will be heavily commented,
--       because frankly, there's just too many ways a mod file's contents
--       can be handled by this loader.

-- Note: Credits where credits are due, most of the hacks used in this came
--       from both SchismTracker's and OpenMPT's source code, purely because
--       i trust those implementations the most. Still, don't use my code as
--       reference, since it's probably full of errors still, and besides,
--       i know not what i'm doing. :3

-- Note: No more notes...



--[[
	Structure definition:

--]]

local util = require('util')
local log = require('log')

-- a Period table, because mod files store notes with amiga periods...
-- This is an extended table, from C-0 to B-4 instead of C-1 to B-3.
local periodTable = {}
periodTable[ 0] = {
	1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016,  960,  906,
	 856,  808,  762,  720,  678,  640,  604,  570,  538,  508,  480,  453,
	 428,  404,  381,  360,  339,  320,  302,  285,  269,  254,  240,  226,
	 214,  202,  190,  180,  170,  160,  151,  143,  135,  127,  120,  113,
	 107,  101,   95,   90,   85,   80,   75,   71,   67,   63,   60,   56}
periodTable[ 1] = {	 
	1700, 1604, 1514, 1430, 1348, 1274, 1202, 1134, 1070, 1010,  954,  900,
     850,  802,  757,  715,  674,  637,  601,  567,  535,  505,  477,  450,
     425,  401,  379,  357,  337,  318,  300,  284,  268,  253,  239,  225,
     213,  201,  189,  179,  169,  159,  150,  142,  134,  126,  119,  113,
     106,  100,   94,   89,   84,   79,   75,   71,   67,   63,   59,   56}
periodTable[ 2] = {	 
	1688, 1592, 1504, 1418, 1340, 1264, 1194, 1126, 1064, 1004, 948 , 894,
     844 , 796 , 752 , 709 , 670 , 632 , 597 , 563 , 532 , 502 , 474 , 447,
     422 , 398 , 376 , 355 , 335 , 316 , 298 , 282 , 266 , 251 , 237 , 224,
     211 , 199 , 188 , 177 , 167 , 158 , 149 , 141 , 133 , 125 , 118 , 112,
     105 , 99  , 94  , 88  , 83  , 79  , 74  , 70  , 66  , 62  , 59  , 56 }
periodTable[ 3] = {	 
	1676, 1582, 1492, 1408, 1330, 1256, 1184, 1118, 1056, 996 , 940 , 888,
     838 , 791 , 746 , 704 , 665 , 628 , 592 , 559 , 528 , 498 , 470 , 444,
     419 , 395 , 373 , 352 , 332 , 314 , 296 , 280 , 264 , 249 , 235 , 222,
     209 , 198 , 187 , 176 , 166 , 157 , 148 , 140 , 132 , 125 , 118 , 111,
     104 , 99  , 93  , 88  , 83  , 78  , 74  , 70  , 66  , 62  , 59  , 55 }
periodTable[ 4] = {	 
	1664, 1570, 1482, 1398, 1320, 1246, 1176, 1110, 1048, 990 , 934 , 882,
     832 , 785 , 741 , 699 , 660 , 623 , 588 , 555 , 524 , 495 , 467 , 441,
     416 , 392 , 370 , 350 , 330 , 312 , 294 , 278 , 262 , 247 , 233 , 220,
     208 , 196 , 185 , 175 , 165 , 156 , 147 , 139 , 131 , 124 , 117 , 110,
     104 , 98  , 92  , 87  , 82  , 78  , 73  , 69  , 65  , 62  , 58  , 55}
periodTable[ 5] = {	 
	1652, 1558, 1472, 1388, 1310, 1238, 1168, 1102, 1040, 982 , 926 , 874,
     826 , 779 , 736 , 694 , 655 , 619 , 584 , 551 , 520 , 491 , 463 , 437,
     413 , 390 , 368 , 347 , 328 , 309 , 292 , 276 , 260 , 245 , 232 , 219,
     206 , 195 , 184 , 174 , 164 , 155 , 146 , 138 , 130 , 123 , 116 , 109,
     103 , 97  , 92  , 87  , 82  , 77  , 73  , 69  , 65  , 61  , 58  , 54}
periodTable[ 6] = {	 
	1640, 1548, 1460, 1378, 1302, 1228, 1160, 1094, 1032, 974 , 920 , 868,
     820 , 774 , 730 , 689 , 651 , 614 , 580 , 547 , 516 , 487 , 460 , 434,
     410 , 387 , 365 , 345 , 325 , 307 , 290 , 274 , 258 , 244 , 230 , 217,
     205 , 193 , 183 , 172 , 163 , 154 , 145 , 137 , 129 , 122 , 115 , 109,
     102 , 96  , 91  , 86  , 81  , 77  , 72  , 68  , 64  , 61  , 57  , 54}
periodTable[ 7] = {	 
	1628, 1536, 1450, 1368, 1292, 1220, 1150, 1086, 1026, 968 , 914 , 862,
     814 , 768 , 725 , 684 , 646 , 610 , 575 , 543 , 513 , 484 , 457 , 431,
     407 , 384 , 363 , 342 , 323 , 305 , 288 , 272 , 256 , 242 , 228 , 216,
     204 , 192 , 181 , 171 , 161 , 152 , 144 , 136 , 128 , 121 , 114 , 108,
     102 , 96  , 90  , 85  , 80  , 76  , 72  , 68  , 64  , 60  , 57  , 54}
periodTable[-8] = {	 
	1814, 1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960,
     907 , 856 , 808 , 762 , 720 , 678 , 640 , 604 , 570 , 538 , 508 , 480,
     453 , 428 , 404 , 381 , 360 , 339 , 320 , 302 , 285 , 269 , 254 , 240,
     226 , 214 , 202 , 190 , 180 , 170 , 160 , 151 , 143 , 135 , 127 , 120,
     113 , 107 , 101 , 95  , 90  , 85  , 80  , 75  , 71  , 67  , 63  , 60 }
periodTable[-7] = {	 
	1800, 1700, 1604, 1514, 1430, 1350, 1272, 1202, 1134, 1070, 1010, 954,
     900 , 850 , 802 , 757 , 715 , 675 , 636 , 601 , 567 , 535 , 505 , 477,
     450 , 425 , 401 , 379 , 357 , 337 , 318 , 300 , 284 , 268 , 253 , 238,
     225 , 212 , 200 , 189 , 179 , 169 , 159 , 150 , 142 , 134 , 126 , 119,
     112 , 106 , 100 , 94  , 89  , 84  , 79  , 75  , 71  , 67  , 63  , 59}
periodTable[-6] = {	 
	1788, 1688, 1592, 1504, 1418, 1340, 1264, 1194, 1126, 1064, 1004, 948,
     894 , 844 , 796 , 752 , 709 , 670 , 632 , 597 , 563 , 532 , 502 , 474,
     447 , 422 , 398 , 376 , 355 , 335 , 316 , 298 , 282 , 266 , 251 , 237,
     223 , 211 , 199 , 188 , 177 , 167 , 158 , 149 , 141 , 133 , 125 , 118,
     111 , 105 , 99  , 94  , 88  , 83  , 79  , 74  , 70  , 66  , 62  , 59 }
periodTable[-5] = {	 
	1774, 1676, 1582, 1492, 1408, 1330, 1256, 1184, 1118, 1056, 996 , 940,
     887 , 838 , 791 , 746 , 704 , 665 , 628 , 592 , 559 , 528 , 498 , 470,
     444 , 419 , 395 , 373 , 352 , 332 , 314 , 296 , 280 , 264 , 249 , 235,
     222 , 209 , 198 , 187 , 176 , 166 , 157 , 148 , 140 , 132 , 125 , 118,
     111 , 104 , 99  , 93  , 88  , 83  , 78  , 74  , 70  , 66  , 62  , 59 }
periodTable[-4] = {	 
	1762, 1664, 1570, 1482, 1398, 1320, 1246, 1176, 1110, 1048, 988 , 934,
     881 , 832 , 785 , 741 , 699 , 660 , 623 , 588 , 555 , 524 , 494 , 467,
     441 , 416 , 392 , 370 , 350 , 330 , 312 , 294 , 278 , 262 , 247 , 233,
     220 , 208 , 196 , 185 , 175 , 165 , 156 , 147 , 139 , 131 , 123 , 117,
     110 , 104 , 98  , 92  , 87  , 82  , 78  , 73  , 69  , 65  , 61  , 58}
periodTable[-3] = {	 
	1750, 1652, 1558, 1472, 1388, 1310, 1238, 1168, 1102, 1040, 982 , 926,
     875 , 826 , 779 , 736 , 694 , 655 , 619 , 584 , 551 , 520 , 491 , 463,
     437 , 413 , 390 , 368 , 347 , 328 , 309 , 292 , 276 , 260 , 245 , 232,
     219 , 206 , 195 , 184 , 174 , 164 , 155 , 146 , 138 , 130 , 123 , 116,
     109 , 103 , 97  , 92  , 87  , 82  , 77  , 73  , 69  , 65  , 61  , 58}
periodTable[-2] = {	 
	1736, 1640, 1548, 1460, 1378, 1302, 1228, 1160, 1094, 1032, 974 , 920,
     868 , 820 , 774 , 730 , 689 , 651 , 614 , 580 , 547 , 516 , 487 , 460,
     434 , 410 , 387 , 365 , 345 , 325 , 307 , 290 , 274 , 258 , 244 , 230,
     217 , 205 , 193 , 183 , 172 , 163 , 154 , 145 , 137 , 129 , 122 , 115,
     108 , 102 , 96  , 91  , 86  , 81  , 77  , 72  , 68  , 64  , 61  , 57}
periodTable[-1] = {	 
	1724, 1628, 1536, 1450, 1368, 1292, 1220, 1150, 1086, 1026, 968 , 914,
     862 , 814 , 768 , 725 , 684 , 646 , 610 , 575 , 543 , 513 , 484 , 457,
     431 , 407 , 384 , 363 , 342 , 323 , 305 , 288 , 272 , 256 , 242 , 228,
     216 , 203 , 192 , 181 , 171 , 161 , 152 , 144 , 136 , 128 , 121 , 114,
     108 , 101 , 96  , 90  , 85  , 80  , 76  , 72  , 68  , 64  , 60  , 57}

-- We only really need the inverse of the above...
local iPeriodTable = {}
for f=-8,7 do
		iPeriodTable[f] = {}
	for i,v in ipairs(periodTable[f]) do
		iPeriodTable[f][v] = i
	end
end

-- The list of known (by me) FourCC-s, and also, the ones this program supports.
-- Note: Karsten Obarski's The Ultimate Soundtracker (1987) does not have a 4CC.
--       Nor do any other 15-sample formats, as far as i know...
--       Some of these may be errorenous.
local fourCC = {
	['M.K.'] = true, -- 4 channel, NewTracker? (or 8 channel WOW...)
	['M!K!'] = 4, -- 4 channel, Mahoney & Kaktus ProTracker
	['PATT'] = 4, -- 4 channel, ProTracker 3.6
	['NSMS'] = 4, -- 4 channel, kingdomofpleasure.mod by bee hunter
	['LARD'] = 4, -- 4 channel, judgement_day_gvine.mod by 4-mat

	['M&K&'] = false, -- 4 channel, NoiseTracker?

	['M&K!'] = 4, -- 4 channel, NoiseTracker / His Master's Noise MusicDisk
	['FEST'] = 4, -- 4 channel, "jobbig.mod" / His Master's Noise MusicDisk
	['N.T.'] = 4, -- 4 channel, NoiseTracker

	['RASP'] = false, -- 4 channel, Exolon / Fairlight StarTrekker?
	['FLT4'] = 4, -- 4 channel, Exolon / Fairlight StarTrekker
	['EXO4'] = 4, -- 4 channel, Exolon / Fairlight StarTrekker - synth format
	['FLT8'] = 4, -- 8 channel, Exolon / Fairlight StarTrekker (2x4ch pat!)
	['EXO8'] = 4, -- 8 channel, Exolon / Fairlight StarTrekker (2x4ch pat!) - synth format

	['CD61'] = 6, -- 6 channel, Octalyser on Atari STe/Falcon
	['CD81'] = 8, -- 8 channel, Octalyser on Atari STe/Falcon

	['OCTA'] = 8, -- 8 channel, Oktalyzer
	['OKTA'] = 8, -- 8 channel, Oktalyzer

	['M\0\0\0'] = 4, -- 4 channel, Inconexia demo (delta samples)
	['8\0\0\0'] = 8, -- 8 channel, Inconexia demo (delta samples)

	['FA04'] = 4, -- 4 channel, Digital Tracker (Atari Falcon)
	['FA06'] = 6, -- 6 channel, Digital Tracker (Atari Falcon)
	['FA08'] = 8, -- 8 channel, Digital Tracker (Atari Falcon)

	['1CHN'] = 1, -- 1 channel, Generic MOD Trackers?
	['2CHN'] = 2, -- 2 channel, FastTracker
	['3CHN'] = 3, -- 3 channel, Generic MOD Trackers?
	['4CHN'] = 4, -- 4 channel, Generic MOD Trackers?
	['5CHN'] = 5, -- 5 channel, TakeTracker
	['6CHN'] = 6, -- 6 channel, Generic MOD Trackers?
	['7CHN'] = 7, -- 7 channel, TakeTracker
	['8CHN'] = 8, -- 8 channel, Generic MOD Trackers?
	['9CHN'] = 9, -- 9 channel, TakeTracker

	--['xxCH'] = true, -- 11,13,15 ch. TakeTracker, or else Generic MOD Trackers?
	--['xxCN'] = true, -- Generic MOD Trackers?

	['TDZ1'] = 1, -- 1 channel, TakeTracker
	['TDZ2'] = 2, -- 2 channel, TakeTracker
	['TDZ3'] = 3, -- 3 channel, TakeTracker
	['TDZ4'] = 4, -- 4 channel, TakeTracker?
	['TDZ5'] = 5, -- 5 channel, TakeTracker?
	['TDZ6'] = 6, -- 6 channel, TakeTracker?
	['TDZ7'] = 7, -- 7 channel, TakeTracker?
	['TDZ8'] = 8, -- 8 channel, TakeTracker?
	['TDZ9'] = 9, -- 9 channel, TakeTracker?
}

-- This basically makes my life easier by assigning specific configurations to
-- specific trackers; flags will state the more contradictory options
local flags = {
	['treat-F20-as-speed'] = false, -- Usually treated as tempo instead.

}

local errorString = {
	--[[1]] "File FourCC at 0x438 isn't supported.",
	--[[2]] "00CH or 00CN format detected.",
	--[[3]] "Early end-of-file in header.",
	--[[4]] "Early end-of-file in sample information.",
	--[[5]] "Early end-of-file in order information.",
	--[[6]] "Early end-of-file in pattern data.",
	--[[7]] "Note period unknown.",
	--[[8]] "Early end-of-file in sample data.",
}

local load_mod = function(file)
	log("--  Various Trackers MOD loader  --\n\n")
	local structure = {}
	file:open('r')

	local v,n

	local oldFormats = false
	local format = false
	local channelCount = 0
	local checkWOW = false
	local is2x4 = false

	-- First thing's first; Try to see if there's any FourCC at offset 0x438.
	file:seek(1080)
	v,n = file:read(4);
	format = v
	log("Format fourCC: %s (%s)\n", format, util.str2hex(format, ' '))
	if n ~= 4 then
		-- EoF reached, either an old format, or damaged or not a module.
		oldFormats = true
		channelCount = 4
	else
		if type(fourCC[format]) == 'number' then
			-- Format known, perfectly defines channel count.
			channelCount = fourCC[format]
			if format == 'FLT8' or format == 'EXO8' then
				is2x4 = true
			end
		elseif fourCC[format] then
			-- Format known, but shenanigans are afoot.
			if format == 'M.K.' then
				-- Check whether compatible mod or WOW 8-channel.
				checkWOW = true
			end
		elseif format:sub(3,4) == 'CH' or format:sub(3,4) == 'CN' then
				-- Generic n channel module format, probably.
				channelCount = tonumber(format:sub(1,2))
		else
			-- No known format detected, probably an old format.
			oldFormats = true
			channelCount = 4
		end
	end

	log("Old 15-instrument format? %s\n", oldFormats and
		'probably' or 'probably not')

	-- Check WOW format... TODO; assume regular 4ch mod for now
	if checkWOW then
		channelCount = 4
	end

	-- One more way we could try to detect an UST module would be the fact that
	-- all of those mods used the same samples from one specific sample disk.
	-- Hashing the sample data, and comparing with already known hashes of
	-- ST-01 samples would probably be helpful too, but i'm not sure if it's
	-- necessary, at all. <-TODO

	if channelCount == 0 then return false, errorString[2] end

	--[[Header]]--

	file:seek(0)
	v,n = file:read(20); if n<20 then return false, errorString[3] end
	structure.title = v
	log("Module title: %s (%s)\n\n", structure.title,
		util.str2hex(structure.title, ' '))

	structure.samples = {}
	-- If oldformat is true, only read 15 samples, else 31.
	for i=1,15 do
		structure.samples[i] = {}
		local sample = structure.samples[i]
		log("Sample #%2d:\n", i)
		v,n = file:read(22); if n<22 then return false, errorString[4] end
		sample.name = v
		v,n = file:read(2); if n<2 then return false, errorString[4] end
		sample.length = util.bin2num(v, 'BE') * 2
		v,n = file:read(1); if n<1 then return false, errorString[4] end
		v = string.byte(v); sample.finetune = v > 7 and v-16 or v
		v,n = file:read(1); if n<1 then return false, errorString[4] end
		sample.volume = string.byte(v)
		v,n = file:read(2); if n<2 then return false, errorString[4] end
		sample.loopstart = util.bin2num(v, 'BE') * 2
		v,n = file:read(2); if n<2 then return false, errorString[4] end
		sample.looplen = util.bin2num(v, 'BE') * 2
		log("\tName: %s (%s)\n"   , sample.name, util.str2hex(sample.name, ' '))
		log("\tLength: %d B\n"    , sample.length)
		log("\tFinetune: %01d\n"  , sample.finetune)
		log("\tVolume: %2X\n"     , sample.volume)
		log("\tLoop start: %d B\n", sample.loopstart)
		log("\tLoop length: %d B\n", sample.looplen)
	end
	if not oldFormats then
	for i=16,31 do
		structure.samples[i] = {}
		local sample = structure.samples[i]
		log("Sample #%2d:\n", i)
		v,n = file:read(22); if n<22 then return false, errorString[4] end
		sample.name = v
		v,n = file:read(2); if n<2 then return false, errorString[4] end
		sample.length = util.bin2num(v, 'BE') * 2
		v,n = file:read(1); if n<1 then return false, errorString[4] end
		v = string.byte(v) % 0x10; sample.finetune = v > 7 and v-16 or v
		v,n = file:read(1); if n<1 then return false, errorString[4] end
		sample.volume = string.byte(v)
		v,n = file:read(2); if n<2 then return false, errorString[4] end
		sample.loopstart = util.bin2num(v, 'BE') * 2
		v,n = file:read(2); if n<2 then return false, errorString[4] end
		sample.looplen = util.bin2num(v, 'BE') * 2
		log("\tName: %s (%s)\n"   , sample.name, util.str2hex(sample.name, ' '))
		log("\tLength: %d B\n"    , sample.length)
		log("\tFinetune: %01d\n"  , sample.finetune)
		log("\tVolume: %2X\n"     , sample.volume)
		log("\tLoop start: %d B\n", sample.loopstart)
		log("\tLoop length: %d B\n", sample.looplen)
	end
	end
	log("\n")

	v,n = file:read(1); if n<1 then return false, errorString[5] end
	structure.orderCount = string.byte(v)
	log("Order count: %d\n", structure.orderCount)

	v,n = file:read(1); if n<1 then return false, errorString[5] end
	structure.orderRestart = string.byte(v)
	log("Not-quite Restart Position: %d\n", structure.orderRestart)

	structure.orders = {}
	local patternCount = 0
	log("Orders:\n\t")
	for i=0,127 do
		v,n = file:read(1); if n<1 then return false, errorString[5] end
		structure.orders[i] = string.byte(v)
		-- A shitty precaution to not try and, by mistake, read 255 patterns.
		if structure.orders[i] > patternCount --and i <= structure.orderCount
		then
			patternCount = structure.orders[i]
		end
		log("%02X ", structure.orders[i])
		if i < 127 and i % 16 == 15 then log('\n\t') end
	end
	log("\n\n")
	log('Calculated pattern count: %3d (%02X)\n\n', patternCount, patternCount)



	-- If 31-sample format, skip the ID.
	if not oldFormats then file:read(4) end



	structure.pattern = {}
	-- Patterns are n Channels * 64 rows * 4 Bytes (Cells) large.
	-- Only one exception exists, where patterns are coupled together,
	-- it being Startrekker's FLT8/EXO8 formats.

	-- Cell bit layout is the following:
	-- AAAABBBB CCCCCCCC DDDDEEEE FFFFFFFF
	-- Rearranged to:
	-- AAAADDDD     - sample
	-- BBBBCCCCCCCC - period value
	-- EEEE         - effect
	-- FFFFFFFF     - parameter(s)

	local noteTf = function(n)

		local symbol = {'-','#','-','#','-','-','#','-','#','-','#','-'}
		local letter = {'C','C','D','D','E','F','F','G','G','A','A','B'}
		if n == 0 then
			return '... (000)'
		else
			local class = ((n-1) % 12) + 1
			local oct = math.floor(n / 12) + 3 -- OpenMPT style
			return ("%1s%1s%1X (%03d)"):format(letter[class], symbol[class], oct, n)
		end
	end



	for p=0, patternCount do
		log("Pattern %02X at 0x%06X:\n", p, 1084 + (p * 4 * 64 * channelCount))
		structure.pattern[p] = {}
		for r=0, 63 do
			structure.pattern[p][r] = {}
			log('\t|')
			for c=1, channelCount do
				local cell = {}
				v,n = file:read(4);if n<4 then return false, errorString[6] end
				v = util.bin2num(v, 'BE')
				local A,B,C,D
				A = math.floor(v / 0x1000000 ) % 0x100
				B = math.floor(v / 0x10000   ) % 0x100
				C = math.floor(v / 0x100     ) % 0x100
				D = math.floor(v             ) % 0x100

				local note = (A % 0x10) * 0x100 + B
				cell.note = note
				if note == 0 then
					cell.note = 0
				else
					-- if out of bounds, try adjusting it
					while note > 1814 do
						note = math.floor(note / 2)
					end
					while note < 54 do
						note = math.floor(note * 2)
					end
					-- find period in lookup table
					cell.note = false
					for f=-8,7 do
						cell.note = iPeriodTable[f][note]
						if cell.note then
							cell.note = cell.note - 1
							break
						end
					end
					-- if that didn't work, try a bit more aggressively
					local done = false
					if not cell.note then
						for f=-8,7 do
							if done then break end
							for a=-2,2 do
								cell.note = iPeriodTable[f][note+a]
								if cell.note then
									cell.note = cell.note - 1
									done = true
									break
								end
							end
						end
					end
					-- if that didn't fix it, guess just die.
					if not cell.note then
						log("\n\nPERIOD VALUE: %s\n\n", cell.note)
						return false, errorString[7]
					end
				end
				cell.samp = math.floor(A / 0x10) * 0x10 + math.floor(C / 0x10)
				cell.cmmd = C % 0x10
				cell.data = D
				structure.pattern[p][r][c] = cell

				log("%3s %2s %1s%2s%s",
					noteTf(cell.note),
					cell.samp > 0 and ('%02d'):format(cell.samp) or '..',
					((cell.cmmd==0 and cell.data > 0) or (cell.cmmd>0)) and ('%1X'):format(cell.cmmd) or '.',
					((cell.cmmd==0 and cell.data > 0) or (cell.cmmd>0)) and ('%02X'):format(cell.data) or '..',
					c < channelCount and '|' or '')
			end
			log('\n')
		end
		log('\n')
	end

	-- Load in sample data
	for i,smp in ipairs(structure.samples) do
		log("Sample 0x%02X waveform at 0x%06X: ", i, file:tell())
		if smp.length > 0 then
			smp.data = love.sound.newSoundData(
				smp.length,
				8000, -- Doesn't matter.
				8,    -- MOD and compatible files only support 8-bit samples.
				1     -- Mod and compatible files only support mono samples.
			)
			v,n = file:read(smp.length)
			if n < smp.length then return false, errorString[8] end
			for i=0,smp.length-1 do
				-- Two's complement, aka signed bytes.
				local x = string.byte(v:sub(i+1,i+1))
				smp.data:setSample(i, ((x > 127) and (-0x100+x) or x) / 128)
			end
			smp.raw = v -- REMOVEME! FOR TESTING ONLY!
			log("Loaded %d Bytes.\n", smp.length)
		else
			log("Empty.\n")
		end
	end
	log('\n')

	log('End of data at: 0x%06X\n',file:tell())
	log('Total file size: 0x%06X\n', file:getSize())
	log('End of file %sreached.\n', file:tell()>=file:getSize() and '' or 'not ')

	structure.oldFormat = oldFormats

	--[[Finalization]]--

	structure.moduleType = "???"
	structure.fileType = 'mod'

	log("-- /Various Trackers MOD loader/ --\n\n")
	return structure
end

---------------
return load_mod