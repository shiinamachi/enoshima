-- ThinkPad X1 Carbon Gen 13 desktop configuration for Hyprland 0.55+.

local internalMonitor = "eDP-1"
local knownDellMonitor = "desc:Dell Inc. DELL U2725QE"

local terminal = "ghostty"
-- Arch's official `zed` package installs the CLI as `zeditor`.
local editor = "zeditor"
local browser = "google-chrome-stable"
local fileManager = "thunar"
local launcher = "cyberlauncher-toggle"

-- The balanced profile exposes a 1920x1200 logical workspace on the internal
-- 2.8K OLED at 1.5x while retaining 2560x1440 on the 27-inch Dell. Coordinates
-- are logical pixels and bottom-align the two panels.
hl.monitor({
    output = internalMonitor,
    mode = "2880x1800@120",
    position = "0x240",
    scale = 1.5,
    bitdepth = 8,
    cm = "srgb",
    vrr = 0,
})

hl.monitor({
    output = knownDellMonitor,
    mode = "3840x2160@120",
    position = "1920x0",
    scale = 1.5,
    bitdepth = 8,
    cm = "srgb",
    vrr = 0,
})

-- Every other output joins the desktop in extended mode. Automatic scale is
-- safer across projectors, standard-DPI displays, and high-DPI USB-C panels.
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto-right",
    scale = "auto",
    bitdepth = 8,
    cm = "srgb",
    vrr = 0,
})

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("XCURSOR_THEME", "capitaine-cursors")

hl.config({
    general = {
        gaps_in = 7,
        gaps_out = 14,
        border_size = 2,
        extend_border_grab_area = 24,
        resize_on_border = true,
        allow_tearing = false,
        layout = "dwindle",
        col = {
            active_border = {
                colors = {
                    "rgba(62d8ffff)",
                    "rgba(9a5cffff)",
                },
                angle = 45,
            },
            inactive_border = "rgba(6d8cff44)",
        },
    },

    decoration = {
        rounding = 12,
        rounding_power = 2.4,
        active_opacity = 1.0,
        inactive_opacity = 0.985,
        shadow = {
            enabled = true,
            range = 16,
            render_power = 3,
            color = "rgba(050623cc)",
            color_inactive = "rgba(05062388)",
            offset = { 0, 4 },
            scale = 0.98,
        },
        blur = {
            enabled = true,
            size = 7,
            passes = 2,
            xray = true,
            noise = 0.012,
            contrast = 0.92,
            brightness = 0.82,
            vibrancy = 0.16,
            vibrancy_darkness = 0.20,
            popups = true,
            popups_ignorealpha = 0.18,
            input_methods = false,
        },
    },

    animations = {
        enabled = true,
    },

    binds = {
        drag_threshold = 5,
        focus_preferred_method = 1,
    },

    dwindle = {
        preserve_split = true,
        smart_resizing = true,
        precise_mouse_move = true,
        use_active_for_splits = true,
    },

    input = {
        kb_layout = "us",
        kb_variant = "",
        kb_model = "",
        kb_options = "korean:ralt_hangul",
        kb_rules = "",
        follow_mouse = 1,
        sensitivity = 0,
        repeat_delay = 300,
        repeat_rate = 35,
        touchpad = {
            natural_scroll = false,
            tap_to_click = true,
            tap_and_drag = true,
            disable_while_typing = true,
            clickfinger_behavior = true,
        },
    },

    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        force_default_wallpaper = 0,
        focus_on_activate = true,
        render_unfocused_fps = 10,
        vrr = 0,
    },

    xwayland = {
        force_zero_scaling = true,
        use_nearest_neighbor = false,
    },
})

hl.curve("easeOutQuint", {
    type = "bezier",
    points = { { 0.23, 1 }, { 0.32, 1 } },
})
hl.curve("easeInOutCubic", {
    type = "bezier",
    points = { { 0.65, 0.05 }, { 0.36, 1 } },
})
hl.curve("quick", {
    type = "bezier",
    points = { { 0.15, 0 }, { 0.1, 1 } },
})

