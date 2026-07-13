-- Korean input: keep native Wayland input paths where possible.
hl.env("XMODIFIERS", "@im=fcitx")
hl.env("QT_IM_MODULES", "wayland;fcitx;ibus")

hl.config({
  general = {
    gaps_in = 5,
    gaps_out = 12,
    border_size = 2,

    col = {
      active_border = {
        colors = {
          "rgba(89b4faff)"
          "rgba(cba6f7ff)"
        },
        angle = 45,
      },
      inactive_border = "rgba(585b70aa)",
    },

    layout = "dwindle",
    allow_tearing = false,
  },

  decoration = {
    rounding = 12,
    rounding_power = 2,
    
    shadow = {
      enabled = true,
      range = 8,

    render_power = 3,
    color = 0x66000000,
  },

  blur = {
    enabled = true,
    size = 5,
    passes = 2,
    vibrancy = 0.18,
  },
},

misc = {
  force_default_wallpaper = 0,
  disable_hyprland_logo = true,
},

input = {
  kb_layout = "us",
  repeat_rate = 35,
  repeat_delay = 250,

  touchpad = {
    natural_scroll = true,
    disable_while_typing = true,
  },
},
})

-- Komorebi-like keyboard additions.
-- The official example already includes:
-- SUPER+Q terminal, SUPER+C close, SUPER+E file manager,
-- SUPER+R launcher, SUPER+1..0 workspaces,
-- SUPER+SHIFT+1..0 move-to-workspace.
hl.bind("SUPER + Return", hl.dsp.exec_cmd("uwsm app -- kitty"))
hl.bind("SUPER + D", hl.dsp.exec_cmd("uwsm app -- hyprlauncher"))
hl.bind("SUPER + SHIFT + Q", hl.dsp.windows.close())
hl.bind("SUPER + L", hl.dsp.exec_cmd("hyprlock"))

hl.on("hyprland.start", function()
  hl.exec_cmd("uwsm app -- waybar")
  hl.exec_cmd("uwsm app -- swaync")
  hl.exec_cmd("uwsm app -- nm-applet --indicator")
  hl.exec_cmd("uwsm app -- blueman-applet")
  hl.exec_cmd("uwsm app -- udiskie --tray")
end)
