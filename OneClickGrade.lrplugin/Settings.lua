-- Settings.lua
-- Persistent plugin settings, stored through LrPrefs (one set per plugin).

local Settings = {}

local DEFAULTS = {
	-- How many levels to step back from the measured clipping point.
	margin = 5,
	-- "auto"   : analyse an exported TIFF and derive the endpoints
	-- "fixed"  : use highlightPoint / shadowPoint below, no export needed
	mode = "auto",
	-- How the endpoints are measured in "auto" mode:
	--   "extremes"   : absolute min / max luminance
	--   "percentile" : drop tailPercent% of the pixels at each end
	tailMode = "percentile",
	-- Tail share (percent of pixels) dropped at each end for "percentile".
	tailPercent = 0.2,
	highlightPoint = 240,
	shadowPoint = 15,
	-- Long edge of the temporary TIFF used for analysis (pixels).
	-- 512 is plenty for a histogram and renders much faster than 1600.
	longEdge = 512,
	-- Scratch folder. Files are deleted after each run.
	tempDir = "D:\\cache\\LrC",
	deleteTemp = true,
	historyName = "一键调色",
}

local function prefs()
	local ok, p = pcall(function()
		return LrPrefs.prefsForPlugin()
	end)
	if ok and type(p) == "table" then return p end
	return nil
end

function Settings.get(key)
	local p = prefs()
	if p and p[key] ~= nil then return p[key] end
	return DEFAULTS[key]
end

function Settings.set(key, value)
	local p = prefs()
	if not p then return end
	if value == nil or value == DEFAULTS[key] then
		p[key] = nil
	else
		p[key] = value
	end
end

function Settings.reset()
	for k in pairs(DEFAULTS) do
		Settings.set(k, nil)
	end
end

function Settings.defaults()
	local copy = {}
	for k, v in pairs(DEFAULTS) do copy[k] = v end
	return copy
end

function Settings.all()
	local out = {}
	for k in pairs(DEFAULTS) do
		out[k] = Settings.get(k)
	end
	return out
end

return Settings
