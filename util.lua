-- Utility functions
-- by zorg @ 2016 § ISC

local utf8 = require 'utf8'
local bit = require 'bit'

local util = {}

function util.str2hex(s)
	local t = {}
	for i=1,#s do table.insert(t, ('%X'):format(s:sub(i,i):byte())) end
	return table.concat(t, ' ')
end

function util.hex2str(h)
	local t = {}
	for x in h:gmatch('%w+') do table.insert(t, string.char(tonumber(x,16))) end
	return table.concat(t)
end

function util.ansi2utf8(s)
	local t,m = {},0
	for c in s:gmatch'.' do
		local n = string.byte(c)
		m = m + 1
		t[m] = utf8.char(n)
	end
	return table.concat(t)
end

function util.ansi2number(s, endianness) -- 'BE' is default -- rename to bin2number
	local n,m = 0, #s
	if endianness == 'LE' then
		for i = 1, m, 1 do n = n + s:sub(i,i):byte() * (256^(i-1)) end
	else--[[if endianness == 'BE' then--]]
		for i = 1, m, 1 do n = n + s:sub(i,i):byte() * (256^((m-1)-(i-1))) end
	end
	return n
end

function util.bin2bitfield(s)

end

-----------
return util