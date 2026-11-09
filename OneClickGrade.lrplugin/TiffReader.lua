-- TiffReader.lua
-- Minimal reader for baseline TIFF files written by Lightroom's export.
-- Supports: little/big endian, strip organisation, PlanarConfiguration=1,
--           Compression=1 (none), BitsPerSample 8 or 16,
--           PhotometricInterpretation 0/1 (grayscale) and 2 (RGB).
-- Returns the min / max luma (and per-channel min / max) of the image.
--
-- The goal is only to find the extreme luminance values, so the reader works on
-- the raw pixel data and never needs libtiff / ImageMagick / external tools.

local TiffReader = {}

local TYPE_SIZE = {
	[1] = 1, [2] = 1, [3] = 2, [4] = 4, [5] = 8,
	[6] = 1, [7] = 1, [8] = 2, [9] = 4, [10] = 8, [11] = 4, [12] = 8,
}

local function u16(data, pos, le)
	local b1, b2 = data:byte(pos, pos + 1)
	if not b2 then return nil end
	if le then return b1 + b2 * 256 end
	return b1 * 256 + b2
end

local function u32(data, pos, le)
	local b1, b2, b3, b4 = data:byte(pos, pos + 3)
	if not b4 then return nil end
	if le then
		return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	end
	return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

-- Read the values of one IFD entry as a Lua array (1-based).
local function entryValues(data, entry, le)
	local size = TYPE_SIZE[entry.type]
	if not size then return nil, "unhandled TIFF field type " .. tostring(entry.type) end

	local total = size * entry.count
	local base
	if total <= 4 then
		base = entry.pos
	else
		local off = u32(data, entry.pos, le)
		if not off then return nil, "truncated TIFF field" end
		base = off + 1
	end

	local out = {}
	local t = entry.type
	local n = entry.count
	for i = 0, n - 1 do
		local v
		if t == 1 or t == 6 or t == 7 then
			v = data:byte(base + i)
		elseif t == 3 or t == 8 then
			v = u16(data, base + i * 2, le)
		elseif t == 4 or t == 9 then
			v = u32(data, base + i * 4, le)
		else
			return nil, "unhandled TIFF field type " .. tostring(t)
		end
		if v == nil then return nil, "truncated TIFF field data" end
		out[i + 1] = v
	end
	return out
end

local function readAllBytes(path)
	-- Prefer the Lightroom file utility when available; fall back to io.
	if rawget(_G, "LrFileUtils") and LrFileUtils.readFile then
		local ok, data = pcall(LrFileUtils.readFile, path)
		if ok and type(data) == "string" and #data > 0 then
			return data
		end
	end
	local f, err = io.open(path, "rb")
	if not f then return nil, "cannot open file: " .. tostring(err) end
	local data = f:read("*a")
	f:close()
	if not data then return nil, "cannot read file" end
	return data
end

