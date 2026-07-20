#define WLR_USE_UNSTABLE

#include <unistd.h>
#include <fnmatch.h>

#include <any>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/shared/parserUtils/ParserUtils.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/desktop/rule/windowRule/WindowRuleEffectContainer.hpp>
#include <hyprland/src/config/lua/bindings/LuaBindingsInternal.hpp>
#include <hyprland/src/config/lua/types/LuaConfigColor.hpp>

#include <hyprutils/string/VarList.hpp>

#include <algorithm>
#include <cctype>
#include <sstream>
#include <stdexcept>

#include "barDeco.hpp"
#include "globals.hpp"

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

// Do NOT change this function.
APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

static std::string trim(std::string value) {
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), [](unsigned char c) { return !std::isspace(c); }));
    value.erase(std::find_if(value.rbegin(), value.rend(), [](unsigned char c) { return !std::isspace(c); }).base(), value.end());
    return value;
}

static bool classMatchesAllowlist(const std::string& className) {
    if (className.empty())
        return false;

    std::stringstream patterns(g_pGlobalState->config.allowlist->value());
    std::string       pattern;
    while (std::getline(patterns, pattern, ',')) {
        pattern = trim(pattern);
        if (!pattern.empty() && fnmatch(pattern.c_str(), className.c_str(), FNM_CASEFOLD) == 0)
            return true;
    }
    return false;
}

static bool windowIsAllowlisted(PHLWINDOW window) {
    return window && (classMatchesAllowlist(window->m_class) || classMatchesAllowlist(window->m_initialClass));
}

static auto findBar(PHLWINDOW window) {
    return std::find_if(g_pGlobalState->bars.begin(), g_pGlobalState->bars.end(), [window](const auto& bar) {
        return bar && bar->getOwner() == window;
    });
}

static bool wantsDecoration(PHLWINDOW window) {
    return window && g_pGlobalState->config.enabled->value() && windowIsAllowlisted(window) && !window->m_X11DoesntWantBorders &&
        window->m_ruleApplicator->decorate().valueOrDefault();
}

static void syncDecoration(PHLWINDOW window) {
    if (!window)
        return;

    const auto BARIT    = findBar(window);
    const bool EXISTING = BARIT != g_pGlobalState->bars.end();
    const bool WANTED   = wantsDecoration(window);

    if (!WANTED && EXISTING) {
        // removeWindowDecoration owns destruction. CHyprBar's destructor also
        // removes its weak reference from g_pGlobalState->bars, so do not erase
        // the iterator a second time here.
        HyprlandAPI::removeWindowDecoration(PHANDLE, BARIT->get());
        window->updateWindowDecos();
        return;
    }

    if (!WANTED || EXISTING)
        return;

    auto bar = makeUnique<CHyprBar>(window);
    g_pGlobalState->bars.emplace_back(bar);
    bar->m_self = bar;
    HyprlandAPI::addWindowDecoration(PHANDLE, window, std::move(bar));
}

static void onNewWindow(PHLWINDOW window) {
    // Ownership is positive-allowlist only. A newly installed CSD client cannot
    // receive a duplicate compositor title bar by default.
    syncDecoration(window);
}

static void onPreConfigReload() {
    g_pGlobalState->buttons.clear();
}

static void onConfigReloaded() {
    // Reconcile in both directions. A class change, an allowlist removal, a
    // border opt-out, or disabling the plugin must remove stale compositor
    // chrome just as reliably as an allowlist addition attaches it.
    for (auto& window : g_pCompositor->m_windows) {
        if (!window->m_isMapped)
            continue;
        syncDecoration(window);
    }

    for (auto& b : g_pGlobalState->bars) {
        if (!b)
            continue;

        b->onConfigReloaded();
    }
}

static void onUpdateWindowRules(PHLWINDOW window) {
    syncDecoration(window);
    const auto BARIT = findBar(window);
    if (BARIT == g_pGlobalState->bars.end())
        return;

    (*BARIT)->updateRules();
    window->updateWindowDecos();
}

Hyprlang::CParseResult onNewButton([[maybe_unused]] const char* K, const char* V) {
    std::string                 v = V;
    Hyprutils::String::CVarList vars(v);

    Hyprlang::CParseResult      result;

    // hyprbars-button = bgcolor, size, icon, action, fgcolor

    if (vars[0].empty() || vars[1].empty()) {
        result.setError("bgcolor and size cannot be empty");
        return result;
    }

    float size = 10;
    try {
        size = std::stof(vars[1]);
    } catch (std::exception& e) {
        result.setError("failed to parse size");
        return result;
    }

    bool userfg  = false;
    auto fgcolor = Config::ParserUtils::parseColor("rgb(ffffff)");
    auto bgcolor = Config::ParserUtils::parseColor(vars[0]);

    if (!bgcolor) {
        result.setError("invalid bgcolor");
        return result;
    }

    if (vars.size() == 5) {
        userfg  = true;
        fgcolor = Config::ParserUtils::parseColor(vars[4]);
    }

    if (!fgcolor) {
        result.setError("invalid fgcolor");
        return result;
    }

    g_pGlobalState->buttons.push_back(SHyprButton{vars[3], userfg, *fgcolor, *bgcolor, size, vars[2], nullptr});

    for (auto& b : g_pGlobalState->bars) {
        b->m_bButtonsDirty = true;
    }

    return result;
}

