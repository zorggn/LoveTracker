-- Module loader
-- by zorg @ 2016-2017 § ISC

local log = require('log')

-- List of loaders.
-- Need this since we want to iterate over loaders only once, if a file
-- extension is not recognized.
local loader = {
	['load_mod'] = require('load_mod'),
	['load_s3m'] = require('load_s3m'),
	--['load_xm']  = require('load_xm'),
	--['load_it']  = require('load_it'),
	['load_org'] = require('load_org'),
	['load_hvl'] = require('load_hvl'),
}

-- List of the supported file extensions and loader assignments to them.
-- Note that some module formats may share extensions, but those are dealt with
-- in the loaders.
local extension = {
	-- Ultimate Soundtracker (m15 subtype)
	-- Soundtracker
	-- Master Soundtracker
	-- Protracker
	-- Noisetracker
	-- FastTracker (ft subtype)
	-- Falcon StarTrekker
	-- TakeTracker
	-- Grave Composer / Mod's Grave (wow subtype)
	['mod']  = 'load_mod',
	['ft']   = 'load_mod',
	['wow']  = 'load_mod',

	-- Scream Tracker III
	['as3m'] = 'load_s3m',
	['s3m']  = 'load_s3m',

	-- Fast Tracker II
	--['xm']  = 'load_xm',

	-- Impulse Tracker
	--['it']  = 'load_it',

	-- Organya
	['org']  = 'load_org',

	-- Abyss' Highest Experience (back-compatibility)
	-- Hively Tracker
	['ahx']  = 'load_hvl',
	['thx']  = 'load_hvl',
	['hvl']  = 'load_hvl',
}

-- The loader
local load_module = function(file)

	-- Holds the module data, or false if the file couldn't be detected/parsed.
	local loaded = false
	local errmsg = false

	-- Separate path, name, extension from filename; though it may be path,
	-- extension, name instead (amiga).
	local _, antePunct, postPunct = file:getFilename():match(
		"(.-)([^\\/]-%.?([^%.\\/]*))$")
	antePunct = antePunct:match("(.+)%..*")
	-- Fix case.
	antePunct, postPunct = string.lower(antePunct), string.lower(postPunct)

	log("Path: '%s' Former half: '%s' Latter half: '%s'\n", _, antePunct,
		postPunct)

	-- Differentiating between tracker module filetypes, by magic
	-- (deep or arcane) or otherwise.
	-- The short version: Try loading the passed file with a loader defined by
	-- the extension that may exist on either end of the filename; if neither
	-- worked, then try all module loaders, and if it's still not detected,
	-- only then return with failure.

	if not loaded and extension[antePunct] then
		-- Extension before the dot, Amiga usage.
		loaded, errmsg = loader[extension[antePunct]](file)
		if loaded then
			loaded.fileExt = antePunct
			log("Found Amiga module with extension '%s' (%s).\n", antePunct,
				loaded.moduleType)
		else
			log("An error was encountered: %s\n", errmsg)
		end
	end

	if not loaded and extension[postPunct] then
		-- Extension after the dot, PC usage.
		loaded, errmsg = loader[extension[postPunct]](file)
		if loaded then
			loaded.fileExt = postPunct
			log("Found PC module with extension '%s' (%s).\n", postPunct,
				loaded.moduleType)
		else
			log("An error was encountered: %s\n", errmsg)
		end
	end

	-- The above ensures that even if a module is called something stupid like
	-- "mod.s3m", it will try to parse it both ways.

	-- Try all of the loaders as a last resort, maybe we'll find a match...
	if not loaded then
		for ldr, fun in pairs(loader) do
			loaded, errmsg = fun(file)
			if loaded then
				loaded.fileExt = loaded.fileType
				log("Extension mismatch, but recognized file as '%s' anyway." ..
					"(%s)\n", ext, loaded.moduleType)
				break
			else
				log("An error was encountered: %s\n", errmsg)
			end
		end
	end

	-- Well shit.
	if not loaded then
		log("Couldn't load file; is it a supported tracker module?\n")
	end

	return loaded
end

------------------
return load_module