-- subtitle-font-helper.lua
-- mpv 专属字幕字体自动注入辅助脚本
--
-- 功能：
-- 在 mpv 启动时自动获取当前 mpv 进程 PID，调用 SubtitleFontHelper 守护进程执行即时注入，
-- 注入后即时拦截 GDI 字体加载，无需后台常驻 WMI 轮询进程。
--
-- 安装方法：
-- 1. 将本脚本放入 mpv 的 scripts 文件夹中（如 ~~/scripts/subtitle-font-helper.lua）
-- 2. 在 mpv.conf 中配置守护程序所在路径（若与脚本放在同级或已加入 PATH 则可自动识别）：
--    script-opts-append=subtitle_font_helper-daemon_path=C:\Path\To\SubtitleFontAutoLoaderDaemon.exe
--    或者创建 script-opts/subtitle_font_helper.conf：
--    daemon_path=C:\Path\To\SubtitleFontAutoLoaderDaemon.exe
--    auto_exit=yes
--    no_tray=no

local utils = require("mp.utils")
local msg = require("mp.msg")
local opt = require("mp.options")

local options = {
    -- 守护进程 SubtitleFontAutoLoaderDaemon.exe 的绝对路径或相对路径
    -- 默认为空，脚本会自动尝试常见路径查找
    daemon_path = "",

    -- 是否在 mpv 退出时自动关闭守护进程（伴生生命周期）
    auto_exit = true,

    -- 是否隐藏守护进程托盘图标（静默伴生运行）
    no_tray = false,

    -- 是否禁用该脚本
    disabled = false,
}

opt.read_options(options, "subtitle_font_helper")

local injected = false

-- 辅助函数：判断文件是否存在
local function file_exists(path)
    if not path or path == "" then return false end
    local info = utils.file_info(path)
    return info and not info.is_dir
end

-- 探测 SubtitleFontAutoLoaderDaemon.exe 的位置
local function resolve_daemon_path()
    if options.daemon_path ~= "" and file_exists(options.daemon_path) then
        return options.daemon_path
    end

    local script_dir = mp.get_script_directory()
    if script_dir then
        local candidates = {
            utils.join_path(script_dir, "SubtitleFontAutoLoaderDaemon.exe"),
            utils.join_path(script_dir, "SubtitleFontHelper/SubtitleFontAutoLoaderDaemon.exe"),
            utils.join_path(script_dir, "../SubtitleFontHelper/SubtitleFontAutoLoaderDaemon.exe"),
            utils.join_path(script_dir, "../ReleaseBuild/SubtitleFontAutoLoaderDaemon.exe"),
        }
        for _, path in ipairs(candidates) do
            if file_exists(path) then
                return path
            end
        end
    end

    -- 默认直接使用可执行文件名（依赖系统 PATH 或工作目录）
    return "SubtitleFontAutoLoaderDaemon.exe"
end

local function inject_font_helper()
    if injected or options.disabled then
        return
    end

    local pid = mp.get_property_native("pid") or (utils.getpid and utils.getpid())
    if not pid then
        msg.error("无法获取 mpv 进程 PID，取消字体注入")
        return
    end

    local daemon_path = resolve_daemon_path()
    msg.debug("找到 SubtitleFontAutoLoaderDaemon: " .. daemon_path)

    local args = {
        daemon_path,
        "-inject", tostring(pid),
        "-no-monitor", -- 禁用 WMI 轮询
    }

    if options.auto_exit then
        table.insert(args, "-auto-exit")
    end

    if options.no_tray then
        table.insert(args, "-no-tray")
    end

    msg.info(string.format("正在为当前 mpv (PID: %s) 注入 SubtitleFontHelper...", pid))

    -- 异步执行外部命令，不阻塞 mpv 播放主循环
    mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stdout = false,
        capture_stderr = false,
    }, function(success, res, err)
        if not success then
            msg.error("调用 SubtitleFontAutoLoaderDaemon 失败: " .. tostring(err))
        else
            msg.info(string.format("SubtitleFontHelper 注入成功 (PID: %s)", pid))
            injected = true
        end
    end)
end

-- 优先在 mpv 初始化时尽快注入，确保在字幕首次渲染前 Detours 挂钩生效
mp.register_event("file-loaded", inject_font_helper)
