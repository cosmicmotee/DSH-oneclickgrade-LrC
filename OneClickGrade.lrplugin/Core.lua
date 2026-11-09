-- Core.lua
-- Shared implementation for the "one click grade" menu commands.

local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'
local LrDate = import 'LrDate'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrExportSession = import 'LrExportSession'

-- Lightroom's Lua sandbox has no 'package' library, so sibling modules are
-- loaded by path; require() is tried first in case it is wired up.
local function loadModule(name)
	local ok, mod = pcall(function() return require(name) end)
	if ok and mod then return mod end
	local path = ((_PLUGIN and _PLUGIN.path) or ".") .. "/" .. name .. ".lua"
	local chunk, err = loadfile(path)
	if not chunk then
		error(string.format("无法加载模块 %s：%s", name, tostring(err)))
	end
	return chunk()
end

local Settings = loadModule("Settings")
local TiffReader = loadModule("TiffReader")
local Curve = loadModule("Curve")

local Core = {}

local BASIC_SETTINGS = {
	Highlights2012 = -100,
	Shadows2012 = 100,
	Whites2012 = -100,
	Blacks2012 = 100,
}

Core.BASIC_SETTINGS = BASIC_SETTINGS

function Core.selectedPhotos()
	local catalog = LrApplication.activeCatalog()
	return catalog:getTargetPhotos()
end

-- Lightroom cannot write develop settings to videos, so detect them up front
-- instead of letting a mixed selection report them as failures. fileFormat is
-- "VIDEO" for videos in the catalog; the extension check is a safety net for
-- formats where that metadata is unavailable.
function Core.isVideo(photo)
	local fmt = photo:getRawMetadata("fileFormat")
	if fmt == "VIDEO" or fmt == "Video" then return true end
	local path = photo:getRawMetadata("path")
	if type(path) == "string" then
		local ext = path:match("%.([%a%d]+)$")
		if ext then
			ext = ext:lower()
			if ext == "mov" or ext == "mp4" or ext == "avi" or ext == "mts"
				or ext == "m2ts" or ext == "m4v" or ext == "3gp" or ext == "wmv" or ext == "mkv" then
				return true
			end
		end
	end
	return false
end

-- getDevelopSettings may yield internally, and in Lua 5.1 a yield cannot cross
-- a pcall boundary, so it is called directly instead of being wrapped.
local function settingsApplied(photo, expected)
	local ds = photo:getDevelopSettings()
	if type(ds) ~= "table" then return false end
	for k, v in pairs(expected) do
		local got = ds[k]
		if type(v) == "number" then
			local n = tonumber(got)
			if not n or math.abs(n - v) > 0.01 then return false end
		elseif type(v) == "table" then
			if got == nil then return false end
		else
			if got ~= v then return false end
		end
	end
	return true
end

-- applyDevelopSettings commits with the write block, so the poll is a short
-- safety net, not a real wait.
local function waitForSettings(photo, expected, timeout)
	if settingsApplied(photo, expected) then return true end
	local deadline = LrDate.currentTime() + (timeout or 0.5)
	while LrDate.currentTime() < deadline do
		LrTasks.sleep(0.05)
		if settingsApplied(photo, expected) then return true end
	end
	return false
end

Core.waitForSettings = waitForSettings

-- Diagnostic helper: show what getDevelopSettings actually returns right after
-- a write, including the Lua type, so a mismatching poll can be explained.
function Core.readBack(photo)
	local ds = photo:getDevelopSettings()
	if type(ds) ~= "table" then
		return "读取失败：返回 " .. type(ds)
	end
	local function pair(key)
		local value = ds[key]
		return string.format("%s(%s)", tostring(value), type(value))
	end
	return string.format("Highlights2012=%s Shadows2012=%s Whites2012=%s Blacks2012=%s ToneCurvePV2012=%s",
		pair("Highlights2012"), pair("Shadows2012"), pair("Whites2012"), pair("Blacks2012"),
		pair("ToneCurvePV2012"))
end

-- applyDevelopSettings must run inside a write-access block. The block itself
-- must not yield, so the "wait until the setting lands" polling stays outside.
local function withWrite(catalog, name, fn)
	catalog:withWriteAccessDo(name, fn, { timeout = 5 })
end

function Core.applyBasic(photo, historyName)
	local settings = {}
	for k, v in pairs(BASIC_SETTINGS) do settings[k] = v end
	local catalog = LrApplication.activeCatalog()
	withWrite(catalog, historyName .. "·基础", function()
		photo:applyDevelopSettings(settings, historyName .. "·基础")
	end)
	-- applyDevelopSettings commits with the write block; the poll is only a
	-- safety net. A slow disk can swallow the first write, so retry once
	-- before reporting the photo as unconfirmed.
	if waitForSettings(photo, settings, 1.0) then return true end
	withWrite(catalog, historyName .. "·基础（重试）", function()
		photo:applyDevelopSettings(settings, historyName .. "·基础（重试）")
	end)
	return waitForSettings(photo, settings, 1.5)
