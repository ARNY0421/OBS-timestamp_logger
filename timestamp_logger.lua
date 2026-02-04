obs = obslua
local ffi = require("ffi")

ffi.cdef[[
    int MultiByteToWideChar(unsigned int CodePage, unsigned long dwFlags, const char* lpMultiByteStr, int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
    void* _wfopen(const wchar_t* filename, const wchar_t* mode);
    int fclose(void* stream);
    int fputs(const char* str, void* stream);
    int fflush(void* stream);
    int MessageBoxW(void* hWnd, const wchar_t* lpText, const wchar_t* lpCaption, unsigned int uType);
]]

-- Helper for MessageBox (UTF-16)
local function message_box(text, caption, flags)
    local CP_UTF8 = 65001
    
    local wtext_len = ffi.C.MultiByteToWideChar(CP_UTF8, 0, text, -1, nil, 0)
    local wtext = ffi.new("wchar_t[?]", wtext_len)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, text, -1, wtext, wtext_len)
    
    local wcaption_len = ffi.C.MultiByteToWideChar(CP_UTF8, 0, caption, -1, nil, 0)
    local wcaption = ffi.new("wchar_t[?]", wcaption_len)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, caption, -1, wcaption, wcaption_len)
    
    return ffi.C.MessageBoxW(nil, wtext, wcaption, flags)
end

-- Helper for Unicode paths
local function open_file_utf8(path, mode)
    local CP_UTF8 = 65001
    
    -- Convert path to UTF-16
    local wpath_len = ffi.C.MultiByteToWideChar(CP_UTF8, 0, path, -1, nil, 0)
    if wpath_len == 0 then return nil end
    local wpath = ffi.new("wchar_t[?]", wpath_len)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, wpath_len)
    
    -- Convert mode to UTF-16
    local wmode_len = ffi.C.MultiByteToWideChar(CP_UTF8, 0, mode, -1, nil, 0)
    local wmode = ffi.new("wchar_t[?]", wmode_len)
    ffi.C.MultiByteToWideChar(CP_UTF8, 0, mode, -1, wmode, wmode_len)
    
    return ffi.C._wfopen(wpath, wmode)
end


-- Global variables
local current_log_file = nil
local output_directory = ""
local hotkey_id = obs.OBS_INVALID_HOTKEY_ID
local start_time = 0
local timeout_minutes = 30 -- Default 30 minutes

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "timeout_minutes", 30)
end

function script_description()
    return "配信または録画開始時にタイムスタンプ用ログファイルを作成し、ホットキー押下で時刻を記録します。\n\n(Lua Version)"
end

function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_path(props, "output_directory", "保存先フォルダ", obs.OBS_PATH_DIRECTORY, "", "")
    
    local p = obs.obs_properties_add_int(props, "timeout_minutes", "再開確認を行う時間（分）", 1, 1440, 1)
    obs.obs_property_set_long_description(p, "配信終了からこの時間以内に再開した場合、続きから記録するか確認します。")
    
    return props
end

function script_update(settings)
    output_directory = obs.obs_data_get_string(settings, "output_directory")
    timeout_minutes = obs.obs_data_get_int(settings, "timeout_minutes")
end

function create_log_file()
    if output_directory == "" then
        print("[Timestamp Logger] 保存先フォルダが設定されていません。")
        return
    end

    local now_str = os.date("%Y-%m-%d_%H-%M")
    local filename = now_str .. ".txt"
    -- Windows path handling
    local sep = package.config:sub(1,1)
    
    -- Ensure directory ends with separator if not empty
    local dir = output_directory
    if string.sub(dir, -1) ~= sep and string.sub(dir, -1) ~= "/" and string.sub(dir, -1) ~= "\\" then
        dir = dir .. sep
    end

    current_log_file = dir .. filename
    start_time = os.time()
    
    -- Use FFI to open file with Unicode support
    local f = open_file_utf8(current_log_file, "w")
    if f ~= nil then
        -- Write BOM for UTF-8 (optional, but good for some editors)
        -- ffi.C.fputs("\xEF\xBB\xBF", f) 
        ffi.C.fputs("Timestamp Log: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n\n", f)
        ffi.C.fclose(f)
        print("[Timestamp Logger] Created new log file: " .. current_log_file)
    else
        print("[Timestamp Logger] Failed to create log file: " .. current_log_file)
        current_log_file = nil
    end
end

function close_log_file()
    if current_log_file then
        print("[Timestamp Logger] Finished logging to: " .. current_log_file)
        current_log_file = nil
    end
end

function on_hotkey(pressed)
    if not pressed then
        return
    end

    if current_log_file then
        local current_time = os.time()
        local elapsed = os.difftime(current_time, start_time)
        local timestamp = os.date("!%H:%M:%S", elapsed)
        local f = open_file_utf8(current_log_file, "a")
        if f ~= nil then
            ffi.C.fputs(timestamp .. "\n", f)
            ffi.C.fclose(f)
            print("[Timestamp Logger] Marked: " .. timestamp)
        else
            print("[Timestamp Logger] Write error for file: " .. current_log_file)
        end
    else
        print("[Timestamp Logger] Warn: Hotkey pressed but no active log file (Stream/Record not active).")
    end