-- analyzeData(data) -> stats table, or nil, errorMessage
-- Split out from analyze() so the parser can be unit-tested with in-memory data.
function TiffReader.analyzeData(data)
	if not data then return nil, "no TIFF data" end
	if #data < 8 then return nil, "file too small to be a TIFF" end

	local bom = data:sub(1, 2)
	local le
	if bom == "II" then
		le = true
	elseif bom == "MM" then
		le = false
	else
		return nil, "unsupported TIFF byte order (" .. bom .. ")"
	end

	local magic = u16(data, 3, le)
	if magic ~= 42 then
		return nil, "not a classic TIFF (magic=" .. tostring(magic) .. ")"
	end

	local ifdOffset = u32(data, 5, le)
	if not ifdOffset or ifdOffset + 2 > #data then
		return nil, "bad IFD offset"
	end

	local n = u16(data, ifdOffset + 1, le)
	if not n or n <= 0 then return nil, "empty IFD" end

	local tags = {}
	for i = 0, n - 1 do
		local base = ifdOffset + 2 + i * 12 + 1
		if base + 11 > #data then return nil, "truncated IFD" end
		local tag = u16(data, base, le)
		local typ = u16(data, base + 2, le)
		local cnt = u32(data, base + 4, le)
		if tag and typ and cnt then
			tags[tag] = { type = typ, count = cnt, pos = base + 8 }
		end
	end

	local function vals(tag)
		local e = tags[tag]
		if not e then return nil end
		return entryValues(data, e, le)
	end

	local widthV, e1 = vals(256)
	local heightV, e2 = vals(257)
	if not widthV or not widthV[1] then return nil, e1 or "missing ImageWidth" end
	if not heightV or not heightV[1] then return nil, e2 or "missing ImageLength" end
	local width = widthV[1]
	local height = heightV[1]
	if width <= 0 or height <= 0 or width > 100000 or height > 100000 then
		return nil, "implausible image dimensions " .. tostring(width) .. "x" .. tostring(height)
	end

	local bitsV = vals(258) or { 8 }
	local compression = (vals(259) or { 1 })[1]
	local photometric = (vals(262) or { 2 })[1]
	local stripOffsets, e3 = vals(273)
	if not stripOffsets then return nil, e3 or "missing StripOffsets" end
	local samplesPerPixel = (vals(277) or {})[1]
	local rowsPerStrip = (vals(278) or {})[1] or height
	local stripCounts = vals(279)
	local planar = (vals(284) or { 1 })[1]
	local sampleFormat = (vals(339) or { 1 })[1]

	if compression ~= 1 then
		return nil, "TIFF is compressed (compression=" .. tostring(compression) ..
			"); export without compression"
	end
	if planar ~= 1 then
		return nil, "unsupported TIFF planar configuration " .. tostring(planar)
	end
	if sampleFormat ~= 1 then
		return nil, "unsupported TIFF sample format " .. tostring(sampleFormat)
	end
	if photometric ~= 0 and photometric ~= 1 and photometric ~= 2 then
		return nil, "unsupported TIFF photometric interpretation " .. tostring(photometric)
	end

	local bits = bitsV[1] or 8
	if bits ~= 8 and bits ~= 16 then
		return nil, "unsupported TIFF bit depth " .. tostring(bits)
	end
	for i = 2, #bitsV do
		if bitsV[i] ~= bits then
			return nil, "mixed TIFF bit depths are not supported"
		end
	end

	local channels
	if photometric == 2 then
		channels = samplesPerPixel or #bitsV
		if not channels or channels < 3 then channels = 3 end
		if channels > 3 then
			return nil, "unsupported number of colour samples " .. tostring(channels)
		end
	else
		channels = 1
	end

	local bytesPerSample
	if bits == 8 then bytesPerSample = 1 else bytesPerSample = 2 end
	local bytesPerPixel = bytesPerSample * channels

	local minLuma, maxLuma = 255, 0
	local minChannel, maxChannel = 255, 0
	-- 256-bin luminance histogram: hist[v + 1] is the number of pixels whose
	-- rounded luma equals v (0..255). Lightroom's curve coordinates are 0..255,
	-- and its clipping indicator reacts to the histogram tails, so the tails
	-- are a better match for the curve end points than the absolute min / max.
	local hist = {}
	for i = 1, 256 do hist[i] = 0 end

	local stripIndex = 0
	for _, stripOffset in ipairs(stripOffsets) do
		stripIndex = stripIndex + 1
		local rowsHere = rowsPerStrip
		local remaining = height - (stripIndex - 1) * rowsPerStrip
		if remaining <= 0 then break end
		if rowsHere > remaining then rowsHere = remaining end

		local byteCount
		if stripCounts and stripCounts[stripIndex] then
			byteCount = stripCounts[stripIndex]
		else
			byteCount = rowsHere * width * bytesPerPixel
		end

		local pos = stripOffset + 1
		local limit = pos + byteCount - 1
		if limit > #data then
			return nil, "truncated TIFF strip #" .. tostring(stripIndex)
		end

		if channels == 1 then
			for row = 0, rowsHere - 1 do
				local p = pos + row * width * bytesPerPixel
				for x = 0, width - 1 do
					local v
					if bits == 8 then
						v = data:byte(p + x)
					else
						-- take the high byte of the 16-bit sample
						v = data:byte(p + x * 2 + (le and 1 or 0)) or 0
					end
					if v < minLuma then minLuma = v end
					if v > maxLuma then maxLuma = v end
					if v < minChannel then minChannel = v end
					if v > maxChannel then maxChannel = v end
					hist[v + 1] = hist[v + 1] + 1
				end
			end
		else
			for row = 0, rowsHere - 1 do
				local p = pos + row * width * bytesPerPixel
				for x = 0, width - 1 do
					local base = p + x * bytesPerPixel
					local r, g, b
					if bits == 8 then
						r, g, b = data:byte(base, base + 2)
					else
						local o = le and 1 or 0
						r = data:byte(base + o) or 0
						g = data:byte(base + 2 + o) or 0
						b = data:byte(base + 4 + o) or 0
					end
					if not r then break end
					local luma = (r * 3 + g * 4 + b) / 8
					if luma < minLuma then minLuma = luma end
					if luma > maxLuma then maxLuma = luma end
					local bin = math.floor(luma + 0.5) + 1
					hist[bin] = hist[bin] + 1
					if r < minChannel then minChannel = r end
					if g < minChannel then minChannel = g end
					if b < minChannel then minChannel = b end
					if r > maxChannel then maxChannel = r end
					if g > maxChannel then maxChannel = g end
					if b > maxChannel then maxChannel = b end
				end
			end
		end
	end

	return {
		width = width,
		height = height,
		bits = bits,
		channels = channels,
		photometric = photometric,
		minLuma = minLuma,
		maxLuma = maxLuma,
		minChannel = minChannel,
		maxChannel = maxChannel,
		hist = hist,
	}
end

function TiffReader.analyze(path)
	local data, rerr = readAllBytes(path)
	if not data then return nil, rerr end
	return TiffReader.analyzeData(data)
end

-- Luminance percentile (0..1) from the histogram: the luma value v such that
-- about p of all pixels are <= v. Used to ignore a few outlier pixels when
-- matching Lightroom's clipping indicator.
function TiffReader.percentile(stats, p)
	local hist = stats and stats.hist
	if not hist then return nil end
	local total = 0
	for i = 1, 256 do total = total + hist[i] end
	if total == 0 then return nil end
	local target = p * total
	local acc = 0
	for i = 1, 256 do
		acc = acc + hist[i]
		if acc > 0 and acc >= target then return i - 1 end
	end
	return 255
end

return TiffReader
