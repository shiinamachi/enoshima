-- ThinkPad X1 Carbon Gen 13 desktop configuration for Hyprland 0.55+.

local internalMonitor = "eDP-1"
local externalMonitor = "desc:Dell Inc. DELL U2725QE"

local terminal = "ghostty"
-- Arch's official `zed` package installs the CLI as `zeditor`.
local editor = "zeditor"
local browser = "google-chrome-stable"
local fileManager = "thunar"
local launcher = "hyprlauncher --toggle"

-- Monitor coordinates are logical pixels after applying the 1.5 scale.
-- The Dell is physically to the upper-right of the laptop panel.
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
    output = externalMonitor,
    mode = "3840x2160@120",
    position = "1920x0",
    scale = 1.5,
    bitdepth = 8,
    cm = "srgb",
    vrr = 0,
})

-- Safe fallback for projectors and monitors other than the known Dell.
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto-right",
    scale = 1,
    bitdepth = 8,
    cm = "srgb",
    vrr = 0,
})

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

hl.config({
    general = {
        gaps_in = 6,
        gaps_out = 12,
        border_size = 2,
        extend_border_grab_area = 15,
        resize_on_border = true,
        allow_tearing = false,
        layout = "dwindle",
        col = {
            active_border = {
                colors = { "rgba(33d6ffff)", "rgba(ff3cc7ff)" },
                angle = 45,
            },
            inactive_border = "rgba(8b5cff88)",
        },
    },

    decoration = {
        rounding = 10,
        rounding_power = 2,
        active_opacity = 1.0,
        inactive_opacity = 0.98,
        shadow = {
            enabled = true,
            range = 8,
            render_power = 3,
            color = "rgba(070b2add)",
        },
        blur = {
            enabled = true,
            size = 6,
            passes = 2,
            vibrancy = 0.15,
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

hl.animation({ leaf = "global", enabled = true, speed = 8, bezier = "easeOutQuint" })
hl.animation({ leaf = "border", enabled = true, speed = 6, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 6, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 6, bezier = "easeOutQuint", style = "popin 92%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 5, bezier = "quick", style = "popin 92%" })
hl.animation({ leaf = "fade", enabled = true, speed = 5, bezier = "quick" })
hl.animation({ leaf = "layers", enabled = true, speed = 5, bezier = "easeOutQuint" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 5, bezier = "easeInOutCubic", style = "slide" })

hl.gesture({
    fingers = 3,
    direction = "horizontal",
    action = "workspace",
})

-- Persistent numbered workspaces keep keybindings and Waybar stable.
for id = 1, 10 do
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

hl.on("hyprland.start", routeWorkspaces)
hl.on("config.reloaded", routeWorkspaces)
hl.on("monitor.added", routeWorkspaces)
hl.on("monitor.layout_changed", routeWorkspaces)
hl.on("monitor.removed", routeWorkspaces)

local mainMod = "SUPER"
local launcherOptions = {
    dont_inhibit = true,
    description = "Open application launcher",
}

hl.bind(mainMod .. " + SPACE", hl.dsp.exec_cmd(launcher), launcherOptions)
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(launcher), launcherOptions)

hl.bind(mainMod .. " + RETURN", hl.dsp.exec_cmd(terminal), { description = "Open Ghostty" })
hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal), { description = "Open Ghostty" })
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(editor), { description = "Open Zed" })
hl.bind(mainMod .. " + Z", hl.dsp.exec_cmd(editor), { description = "Open Zed" })
hl.bind(mainMod .. " + B", hl.dsp.exec_cmd(browser), { description = "Open Chrome" })
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager), { description = "Open Thunar" })
hl.bind(mainMod .. " + C", hl.dsp.window.close(), { description = "Close active window" })
hl.bind(mainMod .. " + F", hl.dsp.exec_cmd("hyprctl dispatch fullscreen 0"), { description = "Toggle true fullscreen" })
hl.bind(mainMod .. " + N", hl.dsp.exec_cmd("cyberdock-minimize"), { description = "Minimize active window" })
hl.bind(mainMod .. " + SHIFT + N", hl.dsp.exec_cmd("cyberdock-recover"), { description = "Recover minimized windows" })
hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }), { description = "Toggle floating" })
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo(), { description = "Toggle pseudotiling" })
hl.bind(mainMod .. " + T", hl.dsp.layout("togglesplit"), { description = "Toggle dwindle split" })
hl.bind(mainMod .. " + CTRL + L", hl.dsp.exec_cmd("loginctl lock-session"), { description = "Lock session" })
hl.bind(mainMod .. " + M", hl.dsp.exec_cmd("hyprshutdown"), { description = "Open session menu" })

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
    left = "left",
    down = "down",
    up = "up",
    right = "right",
}

for key, direction in pairs(arrowDirections) do
    hl.bind(mainMod .. " + " .. key,
        hl.dsp.focus({ direction = direction }))
    hl.bind(mainMod .. " + SHIFT + " .. key,
        hl.dsp.window.move({ direction = direction }))
end

for id = 1, 10 do
    local key = id % 10
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
})
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), {
    mouse = true,
    dont_inhibit = true,
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
    hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),
    { locked = true })
hl.bind("XF86MonBrightnessUp",
    hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),
    { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown",
    hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),
    { locked = true, repeating = true })
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
        class = [[(?i)^(discord|slack|com\.slack\.slack|thunderbird|org\.mozilla\.thunderbird|obsidian|md\.obsidian|.*notion.*|kakaotalk(\.exe)?|kakao.*|onlyoffice.*|desktopeditors|rhwp(-desktop)?|.*rhwp.*)$]],
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

hl.window_rule({
    name = "float-system-tools",
    match = {
        class = [[(?i)^(pavucontrol|nm-connection-editor|blueman-manager|org\.fcitx\..*)$]],
    },
    float = true,
    center = true,
    size = { 900, 640 },
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
    name = "hyprlauncher-style",
    match = { namespace = "^hyprlauncher$" },
    blur = true,
    dim_around = true,
    ignore_alpha = 0.2,
    no_screen_share = true,
})

hl.layer_rule({
    name = "waybar-blur",
    match = { namespace = "^waybar$" },
    blur = true,
    ignore_alpha = 0.2,
})

hl.layer_rule({
    name = "swaync-blur",
    match = { namespace = [[^(swaync-control-center|swaync-notification-window)$]] },
    blur = true,
    ignore_alpha = 0.15,
})