hl.animation({ leaf = "global", enabled = true, speed = 1.8, bezier = "easeOutQuint" })
hl.animation({ leaf = "border", enabled = true, speed = 1.1, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 1.8, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 1.8, bezier = "easeOutQuint", style = "popin 92%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.2, bezier = "quick", style = "popin 92%" })
hl.animation({ leaf = "fade", enabled = true, speed = 1.4, bezier = "quick" })
hl.animation({ leaf = "layers", enabled = true, speed = 1.8, bezier = "easeOutQuint" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 2.0, bezier = "easeInOutCubic", style = "slide" })

-- The official hyprfocus plugin is optional at parse time. Hyprpm loads it
-- after Hyprland starts and schedules a reload; the native active border stays
-- as the complete fallback when the plugin is unavailable or ABI-incompatible.
local function configureHyprfocus()
    local modernEnable = hl.get_config("plugin.hyprfocus.enable")
    local legacyMode = hl.get_config("plugin.hyprfocus.mode")

    if modernEnable ~= nil then
        hl.config({
            plugin = {
                hyprfocus = {
                    enable = true,
                    animate_floating = false,
                    only_on_monitor_change = false,
                    keyboard_focus_animation = "flash",
                    mouse_focus_animation = "none",
                    fade_opacity = 0.94,
                },
            },
        })
    elseif legacyMode ~= nil then
        hl.config({
            plugin = {
                hyprfocus = {
                    mode = "flash",
                    only_on_monitor_change = false,
                    fade_opacity = 0.94,
                },
            },
        })
    else
        return
    end

    hl.animation({ leaf = "hyprfocusIn", enabled = true, speed = 1.6, bezier = "easeOutQuint" })
    hl.animation({ leaf = "hyprfocusOut", enabled = true, speed = 1.1, bezier = "quick" })
end

configureHyprfocus()

local function configureEnoshimaDecoration()
    if hl.get_config("plugin.enoshima_decoration.enabled") == nil then
        return
    end

    hl.config({
        plugin = {
            enoshima_decoration = {
                enabled = true,
                allowlist = "mpv,imv,org.pwmt.zathura,discord,slack,com.slack.Slack,obsidian,md.obsidian,*notion*,rhwp*",
                bar_color = "rgba(0a0c3eff)",
                ["col.text"] = "rgba(f2ecffff)",
                inactive_button_color = "rgba(16115188)",
                bar_height = 36,
                bar_hit_height = 44,
                bar_text_size = 13,
                bar_text_font = "Pretendard",
                bar_text_align = "left",
                bar_buttons_alignment = "right",
                bar_padding = 8,
                bar_button_padding = 16,
                bar_part_of_window = true,
                bar_precedence_over_border = false,
                icon_on_hover = false,
                on_double_click = "desktop-window-action maximize --address {address} --origin titlebar",
            },
        },
    })

    -- Buttons are registered from right to left. Papirus vector icons remain
    -- crisp on mixed-DPI outputs; the 44px input extent is larger than the
    -- restrained 28px visual control.
    hl.plugin.enoshima_decoration.add_button({
        bg_color = "rgba(00000000)", fg_color = "rgba(f2ecffff)",
        size = 28, icon = "/usr/share/icons/Papirus/16x16/actions/window-close.svg",
        semantic = "close", tooltip = "Close · 닫기",
        action = "desktop-window-action close --address {address} --origin titlebar",
    })
    hl.plugin.enoshima_decoration.add_button({
        bg_color = "rgba(00000000)", fg_color = "rgba(f2ecffff)",
        size = 28, icon = "/usr/share/icons/Papirus/16x16/actions/window-maximize.svg",
        alternate_icon = "/usr/share/icons/Papirus/16x16/actions/window-restore.svg",
        semantic = "maximize", tooltip = "Maximize / Restore · 최대화 / 복원",
        action = "desktop-window-action maximize --address {address} --origin titlebar",
    })
    hl.plugin.enoshima_decoration.add_button({
        bg_color = "rgba(00000000)", fg_color = "rgba(f2ecffff)",
        size = 28, icon = "/usr/share/icons/Papirus/16x16/actions/window-minimize.svg",
        semantic = "minimize", tooltip = "Minimize · 최소화",
        action = "desktop-window-action minimize --address {address} --origin titlebar",
    })
end

configureEnoshimaDecoration()

local function reloadHyprlandPlugins()
    -- Never load a stale optional plugin set during login. Bootstrap first
    -- converges these flags and the ABI cache; only that reviewed state may be
    -- loaded into the compositor.
    hl.exec_cmd([[
test -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" &&
state="/var/cache/hyprpm/$USER/hyprland-plugins/state.toml" &&
awk '
    /^\[/ { section = $0 }
    section == "[hyprbars]" && $1 == "enabled" { hyprbars = $3 }
    section == "[hyprfocus]" && $1 == "enabled" { hyprfocus = $3 }
    END { exit !(hyprbars == "false" && hyprfocus == "true") }
' "$state" &&
hyprpm reload && enoshima-decoration-load
]])
end

hl.on("hyprland.start", reloadHyprlandPlugins)

hl.gesture({
    fingers = 3,
    direction = "horizontal",
    action = "workspace",
})

-- Five purpose-led workspaces keep navigation predictable without exposing
-- unused reserves in the overview, keymap, or Waybar.
for id = 1, 5 do
    hl.workspace_rule({
        workspace = tostring(id),
        persistent = true,
    })
end

-- Resolve the Dell from live output metadata instead of assuming a connector
-- name. USB-C docks may expose the same monitor as DP-1, DP-2, and so on after
-- reconnects. The helper is idempotent, so every topology change can converge
-- the workspace layout safely.
local function routeWorkspaces()
    hl.exec_cmd("workspace-output-route")
end

local function reconcileDisplays()
    hl.exec_cmd("desktop-display-mode reconcile")
end

local function applyAppearancePreferences()
    hl.exec_cmd("desktop-appearance apply")
end

hl.on("hyprland.start", routeWorkspaces)
hl.on("config.reloaded", routeWorkspaces)
hl.on("monitor.added", routeWorkspaces)
hl.on("monitor.layout_changed", routeWorkspaces)
hl.on("monitor.removed", routeWorkspaces)
hl.on("hyprland.start", reconcileDisplays)
hl.on("config.reloaded", reconcileDisplays)
hl.on("hyprland.start", applyAppearancePreferences)
hl.on("config.reloaded", applyAppearancePreferences)

local mainMod = "SUPER"
local launcherOptions = {
    dont_inhibit = true,
    description = "Open application launcher",
}

hl.bind(mainMod .. " + SPACE", hl.dsp.exec_cmd(launcher), launcherOptions)
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(launcher), launcherOptions)
hl.bind(mainMod .. " + A", hl.dsp.exec_cmd("swaync-client -t -sw"), {
    dont_inhibit = true,
    description = "Open notification and control center",
})
hl.bind(mainMod .. " + SHIFT + A", hl.dsp.exec_cmd("swaync-client -d -sw"), {
    dont_inhibit = true,
    description = "Toggle do not disturb",
})

local function cycleWindow(nextWindow)
    hl.dispatch(hl.dsp.window.cycle_next({ next = nextWindow }))
    hl.dispatch(hl.dsp.window.bring_to_top())
end

hl.bind("ALT + Tab", function()
    cycleWindow(true)
end, { description = "Focus next window on this workspace" })
hl.bind("ALT + SHIFT + Tab", function()
    cycleWindow(false)
end, { description = "Focus previous window on this workspace" })

hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd(terminal), { description = "Open Ghostty" })
hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal), { description = "Open Ghostty" })
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(editor), { description = "Open Zed" })
hl.bind(mainMod .. " + B", hl.dsp.exec_cmd(browser), { description = "Open Chrome" })
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager), { description = "Open Thunar" })
hl.bind(mainMod .. " + C", hl.dsp.window.close(), { description = "Close active window" })
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }), {
    description = "Toggle true fullscreen",
})
hl.bind(mainMod .. " + N", hl.dsp.exec_cmd("cyberdock-minimize"), { description = "Minimize active window" })
hl.bind(mainMod .. " + SHIFT + N", hl.dsp.exec_cmd("cyberdock-recover"), { description = "Recover minimized windows" })
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }), { description = "Toggle floating" })
hl.bind(mainMod .. " + P", hl.dsp.exec_cmd("desktop-display-mode menu"), {
    description = "Choose projection mode",
})
hl.bind(mainMod .. " + SHIFT + P", hl.dsp.window.pseudo(), { description = "Toggle pseudotiling" })
hl.bind(mainMod .. " + T", hl.dsp.layout("togglesplit"), { description = "Toggle dwindle split" })
hl.bind(mainMod .. " + CTRL + L", hl.dsp.exec_cmd("desktop-power lock"), { description = "Lock session" })
hl.bind(mainMod .. " + CTRL + K", hl.dsp.exec_cmd("kakaotalk-focus-repair"), {
    description = "Repair KakaoTalk input focus",
})
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("desktop-power menu"), { description = "Open power and session menu" })
hl.bind(mainMod .. " + SHIFT + D",
    hl.dsp.exec_cmd("qs -p ~/.config/quickshell/cyberdock ipc call -- dock keyboard"),
    { description = "Focus Cyberdock with the keyboard" })
