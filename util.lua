-- Utility functions
-- by zorg @ 2016 § ISC

local utf8 = require 'utf8'
local bit  = require 'bit'

local util = {}

function util.str2hex(str, div)
	local t = {}
	for i=1, #str do
		table.insert(t, ('%X'):format(str:sub(i, i):byte()))
	end
	return table.concat(t, div)
end

function util.hex2str(hex)
	local t = {}
	for x in hex:gmatch('%w+') do
		table.insert(t, string.char(tonumber(x, 16)))
	end
	return table.concat(t)
end

function util.bin2utf8(str)
	local t, m = {}, 0
	for chr in str:gmatch'.' do
		local n = string.byte(chr)
		m = m + 1
		t[m] = utf8.char(n)
	end
	return table.concat(t)
end

function util.bin2num(str, ord, wsize)
	wsize = wsize or 1
	local n,m = 0, #str
	if ord == 'LE' then
		for i = 1, m, wsize do
			for j = wsize-1, 0, -1 do
				n = n + str:sub(i+j,i+j):byte() * (256^(i-1+(wsize-1-j)))
			end
		end
	else --[[if ord == 'BE' then--]]
		for i = 1, m, 1 do
			n = n + str:sub(i,i):byte() * (256^((m-1)-(i-1)))
		end
	end
	return n
end

function util.bin2flags(str, ord)
local t, n = {}, 0
	while n < #str do
		local c = str:sub(n+1,n+1):byte()
		local i = 0
		while i < 8 do
			if ord == 'LE' then
				t[(n*8)+i+1] = bit.band(c, 2^(7-i)) ~= 0 and true or false
			else --[[if ord == 'BE' then--]]
				t[(n*8)+i+1] = bit.band(c, 2^i) ~= 0 and true or false
			end
			i = i + 1
		end
		n = n + 1
	end
	return t
end

-----------
return util
