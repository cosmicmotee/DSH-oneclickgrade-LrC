-- Diagnose.lua
-- Read-only diagnostic: shows the current develop settings, exports one TIFF
-- and reports the measured luminance range plus the curve the plug-in would set.

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

local LrTasks = import 'LrTasks'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrDate = import 'LrDate'

local Core = loadModule("Core")
local Settings = loadModule("Settings")
local Curve = loadModule("Curve")
local TiffReader = loadModule("TiffReader")

-- Metadata calls may yield, so they are called directly rather than inside
-- pcall (Lua 5.1 cannot yield across a C call).
local function photoName(photo)
	local name = photo:getFormattedMetadata("fileName")
	if name and name ~= "" then return name end
	name = photo:getRawMetadata("path")
	if name and name ~= "" then
		local leaf = LrPathUtils.leafName(name)
		if leaf and leaf ~= "" then return leaf end
	end
	return "?"
end

local function dump(v, depth)
	if type(v) ~= "table" then return tostring(v) end
	if depth > 2 then return "{...}" end
	local parts = {}
	local n = 0
	for k, val in pairs(v) do
		n = n + 1
		if n > 40 then
			parts[#parts + 1] = "…"
			break
		end
		parts[#parts + 1] = tostring(k) .. "=" .. dump(val, depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext("OneClickGradeDiagnose", function(context)
		local photos = Core.selectedPhotos()
		if not photos or #photos == 0 then
			LrDialogs.message("一键调色 · 诊断", "请先选中一张照片。", "info")
			return
		end

		local photo = photos[1]
		local settings = Settings.all()
		local lines = {}
		-- The export below waits on Lightroom's async rendering, so it must not
		-- run inside pcall: Lua 5.1 cannot yield across a C call.
		do
			lines[#lines + 1] = "照片：" .. photoName(photo)
			lines[#lines + 1] = "  formatted.fileName = " .. tostring(photo:getFormattedMetadata("fileName"))
			lines[#lines + 1] = "  raw.path = " .. tostring(photo:getRawMetadata("path"))

			local ds = photo:getDevelopSettings() or {}
			for _, key in ipairs {
				"ConvertToGrayscale", "Highlights2012", "Shadows2012",
				"Whites2012", "Blacks2012", "ToneCurveName", "ToneCurvePV2012",
			} do
				lines[#lines + 1] = key .. " = " .. dump(ds[key], 0)
			end
			lines[#lines + 1] = "ToneCurve = " .. dump(ds.ToneCurve, 0)

			local function report(label, tempDir, opts)
				local exported = Core.exportAndAnalyze({ photo }, tempDir, settings.longEdge, opts)
				local item = exported and exported[1]
				lines[#lines + 1] = label .. " → " .. tempDir
				if item and item.stats then
					local s = item.stats
					local function pct(p)
						return TiffReader.percentile(s, p) or 0
					end
					lines[#lines + 1] = string.format(
						"  亮度 %.1f–%.1f ｜ 低端 p0.1=%d p0.2=%d p0.3=%d p0.5=%d p1=%d ｜ 高端 p99=%d p99.5=%d p99.7=%d p99.8=%d p99.9=%d",
						s.minLuma, s.maxLuma,
						pct(0.001), pct(0.002), pct(0.003), pct(0.005), pct(0.01),
						pct(0.99), pct(0.995), pct(0.997), pct(0.998), pct(0.999))
					local curve, curveErr = Core.buildCurve(photo, s, settings)
					if curve then
						local how = settings.tailMode == "percentile"
							and string.format("分位，两端各裁 %.2f%%", settings.tailPercent or 0.2)
							or "绝对极值"
						lines[#lines + 1] = string.format(
							"  当前设置（%s）：(%d, 0) → (%d, 255)", how, curve.y, curve.x)
					else
						lines[#lines + 1] = "  无法计算曲线：" .. tostring(curveErr)
					end
					local extreme = Curve.build(ds.ToneCurvePV2012 or ds.ToneCurve,
						s.minLuma, s.maxLuma, { margin = settings.margin })
					lines[#lines + 1] = string.format(
						"  绝对极值参考：(%d, 0) → (%d, 255)", extreme.y, extreme.x)
				else
					lines[#lines + 1] = "  解析失败：" .. tostring(item and item.error or "没有导出结果")
				end
			end

			report("sRGB 8bit", Core.makeTempDir(settings), {})
			report("ProPhoto 16bit", Core.makeTempDir(settings), { colorSpace = "ProPhotoRGB", bitDepth = 16 })

		end

		LrDialogs.message("一键调色 · 诊断", table.concat(lines, "\n"), "info")
	end)
end)