hl.bind("ALT + SPACE", hl.dsp.exec_cmd("enoshima-window-menu"), { description = "Open the system window menu" })
hl.bind(mainMod .. " + Z", hl.dsp.exec_cmd("enoshima-snap-controller chooser"), {
    description = "Choose a Windows-style snap layout",
})

local directions = {
    H = { name = "left", x = -40, y = 0 },
    J = { name = "down", x = 0, y = 40 },
    K = { name = "up", x = 0, y = -40 },
    L = { name = "right", x = 40, y = 0 },
}

for key, direction in pairs(directions) do
    hl.bind(mainMod .. " + " .. key,
        hl.dsp.focus({ direction = direction.name }))
    hl.bind(mainMod .. " + SHIFT + " .. key,
        hl.dsp.window.move({ direction = direction.name }))
    hl.bind(mainMod .. " + ALT + " .. key,
        hl.dsp.window.resize({ x = direction.x, y = direction.y, relative = true }),
        { repeating = true })
end

local arrowDirections = {
    left = { direction = "left", snap = "left-half" },
    down = { direction = "down", action = "desktop-window-action minimize --active --origin keyboard" },
    up = { direction = "up", snap = "maximize" },
    right = { direction = "right", snap = "right-half" },
}

for key, action in pairs(arrowDirections) do
    local command = action.action or ("enoshima-snap-controller place " .. action.snap)
    hl.bind(mainMod .. " + " .. key, hl.dsp.exec_cmd(command), {
        description = "Place the active window like Windows Snap",
    })
    hl.bind(mainMod .. " + SHIFT + " .. key,
        hl.dsp.window.move({ direction = action.direction }))
