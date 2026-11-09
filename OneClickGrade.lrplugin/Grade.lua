-- Grade.lua
-- Entry point for the "一键调色" Library / Develop menu command.

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
local LrDialogs = import 'LrDialogs'
local LrProgressScope = import 'LrProgressScope'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrDate = import 'LrDate'

local Core = loadModule("Core")
local Settings = loadModule("Settings")

-- Same pcall caveat: these metadata calls may yield, so call them directly.
-- getFormattedMetadata("fileName") can come back nil for some catalogs; fall
-- back to raw metadata, the absolute path and finally the exported TIFF name.
local function photoName(photo, pathFallback)
	local name = photo:getFormattedMetadata("fileName")
	if name and name ~= "" then return name end
	name = photo:getRawMetadata("fileName")
	if name and name ~= "" then return name end
	name = photo:getRawMetadata("path")
	if name and name ~= "" then
		local leaf = LrPathUtils.leafName(name)
		if leaf and leaf ~= "" then return leaf end
	end
	if pathFallback and pathFallback ~= "" then
		local leaf = LrPathUtils.leafName(pathFallback)
		if leaf and leaf ~= "" then
			leaf = leaf:gsub("%.[Tt][Ii][Ff][Ff]?$", "")
			if leaf ~= "" then return leaf end
		end
	end
	return "<未知照片>"
end

LrTasks.startAsyncTask(function()
	local startedAt = LrDate.currentTime()
	LrFunctionContext.callWithContext("OneClickGrade", function(context)
		local selected = Core.selectedPhotos()
		if not selected or #selected == 0 then
			LrDialogs.message("一键调色", "请先在 Lightroom 中选中至少一张照片。", "info")
			return
		end

		-- Videos have no develop settings; drop them before the batch starts.
		local photos, skippedVideos = {}, 0
		for _, photo in ipairs(selected) do
			if Core.isVideo(photo) then
				skippedVideos = skippedVideos + 1
			else
				photos[#photos + 1] = photo
			end
		end
		if #photos == 0 then
			LrDialogs.message("一键调色",
				string.format("选中的 %d 个文件都是视频，已跳过。", skippedVideos), "info")
			return
		end

		local settings = Settings.all()
		local progress = LrProgressScope({
			title = "一键调色",
			functionContext = context,
		})
		progress:setCancelable(true)

		local tempDir
		local results = {}
		local tBasic, tExport, tCurve = 0, 0, 0
		local waitFailures, firstFailPhoto = 0, nil
		local basicUnconfirmed = {}

		-- Steps 1-2 run directly: in Lua 5.1 a coroutine may not yield across
		-- pcall (a C call), and these steps wait on Lightroom's async APIs.
		do
			-- Step 1: basic tone ----------------------------------------------
			-- The photo stays in colour. "Black & white" here is an analysis
			-- model (luma), not a treatment: the tone range used for the curve
			-- is measured from the luminance of this colour+basic image.
			progress:setCaption("步骤 1/2：调整基础影调")
			for i, photo in ipairs(photos) do
				if progress:isCanceled() then return end
				progress:setPortionComplete((i - 1) / #photos)
				local t0 = LrDate.currentTime()
				local confirmed = Core.applyBasic(photo, settings.historyName)
				tBasic = tBasic + (LrDate.currentTime() - t0)
				if not confirmed then
					waitFailures = waitFailures + 1
					firstFailPhoto = firstFailPhoto or photo
					basicUnconfirmed[photo] = true
				end
			end

			-- Step 2: measure the tone range and write the point curve ----------
			if settings.mode == "auto" then
				progress:setCaption("步骤 2/2：分析高光 / 阴影并设置曲线")
				tempDir = Core.makeTempDir(settings)
				local t0 = LrDate.currentTime()
				results = Core.exportAndAnalyze(photos, tempDir, settings.longEdge)
				tExport = LrDate.currentTime() - t0
			else
				progress:setCaption("步骤 2/2：使用固定端点设置曲线")
				for _, photo in ipairs(photos) do
					results[#results + 1] = { photo = photo }
				end
			end

			for i, item in ipairs(results) do
				if progress:isCanceled() then return end
				progress:setPortionComplete((i - 1) / math.max(1, #results))
				local curve, curveError = Core.buildCurve(item.photo, item.stats, settings)
				if curve then
					local t0 = LrDate.currentTime()
					local confirmed = Core.applyCurve(item.photo, curve, settings.historyName)
					tCurve = tCurve + (LrDate.currentTime() - t0)
					if not confirmed then
						waitFailures = waitFailures + 1
						firstFailPhoto = firstFailPhoto or item.photo
						item.error = item.error or "曲线设置未生效"
					end
					item.curve = curve
				else
					item.error = curveError
				end
			end
		end

		if settings.deleteTemp and tempDir then
			Core.removeTree(tempDir)
		end
		progress:done()

		-- Build the summary ------------------------------------------------------
		-- Only the file name is reported per photo: the measured tone range and
		-- the p0.5/p99.5 probes are inputs to the endpoint maths, not results
		-- the user needs to read.
		local lines = {}
		local failedLines = {}
		local done, problems = 0, 0
		for _, item in ipairs(results) do
			local name = photoName(item.photo, item.path)
			local reason = item.error
			if not reason and basicUnconfirmed[item.photo] then
				reason = "基础设置未生效"
			end
			if item.curve and not reason then
				done = done + 1
				lines[#lines + 1] = "✔ " .. name
			else
				problems = problems + 1
				failedLines[#failedLines + 1] = "✘ " .. name .. "：" .. tostring(reason or "未知错误")
			end
		end

		local elapsed = LrDate.currentTime() - startedAt
		local perPhoto = elapsed / math.max(1, #photos)
		local summary = string.format("已处理 %d 张照片，成功 %d 张，总耗时 %.1f 秒（平均 %.1f 秒/张）。",
			#photos, done, elapsed, perPhoto)
		summary = summary .. string.format("\n耗时明细：基础 %.1f 秒，分析导出 %.1f 秒，曲线 %.1f 秒。",
			tBasic, tExport, tCurve)
		if skippedVideos > 0 then
			summary = summary .. string.format("\n已跳过 %d 个视频（视频不支持调色）。", skippedVideos)
		end
		if waitFailures > 0 and firstFailPhoto then
			summary = summary .. "\n⚠ 设置确认超时 " .. waitFailures .. " 次；示例：" .. Core.readBack(firstFailPhoto)
		end
		if problems > 0 then
			summary = summary .. string.format("\n%d 张需要注意：", problems)
		end
		local detail
		if problems > 0 then
			detail = table.concat(failedLines, "\n")
		elseif done > 0 and #photos <= 30 then
			detail = table.concat(lines, "\n")
		else
			detail = "全部成功。"
		end
		local message = summary .. "\n\n" .. detail
		if progress:isCanceled() then
			message = "操作已取消，已处理的步骤会保留在历史记录中。\n\n" .. message
		end
		LrDialogs.message("一键调色", message, problems > 0 and "warning" or "info")
	end)
end)
