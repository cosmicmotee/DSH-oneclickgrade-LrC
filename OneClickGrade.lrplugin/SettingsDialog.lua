-- SettingsDialog.lua
-- Modal settings dialog.

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
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'

local Settings = loadModule("Settings")

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext("OneClickGradeSettings", function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		local current = Settings.all()
		for k, v in pairs(current) do
			props[k] = v
		end

		local contents = f:column {
			spacing = f:control_spacing(),
			f:row {
				f:static_text { title = "端点回退量（级）：" },
				f:edit_field { value = LrView.bind("margin"), width_in_chars = 6, min_integer = 0, max_integer = 64 },
			},
			f:row {
				f:static_text { title = "判定方式：" },
				f:popup_menu {
					value = LrView.bind("mode"),
					items = {
						{ title = "自动（导出临时 TIFF 分析）", value = "auto" },
						{ title = "固定端点（不导出）", value = "fixed" },
					},
				},
			},
			f:row {
				f:static_text { title = "端点统计：" },
				f:popup_menu {
					value = LrView.bind("tailMode"),
					items = {
						{ title = "分位（推荐，贴近肉眼剪切）", value = "percentile" },
						{ title = "绝对极值", value = "extremes" },
					},
				},
			},
			f:row {
				f:static_text { title = "两端各裁掉（%）：" },
				f:edit_field { value = LrView.bind("tailPercent"), width_in_chars = 6, min_real = 0, max_real = 5, precision = 2 },
				f:static_text { title = " 0 = 与极值相同，调大可更贴手工" },
			},
			f:row {
				f:static_text { title = "固定高光点：" },
				f:edit_field { value = LrView.bind("highlightPoint"), width_in_chars = 6, min_integer = 0, max_integer = 255 },
				f:static_text { title = "固定阴影点：" },
				f:edit_field { value = LrView.bind("shadowPoint"), width_in_chars = 6, min_integer = 0, max_integer = 255 },
			},
			f:row {
				f:static_text { title = "分析用长边（像素）：" },
				f:edit_field { value = LrView.bind("longEdge"), width_in_chars = 8, min_integer = 400, max_integer = 8000 },
			},
			f:row {
				f:static_text { title = "临时目录：" },
				f:edit_field { value = LrView.bind("tempDir"), width_in_chars = 46 },
			},
			f:row {
				f:checkbox { title = "处理完成后删除临时文件", value = LrView.bind("deleteTemp") },
			},
			f:row {
				f:static_text {
					title = "自动模式会为每张照片导出一张临时 TIFF 用于测量亮度，处理完成后删除。",
					font = "<system/small>",
				},
			},
		}

		local result = LrDialogs.presentModalDialog {
			title = "一键调色 · 设置",
			contents = contents,
			actionVerb = "保存",
			cancelVerb = "取消",
		}

		if result == "ok" then
			Settings.set("margin", math.max(0, math.floor(tonumber(props.margin) or 5)))
			Settings.set("mode", props.mode == "fixed" and "fixed" or "auto")
			Settings.set("tailMode", props.tailMode == "extremes" and "extremes" or "percentile")
			Settings.set("tailPercent", math.max(0, math.min(5, tonumber(props.tailPercent) or 0.2)))
			Settings.set("highlightPoint", math.max(0, math.min(255, math.floor(tonumber(props.highlightPoint) or 240))))
			Settings.set("shadowPoint", math.max(0, math.min(255, math.floor(tonumber(props.shadowPoint) or 15))))
			Settings.set("longEdge", math.max(400, math.min(8000, math.floor(tonumber(props.longEdge) or 1600))))
			local dir = tostring(props.tempDir or "")
			if dir ~= "" then Settings.set("tempDir", dir) end
			Settings.set("deleteTemp", props.deleteTemp and true or false)
			LrDialogs.message("一键调色", "设置已保存。", "info")
		end
	end)
end)