end

hl.bind(mainMod .. " + CTRL + left",
    hl.dsp.focus({ workspace = "e-1" }),
    { description = "Focus previous workspace" })
hl.bind(mainMod .. " + CTRL + right",
    hl.dsp.focus({ workspace = "e+1" }),
    { description = "Focus next workspace" })

for id = 1, 5 do
    local key = id
    hl.bind(mainMod .. " + " .. key,
        hl.dsp.focus({ workspace = id }))
    hl.bind(mainMod .. " + SHIFT + " .. key,
        hl.dsp.window.move({ workspace = id }))
end

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), {
    mouse = true,
    dont_inhibit = true,
    description = "Move window with pointer",
})
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), {
    mouse = true,
    dont_inhibit = true,
    description = "Resize window with pointer",
})

hl.bind("XF86AudioRaiseVolume",
    hl.dsp.exec_cmd("audio-output-control raise"),
    { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",
    hl.dsp.exec_cmd("audio-output-control lower"),
    { locked = true, repeating = true })
hl.bind("XF86AudioMute",
    hl.dsp.exec_cmd("audio-output-control toggle-mute"),
    { locked = true })
hl.bind("XF86AudioMicMute",
    hl.dsp.exec_cmd("desktop-microphone-control toggle-mute"),
    { locked = true })
hl.bind("XF86MonBrightnessUp",
    hl.dsp.exec_cmd("desktop-brightness-control raise"),
    { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown",
    hl.dsp.exec_cmd("desktop-brightness-control lower"),
    { locked = true, repeating = true })
hl.bind("XF86KbdBrightnessUp",
    hl.dsp.exec_cmd("desktop-keyboard-backlight-control raise"),
    { locked = true, repeating = true })
hl.bind("XF86KbdBrightnessDown",
    hl.dsp.exec_cmd("desktop-keyboard-backlight-control lower"),
    { locked = true, repeating = true })
hl.bind("XF86WLAN", hl.dsp.exec_cmd("desktop-airplane-control toggle"), { locked = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"), { locked = true })

-- Route application windows without changing the currently focused workspace.
local applicationRoutes = {
    {
        name = "route-dev",
        class = [[(?i)^(dev\.zed\.zed|zed|com\.mitchellh\.ghostty|ghostty)$]],
        workspace = "1 silent",
    },
    {
        name = "route-web",
        class = [[(?i)^(google-chrome(-stable)?|com\.google\.chrome)$]],
        workspace = "2 silent",
    },
    {
        name = "route-document",
        class = [[(?i)^(discord|slack|com\.slack\.slack|thunderbird|org\.mozilla\.thunderbird|obsidian|md\.obsidian|.*notion.*|onlyoffice.*|desktopeditors|rhwp(-desktop)?|.*rhwp.*)$]],
        workspace = "3 silent",
    },
    {
        name = "route-remote",
        class = [[(?i)^(parsec|parsecd|com\.parsecgaming\.parsec)$]],
        workspace = "4 silent",
    },
    {
        name = "route-misc",
        class = [[(?i)^(thunar|org\.gnome\.nautilus|org\.kde\.dolphin|org\.gnome\.fileroller)$]],
        workspace = "5 silent",
    },
}

for _, route in ipairs(applicationRoutes) do
    hl.window_rule({
        name = route.name,
        match = { class = route.class },
        workspace = route.workspace,
    })
end

-- Route only the verified KakaoTalk main window. Notification and conversation
-- popups stay on the focused monitor instead of being swept to DOCUMENT.
hl.window_rule({
    name = "route-kakaotalk-main",
    match = {
        class = [[(?i)^kakaotalk\.exe$]],
        title = "^카카오톡$",
    },
    workspace = "3 silent",
})

-- Keep the bridge's own X11 implementation surface out of the desktop. Wine's
-- explorer.exe surfaces are classified by exact address and geometry at
-- runtime; a broad empty-title rule would also hide real Kakao notifications.
hl.window_rule({
    name = "hide-xembed-tray-host",
    match = { class = [[(?i)^xembed-sni-proxy$]] },
    workspace = "special:tray silent",
    no_focus = true,
})

hl.window_rule({
    name = "float-system-tools",
    match = {
        class = [[(?i)^(pavucontrol|nm-connection-editor|blueman-manager|org\.fcitx\..*)$]],
    },
    float = true,
    center = true,
    size = { 900, 640 },
})

-- The packaged taskbar client requests maximize and may otherwise be created
-- on whichever numbered workspace happened to be active at login. Keep its UI
-- as a normal closable utility on MISC while leaving the tray service running.
hl.window_rule({
    name = "cloudflare-one-client",
    match = {
        class = [[(?i)^warp-taskbar$]],
    },
    float = true,
    center = true,
    size = { 960, 700 },
    fullscreen_state = "0 0",
    workspace = "5 silent",
    suppress_event = "fullscreen maximize fullscreenoutput",
})

-- Hidden workspaces are normally not rendered. Codex depends on its renderer
-- event loop to deliver completion notifications, so keep it ticking at the
-- deliberately low background frame rate configured above.
hl.window_rule({
    name = "keep-codex-background-active",
    match = {
        class = [[(?i)^(chatgpt|com\.openai\.chatgpt)$]],
    },
    render_unfocused = true,
})

hl.window_rule({
    name = "fix-xwayland-drag-icons",
    match = {
        class = "^$",
        title = "^$",
        xwayland = true,
        float = true,
        fullscreen = false,
        pin = false,
    },
    no_focus = true,
})

hl.layer_rule({
    name = "cyberlauncher-style",
    match = { namespace = "^cyberlauncher$" },
    blur = true,
    ignore_alpha = 0.12,
})

hl.layer_rule({
    name = "cyberosd-style",
    match = { namespace = "^cyberosd$" },
    blur = true,
    ignore_alpha = 0.12,
})

hl.layer_rule({
    name = "cyberdisplay-style",
    match = { namespace = "^cyberdisplay$" },
    blur = true,
    dim_around = true,
    ignore_alpha = 0.12,
})

hl.layer_rule({
    name = "cyberpower-style",
    match = { namespace = "^cyberpower$" },
    blur = true,
    dim_around = true,
    ignore_alpha = 0.12,
})

hl.layer_rule({
    name = "swaync-control-center-style",
    match = { namespace = "^swaync-control-center$" },
    blur = true,
    dim_around = true,
    ignore_alpha = 0.15,
})

hl.layer_rule({
    name = "swaync-notification-style",
    match = { namespace = "^swaync-notification-window$" },
    blur = true,
    ignore_alpha = 0.15,
})
