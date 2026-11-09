-- Info.lua
-- Lightroom Classic plug-in manifest.

return {
	LrSdkVersion = 12.4,
	LrSdkMinimumVersion = 6.0,
	LrToolkitIdentifier = "com.oneclickgrade.lrc",
	LrPluginName = "一键调色",

	LrExportMenuItems = {
		{
			title = "一键调色",
			file = "Grade.lua",
			enabledWhen = "photosSelected",
		},
		{
			title = "一键调色·设置…",
			file = "SettingsDialog.lua",
		},
		{
			title = "一键调色·诊断…",
			file = "Diagnose.lua",
			enabledWhen = "photosSelected",
		},
	},

	LrLibraryMenuItems = {
		{
			title = "一键调色",
			file = "Grade.lua",
			enabledWhen = "photosSelected",
		},
		{
			title = "一键调色·设置…",
			file = "SettingsDialog.lua",
		},
		{
			title = "一键调色·诊断…",
			file = "Diagnose.lua",
			enabledWhen = "photosSelected",
		},
	},

	VERSION = { major = 1, minor = 2, revision = 0 },
}