int newLuaButton(lua_State* L) {
    if (!lua_istable(L, 1))
        return Config::Lua::Bindings::Internal::configError(L, "add_button: expected a table { bg_color, fg_color, size, icon, action }");

    SHyprButton button;

    {
        Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

        lua_getfield(L, 1, "bg_color");

        Config::Lua::CLuaConfigColor parser(0);
        auto                         err = parser.parse(L);
        if (err.errorCode != Config::Lua::PARSE_ERROR_OK)
            return Config::Lua::Bindings::Internal::configError(L, "add_button: failed to parse bg_color");

        button.bgcol = parser.parsed();
    }

    {
        Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

        lua_getfield(L, 1, "fg_color");

        Config::Lua::CLuaConfigColor parser(0);
        auto                         err = parser.parse(L);
        if (err.errorCode != Config::Lua::PARSE_ERROR_OK)
            return Config::Lua::Bindings::Internal::configError(L, "add_button: failed to parse fg_color");

        button.fgcol = parser.parsed();
    }

    {
        Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

        lua_getfield(L, 1, "size");

        if (!lua_isnumber(L, -1))
            return Config::Lua::Bindings::Internal::configError(L, "add_button: size must be an integer");

        button.size = lua_tointeger(L, -1);
    }

    {
        Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

        lua_getfield(L, 1, "icon");

        if (!lua_isstring(L, -1))
            return Config::Lua::Bindings::Internal::configError(L, "add_button: icon must be a string");

        button.icon = lua_tostring(L, -1);
    }

    {
        Hyprutils::Utils::CScopeGuard x([L] { lua_pop(L, 1); });

        lua_getfield(L, 1, "action");

        if (!lua_isstring(L, -1))
            return Config::Lua::Bindings::Internal::configError(L, "add_button: action must be a string");

        button.cmd = lua_tostring(L, -1);
    }

    g_pGlobalState->buttons.push_back(std::move(button));

    for (auto& b : g_pGlobalState->bars) {
        b->m_bButtonsDirty = true;
    }

    return 0;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();

    if (HASH != CLIENT_HASH) {
        HyprlandAPI::addNotification(PHANDLE, "[enoshima-decoration] ABI mismatch: rebuild the managed plugin for this Hyprland version",
                                     CHyprColor{1.0, 0.2, 0.2, 1.0}, 5000);
        throw std::runtime_error("[enoshima-decoration] version mismatch");
    }

    g_pGlobalState                    = makeUnique<SGlobalState>();
    g_pGlobalState->nobarRuleIdx      = Desktop::Rule::windowEffects()->registerEffect("enoshima-decoration:no_bar");
    g_pGlobalState->barColorRuleIdx   = Desktop::Rule::windowEffects()->registerEffect("enoshima-decoration:bar_color");
    g_pGlobalState->titleColorRuleIdx = Desktop::Rule::windowEffects()->registerEffect("enoshima-decoration:title_color");

    static auto P  = Event::bus()->m_events.window.open.listen([&](PHLWINDOW w) { onNewWindow(w); });
    static auto P3 = Event::bus()->m_events.window.updateRules.listen([&](PHLWINDOW w) { onUpdateWindowRules(w); });

    g_pGlobalState->config.barColor            = makeShared<Config::Values::CColorValue>("plugin:enoshima_decoration:bar_color", "Change the bar color", 0x88333333);
    g_pGlobalState->config.textColor           = makeShared<Config::Values::CColorValue>("plugin:enoshima_decoration:col.text", "Change the text color", 0xffffffff);
    g_pGlobalState->config.inactiveButtonColor = makeShared<Config::Values::CColorValue>(
        "plugin:enoshima_decoration:inactive_button_color", "Change the inactive button's color. 0x00000000 means unset", 0x00000000);
    g_pGlobalState->config.barHeight       = makeShared<Config::Values::CIntValue>("plugin:enoshima_decoration:bar_height", "Change the bar's height", 15);
    g_pGlobalState->config.barHitHeight    = makeShared<Config::Values::CIntValue>(
        "plugin:enoshima_decoration:bar_hit_height", "Reserved input height; may exceed the rendered title bar", 44);
    g_pGlobalState->config.barTextSize     = makeShared<Config::Values::CIntValue>("plugin:enoshima_decoration:bar_text_size", "Change the bar's text size", 10);
    g_pGlobalState->config.barTitleEnabled = makeShared<Config::Values::CBoolValue>("plugin:enoshima_decoration:bar_title_enabled", "Whether to enable titles in the bar", true);
    g_pGlobalState->config.barBlur         = makeShared<Config::Values::CBoolValue>("plugin:enoshima_decoration:bar_blur", "Whether to enable blur of the bar", false);
    g_pGlobalState->config.barTextFont     = makeShared<Config::Values::CStringValue>("plugin:enoshima_decoration:bar_text_font", "Bar's text font", "Sans");
    g_pGlobalState->config.barTextAlign    = makeShared<Config::Values::CStringValue>("plugin:enoshima_decoration:bar_text_align", "Bar's text alignment", "center");
    g_pGlobalState->config.barPartOfWindow =
        makeShared<Config::Values::CBoolValue>("plugin:enoshima_decoration:bar_part_of_window", "Whether the bar is a part of the window (reserves space)", true);
    g_pGlobalState->config.barPrecedenceOverBorder =
        makeShared<Config::Values::CBoolValue>("plugin:enoshima_decoration:bar_precedence_over_border", "Whether the bar is before, or after the border", false);
    g_pGlobalState->config.barButtonsAlignment = makeShared<Config::Values::CStringValue>("plugin:enoshima_decoration:bar_buttons_alignment", "Alignment of the bar buttons", "right");
    g_pGlobalState->config.barPadding          = makeShared<Config::Values::CIntValue>("plugin:enoshima_decoration:bar_padding", "Padding of the bar", 7);
    g_pGlobalState->config.barButtonPadding    = makeShared<Config::Values::CIntValue>("plugin:enoshima_decoration:bar_button_padding", "Padding of the bar buttons", 5);
    g_pGlobalState->config.enabled             = makeShared<Config::Values::CBoolValue>("plugin:enoshima_decoration:enabled", "Whether bars are enabled", true);
    g_pGlobalState->config.iconOnHover         = makeShared<Config::Values::CBoolValue>("plugin:enoshima_decoration:icon_on_hover", "Whether to use an icon on hover of the buttons", false);
    g_pGlobalState->config.onDoubleClick       = makeShared<Config::Values::CStringValue>("plugin:enoshima_decoration:on_double_click", "Action to execute on double click of the bar", "");
    g_pGlobalState->config.allowlist = makeShared<Config::Values::CStringValue>(
        "plugin:enoshima_decoration:allowlist", "Comma-separated positive class globs that receive Enoshima system chrome", "");

    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barColor);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.textColor);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.inactiveButtonColor);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barHeight);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barHitHeight);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barTextSize);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barTitleEnabled);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barBlur);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barTextFont);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barTextAlign);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barPartOfWindow);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barPrecedenceOverBorder);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barButtonsAlignment);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barPadding);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.barButtonPadding);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.enabled);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.iconOnHover);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.onDoubleClick);
    HyprlandAPI::addConfigValueV2(PHANDLE, g_pGlobalState->config.allowlist);

    if (Config::mgr()->type() == Config::CONFIG_LEGACY) {
// Hyprland 0.55 deprecates the legacy keyword API without exposing a V2
// replacement. Keep this warning scoped to the legacy-only compatibility call.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        const bool keywordAdded =
            HyprlandAPI::addConfigKeyword(PHANDLE, "plugin:enoshima_decoration:button", onNewButton, Hyprlang::SHandlerOptions{});
#pragma GCC diagnostic pop
        if (!keywordAdded)
            throw std::runtime_error("[enoshima-decoration] failed to register the legacy button keyword");
    } else {
        HyprlandAPI::addLuaFunction(PHANDLE, "enoshima_decoration", "add_button", ::newLuaButton);
    }
    static auto P4 = Event::bus()->m_events.config.preReload.listen([&] { onPreConfigReload(); });
    static auto P5 = Event::bus()->m_events.config.reloaded.listen([&] { onConfigReloaded(); });

    // add deco to existing windows
    for (auto& w : g_pCompositor->m_windows) {
        if (w->isHidden() || !w->m_isMapped)
            continue;

        onNewWindow(w);
    }

    HyprlandAPI::reloadConfig();

    return {"enoshima-decoration", "Positive-allowlist system title bars for Enoshima.", "Enoshima contributors; based on hyprbars by Vaxry", "1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    for (auto& m : g_pCompositor->m_monitors)
        m->m_scheduledRecalc = true;

    g_pHyprRenderer->m_renderPass.removeAllOfType("CBarPassElement");

    Desktop::Rule::windowEffects()->unregisterEffect(g_pGlobalState->barColorRuleIdx);
    Desktop::Rule::windowEffects()->unregisterEffect(g_pGlobalState->titleColorRuleIdx);
    Desktop::Rule::windowEffects()->unregisterEffect(g_pGlobalState->nobarRuleIdx);
}
