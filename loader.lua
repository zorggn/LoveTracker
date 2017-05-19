-- Module loader
-- by zorg @ 2016-2017 § ISC

local log = require('log')

-- List of loaders.
-- Need this since we want to iterate over loaders only once, if a file
-- extension is not recognized.
local loader = {
	--['mod'] = require('load_mod'),
	['s3m'] = require('load_s3m'),
	--['xm']  = require('load_xm'),
	--['it']  = require('load_it'),
	['org'] = require('load_org')
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

	if not loaded and loader[antePunct] then
		-- Extension before the dot, Amiga usage.
		loaded, errmsg = loader[antePunct](file)
		if loaded then
			loaded.fileType = antePunct
			log("Found Amiga module with extension '%s' (%s).\n", antePunct,
				loaded.moduleType)
		else
			log("An error was encountered: %s\n", errmsg)
		end
	end

	if not loaded and loader[postPunct] then
		-- Extension after the dot, PC usage.
		loaded, errmsg = loader[postPunct](file)
		if loaded then
			loaded.fileType = postPunct
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
		for ext, fun in pairs(loader) do
			loaded, errmsg = fun(file)
			if loaded then
				loaded.fileType = ext
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