end

function on_event(event)
    if event == obs.OBS_FRONTEND_EVENT_STREAMING_STARTED then
        print("[Timestamp Logger] Streaming started.")
        -- Defer the check to avoid blocking the event handler directly (which causes crashes)
        obs.timer_add(defer_resume_check, 1000)
        
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        print("[Timestamp Logger] Recording started.")
        obs.timer_add(defer_resume_check, 1000)
        
    elseif event == obs.OBS_FRONTEND_EVENT_STREAMING_STOPPED then
        if not obs.obs_frontend_recording_active() then
            print("[Timestamp Logger] Streaming stopped.")
            save_session_data() -- Save state for potential resume
            close_log_file()
        end
    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        if not obs.obs_frontend_streaming_active() then
            print("[Timestamp Logger] Recording stopped.")
            save_session_data() -- Save state for potential resume
            close_log_file()
        end
    end
end

function script_load(settings)
    -- Register hotkey
    hotkey_id = obs.obs_hotkey_register_frontend("timestamp_logger_hotkey", "Timestamp Log: Mark Time", on_hotkey)
    
    -- Load saved hotkey data
    local hotkey_save_array = obs.obs_data_get_array(settings, "timestamp_logger_hotkey")
    obs.obs_hotkey_load(hotkey_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    -- Register event callback
    obs.obs_frontend_add_event_callback(on_event)
end

-- Timer callback for deferred check
function defer_resume_check()
    obs.timer_remove(defer_resume_check)
    if not try_resume_session() then
        create_log_file()
    end
end

-- Reconnection Logic Helpers
function get_session_file_path()
    -- Save session json in the output directory
    if output_directory == "" then return nil end
    local sep = package.config:sub(1,1)
    local dir = output_directory
    if string.sub(dir, -1) ~= sep and string.sub(dir, -1) ~= "/" and string.sub(dir, -1) ~= "\\" then
        dir = dir .. sep
    end
    return dir .. "timestamp_session.json"
end

function save_session_data(is_ended)
    local path = get_session_file_path()
    if not path then return end
    
    local data = obs.obs_data_create()
    -- No longer saving stream_key
    
    -- Calculate total elapsed time up to now
    local now = os.time()
    local elapsed = 0
    if start_time and start_time > 0 then
        elapsed = os.difftime(now, start_time)
    end
    
    -- If this is a final stop (not a crash/disconnect), we might want to flag it?
    -- But for now, we just save the state. 
    -- If user restarts within 10 mins, we resume.
    
    obs.obs_data_set_int(data, "total_elapsed_time", math.floor(elapsed))
    obs.obs_data_set_int(data, "last_active_time", now)
    obs.obs_data_set_string(data, "last_log_file", current_log_file or "")
    
    obs.obs_data_save_json(data, path)
    obs.obs_data_release(data)
end

function try_resume_session()
    local path = get_session_file_path()
    if not path then return false end
    
    local data = obs.obs_data_create_from_json_file(path)
    if not data then return false end
    
    local saved_elapsed = obs.obs_data_get_int(data, "total_elapsed_time")
    local last_active = obs.obs_data_get_int(data, "last_active_time")
    local saved_file = obs.obs_data_get_string(data, "last_log_file")
    
    obs.obs_data_release(data)
    
    local now = os.time()
    local limit_seconds = timeout_minutes * 60
    
    -- Logic: Check if within configured timeout
    if (now - last_active) < limit_seconds and saved_file ~= "" then
        -- Ask user via Popup
        local MB_YESNO = 0x00000004
        local MB_ICONQUESTION = 0x00000020
        local IDYES = 6
        
        local msg = "前回終了から" .. math.floor((now - last_active)/60) .. "分経過（設定:" .. timeout_minutes .. "分以内）しています。\n続きから記録しますか？\n(いいえを選ぶと新しいファイルになります)"
        local ret = message_box(msg, "Timestamp Logger", MB_YESNO + MB_ICONQUESTION)
        
        if ret == IDYES then
            -- Resume!
            current_log_file = saved_file
            
            -- Backdate start_time so that (now - start_time) equals saved_elapsed
            start_time = now - saved_elapsed
            
            print("[Timestamp Logger] Session Resumed! Elapsed so far: " .. saved_elapsed .. "s")
            
            local f = open_file_utf8(current_log_file, "a")
            if f ~= nil then
                ffi.C.fputs("[Resumed stream after " .. (now - last_active) .. "s break]\n", f)
                ffi.C.fclose(f)
            end
            return true
        end
    end
    
    return false
end

function script_save(settings)
    -- Save hotkey data
    local hotkey_save_array = obs.obs_hotkey_save(hotkey_id)
    obs.obs_data_set_array(settings, "timestamp_logger_hotkey", hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)
end
