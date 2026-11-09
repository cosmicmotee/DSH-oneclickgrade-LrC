-- Curve.lua
-- Helpers for Lightroom's point tone curve (ToneCurve / ToneCurveName).
--
-- Lightroom stores the point curve either as a flat array of numbers
--   { x1, y1, x2, y2, ... }            (values 0-255, like the "crs:ToneCurve" XMP)
-- or, in some builds, as an array of points
--   { {x=.., y=..}, ... }  /  { {x1,y1}, ... }
-- Both shapes are accepted here.  All produced coordinates are integers so that
-- the result can be written straight back to applyDevelopSettings().

local Curve = {}

local function round(x)
	return math.floor(x + 0.5)
end

-- Normalise a raw ToneCurve value into an array of {x=, y=} points.
-- Returns points, format ("flat" | "points" | "empty" | "unknown")
function Curve.parse(raw)
	if type(raw) ~= "table" then return {}, "empty" end

	local first = raw[1]
	if type(first) == "number" then
		local pts = {}
		local i = 1
		while raw[i] ~= nil do
			local x, y = raw[i], raw[i + 1]
			if type(x) ~= "number" or type(y) ~= "number" then break end
			pts[#pts + 1] = { x = x, y = y }
			i = i + 2
		end
		if #pts == 0 then return {}, "flat" end
		return pts, "flat"
	elseif type(first) == "table" then
		local pts = {}
		for i = 1, #raw do
			local p = raw[i]
			local x = p.x or p[1]
			local y = p.y or (p[1] and p[2])
			if type(x) == "number" and type(y) == "number" then
				pts[#pts + 1] = { x = x, y = y }
			end
		end
		return pts, "points"
	end

	return {}, "unknown"
end

local function looksLinear(points)
	if #points <= 2 then return true end
	for _, p in ipairs(points) do
		if math.abs(p.x - p.y) > 1 then return false end
	end
	return true
end

-- Sort by x (simple insertion sort; curves never have many points) and drop
-- points that would break strict monotonicity.
local function normalise(points)
	table.sort(points, function(a, b) return a.x < b.x end)
	local out = {}
	for _, p in ipairs(points) do
		local prev = out[#out]
		if not prev or p.x > prev.x then
			out[#out + 1] = p
		end
	end
	return out
end

-- Build the new curve.
--   currentRaw : the ToneCurve value read from getDevelopSettings (may be nil)
--   minLuma    : darkest luminance found in the image (0-255)
--   maxLuma    : brightest luminance found in the image (0-255)
--   opts       : { margin = 5 }  how many levels to step back from clipping
--
-- Returns a table:
--   points   : array of {x=, y=} integers
--   flat     : flat numeric array {x1,y1,...} ready for applyDevelopSettings
--   x, y     : the two endpoint inputs that were used
--   kept     : true when the user's custom mid-points were preserved
function Curve.build(currentRaw, minLuma, maxLuma, opts)
	opts = opts or {}
	local margin = opts.margin or 5

	-- Clamp to the 0..255 domain Lightroom uses.
	if minLuma < 0 then minLuma = 0 end
	if maxLuma > 255 then maxLuma = 255 end

	local x = round(maxLuma + margin)      -- highlight end input
	local y = round(minLuma - margin)      -- shadow end input
	if x > 255 then x = 255 end
	if y < 0 then y = 0 end
	if x <= y then
		-- Degenerate (flat image or huge margin): keep a legal, barely-open curve.
		x = math.min(255, y + 1)
	end

	local current, _ = Curve.parse(currentRaw)
	local kept = false
	local points

	if #current <= 2 or looksLinear(current) then
		points = { { x = y, y = 0 }, { x = x, y = 255 } }
	else
		-- Preserve the user's custom shape: remap the inner x positions from the
		-- old 0..255 domain into the new y..x domain, keep the outputs untouched.
		kept = true
		points = { { x = y, y = 0 } }
		for _, p in ipairs(current) do
			if p.x > 0 and p.x < 255 then
				local nx = y + (p.x / 255) * (x - y)
				nx = round(nx)
				if nx > y and nx < x then
					points[#points + 1] = { x = nx, y = round(p.y) }
				end
			end
		end
		points[#points + 1] = { x = x, y = 255 }
		points = normalise(points)
	end

	local flat = {}
	for _, p in ipairs(points) do
		flat[#flat + 1] = p.x
		flat[#flat + 1] = p.y
	end

	return {
		points = points,
		flat = flat,
		x = x,
		y = y,
		kept = kept,
		margin = margin,
		isStraightInput = (#current <= 2 or looksLinear(current)),
	}
end

-- Convert points back to the { {x=,y=}, ... } shape.
function Curve.toPointTable(points)
	local out = {}
	for i, p in ipairs(points) do
		out[i] = { x = p.x, y = p.y }
	end
	return out
end

Curve.round = round

return Curve