end


-- Batch helpers: one write-access block per batch instead of one per photo.
-- withWriteAccessDo cannot yield, so the "did it land?" polls run outside.
local BATCH_SIZE = 100

local function chunks(list, size)
	local batches = {}
	for i = 1, #list, size do
		local batch = {}
		for j = i, math.min(i + size - 1, #list) do
			batch[#batch + 1] = list[j]
		end
		batches[#batches + 1] = batch
	end
	return batches
end

function Core.applyBasicMany(photos, historyName, onProgress)
	local settings = {}
	for k, v in pairs(BASIC_SETTINGS) do settings[k] = v end
	local catalog = LrApplication.activeCatalog()
	local batches = chunks(photos, BATCH_SIZE)
	local unconfirmed = {}
	for bi, batch in ipairs(batches) do
		withWrite(catalog, historyName .. "·基础", function()
			for _, photo in ipairs(batch) do
				photo:applyDevelopSettings(settings, historyName .. "·基础")
			end
		end)
		local retry = {}
		for _, photo in ipairs(batch) do
			if not waitForSettings(photo, settings, 0.3) then
				retry[#retry + 1] = photo
			end
		end
		if #retry > 0 then
			withWrite(catalog, historyName .. "·基础（重试）", function()
				for _, photo in ipairs(retry) do
					photo:applyDevelopSettings(settings, historyName .. "·基础（重试）")
				end
			end)
			for _, photo in ipairs(retry) do
				if not waitForSettings(photo, settings, 0.5) then
					unconfirmed[#unconfirmed + 1] = photo
				end
			end
		end
		if onProgress and onProgress(bi / #batches) == false then break end
	end
	return unconfirmed
end

function Core.applyCurveMany(items, historyName, onProgress)
	local catalog = LrApplication.activeCatalog()
	local pending = {}
	for _, item in ipairs(items) do
		if item.curve then pending[#pending + 1] = item end
	end
	local batches = chunks(pending, BATCH_SIZE)
	local unconfirmed = {}
	for bi, batch in ipairs(batches) do
		withWrite(catalog, historyName .. "·曲线", function()
			for _, item in ipairs(batch) do
				item.photo:applyDevelopSettings({
					ToneCurveName2012 = "Custom",
					ToneCurvePV2012 = item.curve.flat,
				}, historyName .. "·曲线")
			end
		end)
		local retry = {}
		for _, item in ipairs(batch) do
			if not waitForSettings(item.photo, { ToneCurvePV2012 = item.curve.flat }, 0.3) then
				retry[#retry + 1] = item
			end
		end
		if #retry > 0 then
			withWrite(catalog, historyName .. "·曲线（重试）", function()
				for _, item in ipairs(retry) do
					item.photo:applyDevelopSettings({
						ToneCurveName2012 = "Custom",
						ToneCurvePV2012 = item.curve.flat,
					}, historyName .. "·曲线（重试）")
				end
			end)
			for _, item in ipairs(retry) do
				if not waitForSettings(item.photo, { ToneCurvePV2012 = item.curve.flat }, 0.5) then
					unconfirmed[#unconfirmed + 1] = item
				end
			end
		end
		if onProgress and onProgress(bi / #batches) == false then break end
	end
	return unconfirmed
end

function Core.applyCurve(photo, curve, historyName)
	-- LrC 12.x uses the PV2012 process version, where the legacy ToneCurve key
	-- is ignored. ToneCurvePV2012 is a flat { x1, y1, x2, y2, ... } array over
	-- 0..255, and ToneCurveName2012 should say "Custom" when the shape is ours.
	local settings = {
		ToneCurveName2012 = "Custom",
		ToneCurvePV2012 = curve.flat,
	}
	local catalog = LrApplication.activeCatalog()
	withWrite(catalog, historyName .. "·曲线", function()
		photo:applyDevelopSettings(settings, historyName .. "·曲线")
	end)
	if waitForSettings(photo, { ToneCurvePV2012 = curve.flat }, 1.0) then return true end
	withWrite(catalog, historyName .. "·曲线（重试）", function()
		photo:applyDevelopSettings(settings, historyName .. "·曲线（重试）")
	end)
	return waitForSettings(photo, { ToneCurvePV2012 = curve.flat }, 1.5)
end

-- Build the export settings used for the analysis TIFF.
-- opts.colorSpace ("sRGB" | "ProPhotoRGB") and opts.bitDepth (8 | 16) let the
-- diagnostic compare how the two encodings map onto Lightroom's curve scale.
function Core.exportSettingsFor(outDir, longEdge, opts)
	opts = opts or {}
	return {
		LR_export_destinationType = "specificFolder",
		LR_export_destinationPathPrefix = outDir,
		LR_export_useSubfolder = false,
		LR_format = "TIFF",
		LR_export_bitDepth = opts.bitDepth or 8,
		LRtiff_compressionMethod = "compressionMethod_None",
		LR_export_colorSpace = opts.colorSpace or "sRGB",
		LR_size_doConstrain = true,
		LR_size_units = "pixels",
		LR_size_resizeType = "longEdge",
		LR_size_maxWidth = longEdge,
		LR_size_maxHeight = longEdge,
		LR_size_doNotEnlarge = true,
		LR_outputSharpeningOn = false,
		LR_export_useSmartPreview = false,
		LR_reimportExportedPhoto = false,
		LR_collisionHandling = "overwrite",
		LR_renamingTokensOn = true,
		LR_tokens = "{{image_name}}",
		LR_extensionCase = "lowercase",
	}
end

-- Export the given photos to outDir and return
--   { { photo = <LrPhoto>, path = <string>, stats = <table|nil>, error = <string|nil> }, ... }
function Core.exportAndAnalyze(photos, outDir, longEdge, opts)
	local session = LrExportSession({
		photosToExport = photos,
		exportSettings = Core.exportSettingsFor(outDir, longEdge, opts),
	})
	-- renditions() is an iterator; waitForRender() drives and waits for each
	-- rendition, then destinationPath points at the finished TIFF.
	local results = {}
	for i, rendition in session:renditions() do
		local rendered, pathOrMessage = rendition:waitForRender()
		local item = {
			photo = rendition.photo,
			path = rendition.destinationPath,
		}
		if rendered and item.path then
			local stats, err = TiffReader.analyze(item.path)
			item.stats = stats
			item.error = err
		else
			item.error = tostring(pathOrMessage)
		end
		results[#results + 1] = item
	end
	return results
end

function Core.makeTempDir(settings)
	local base = settings.tempDir
	if not base or base == "" then
		base = LrPathUtils.getStandardFilePath("temp")
	end
	local name = "OneClickGrade_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
	local dir = LrPathUtils.child(base, name)
	local ok = pcall(function()
		LrFileUtils.createAllDirectories(dir)
	end)
	if not ok or not LrFileUtils.exists(dir) then
		-- Fall back to the system temp folder so the feature still works.
		dir = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), name)
		LrFileUtils.createAllDirectories(dir)
	end
	return dir
end

-- Recursively delete a directory tree (best effort).
function Core.removeTree(path)
	if not path then return end
	local ok, entries = pcall(function()
		return LrFileUtils.directoryEntries(path)
	end)
	if ok and type(entries) == "table" then
		for _, entry in ipairs(entries) do
			if entry ~= "." and entry ~= ".." then
				local child = LrPathUtils.child(path, entry)
				local isDir = false
				pcall(function()
					isDir = LrFileUtils.isDirectory(child)
				end)
				if isDir then
					Core.removeTree(child)
				else
					pcall(function()
						LrFileUtils.delete(child)
					end)
				end
			end
		end
	end
	pcall(function()
		os.remove(path)
	end)
end

-- Resolve the curve for one photo.
-- In "auto" mode a stats table is required; in "fixed" mode it is not.
function Core.buildCurve(photo, stats, settings)
	local develop = photo:getDevelopSettings() or {}
	local currentCurve = develop.ToneCurvePV2012 or develop.ToneCurve

	local minLuma, maxLuma
	if settings.mode == "fixed" then
		minLuma = settings.shadowPoint
		maxLuma = settings.highlightPoint
	else
		if not stats then return nil, "没有可用的亮度分析结果" end
		if settings.tailMode == "percentile" then
			local tail = math.max(0, math.min(5, settings.tailPercent or 0.2)) / 100
			minLuma = TiffReader.percentile(stats, tail)
			maxLuma = TiffReader.percentile(stats, 1 - tail)
			if not minLuma or not maxLuma or maxLuma <= minLuma then
				minLuma, maxLuma = stats.minLuma, stats.maxLuma
			end
		else
			minLuma = stats.minLuma
			maxLuma = stats.maxLuma
		end
	end

	local curve = Curve.build(currentCurve, minLuma, maxLuma, { margin = settings.margin })
	curve.minLuma = minLuma
	curve.maxLuma = maxLuma
	return curve
end

return Core
