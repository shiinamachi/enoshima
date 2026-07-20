#include "barDeco.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/helpers/MiscFunctions.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/shared/animation/AnimationTree.hpp>
#include <hyprland/src/config/shared/parserUtils/ParserUtils.hpp>
#include <hyprland/src/config/supplementary/executor/Executor.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/managers/animation/AnimationManager.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/render/OpenGL.hpp>

#include <librsvg/rsvg.h>

#include "globals.hpp"
#include "BarPassElement.hpp"

#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <format>
#include <linux/input-event-codes.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

using namespace Render::GL;

static CHyprColor configColor(Config::INTEGER color) {
    return CHyprColor{static_cast<uint64_t>(color)};
}

static SP<Render::ITexture> svgTexture(const std::string& path, int pixels, std::optional<CHyprColor> tint = std::nullopt) {
    if (pixels < 1 || !std::filesystem::is_regular_file(path))
        return nullptr;

    GError* error  = nullptr;
    auto*   handle = rsvg_handle_new_from_file(path.c_str(), &error);
    if (!handle) {
        if (error)
            g_error_free(error);
        return nullptr;
    }

    auto* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pixels, pixels);
    auto* cairo   = cairo_create(surface);
    const RsvgRectangle viewport = {.x = 0, .y = 0, .width = static_cast<double>(pixels), .height = static_cast<double>(pixels)};
    const bool rendered           = rsvg_handle_render_document(handle, cairo, &viewport, &error);
    cairo_destroy(cairo);
    g_object_unref(handle);
    if (!rendered) {
        if (error)
            g_error_free(error);
        cairo_surface_destroy(surface);
        return nullptr;
    }

    if (tint) {
        cairo_surface_flush(surface);
        auto*       data   = reinterpret_cast<uint32_t*>(cairo_image_surface_get_data(surface));
        const auto  stride = cairo_image_surface_get_stride(surface) / static_cast<int>(sizeof(uint32_t));
        const auto& color  = *tint;
        for (int y = 0; y < pixels; ++y) {
            for (int x = 0; x < pixels; ++x) {
                const auto alpha = static_cast<uint8_t>(data[y * stride + x] >> 24U);
                const auto red   = static_cast<uint8_t>(std::clamp(color.r * alpha, 0.0, 255.0));
                const auto green = static_cast<uint8_t>(std::clamp(color.g * alpha, 0.0, 255.0));
                const auto blue  = static_cast<uint8_t>(std::clamp(color.b * alpha, 0.0, 255.0));
                data[y * stride + x] = static_cast<uint32_t>(alpha) << 24U | static_cast<uint32_t>(red) << 16U |
                    static_cast<uint32_t>(green) << 8U | static_cast<uint32_t>(blue);
            }
        }
        cairo_surface_mark_dirty(surface);
    }

    auto texture = g_pHyprRenderer->createTexture(surface);
    cairo_surface_destroy(surface);
    return texture;
}

static std::string iconPathForClass(std::string className) {
    std::ranges::transform(className, className.begin(), [](unsigned char c) { return std::tolower(c); });
    if (className.find("zathura") != std::string::npos)
        return "/usr/share/icons/Papirus/16x16/apps/org.pwmt.zathura.svg";
    if (className == "mpv" || className.find("mpv") != std::string::npos)
        return "/usr/share/icons/Papirus/16x16/apps/mpv.svg";
    return "/usr/share/icons/Papirus/16x16/mimetypes/image-x-generic.svg";
}

CHyprBar::CHyprBar(PHLWINDOW pWindow) : IHyprWindowDecoration(pWindow) {
    m_pWindow = pWindow;

    const auto PMONITOR         = pWindow->m_monitor.lock();
    PMONITOR->m_scheduledRecalc = true;

    // button events
    m_pMouseButtonCallback = Event::bus()->m_events.input.mouse.button.listen([&](IPointer::SButtonEvent e, Event::SCallbackInfo& info) { onMouseButton(info, e); });
    m_pTouchDownCallback   = Event::bus()->m_events.input.touch.down.listen([&](ITouch::SDownEvent e, Event::SCallbackInfo& info) { onTouchDown(info, e); });
    m_pTouchUpCallback     = Event::bus()->m_events.input.touch.up.listen([&](ITouch::SUpEvent e, Event::SCallbackInfo& info) { onTouchUp(info, e); });

    // move events
    m_pTouchMoveCallback = Event::bus()->m_events.input.touch.motion.listen([&](ITouch::SMotionEvent e, Event::SCallbackInfo& info) { onTouchMove(info, e); });
    m_pMouseMoveCallback = Event::bus()->m_events.input.mouse.move.listen([&](Vector2D c, Event::SCallbackInfo&) { onMouseMove(c); });
    m_pKeyboardKeyCallback = Event::bus()->m_events.input.keyboard.key.listen(
        [&](IKeyboard::SKeyEvent e, Event::SCallbackInfo& info) { onKeyboardKey(info, e); });

    g_pAnimationManager->createAnimation(configColor(g_pGlobalState->config.barColor->value()), m_cRealBarColor, Config::animationTree()->getAnimationPropertyConfig("border"),
                                         pWindow, AVARDAMAGE_NONE);
    m_cRealBarColor->setUpdateCallback([&](auto) { damageEntire(); });
}

CHyprBar::~CHyprBar() {
    std::erase(g_pGlobalState->bars, m_self);
}

SDecorationPositioningInfo CHyprBar::getPositioningInfo() {
    const auto                 HEIGHT     = g_pGlobalState->config.barHitHeight->value();
    const auto                 ENABLED    = g_pGlobalState->config.enabled->value();
    const auto                 PRECEDENCE = g_pGlobalState->config.barPrecedenceOverBorder->value();

    SDecorationPositioningInfo info;
    info.policy         = m_hidden ? DECORATION_POSITION_ABSOLUTE : DECORATION_POSITION_STICKY;
    info.edges          = DECORATION_EDGE_TOP;
    info.priority       = PRECEDENCE ? 10005 : 5000;
    info.reserved       = true;
    info.desiredExtents = {{0, m_hidden || !ENABLED ? 0 : static_cast<int>(HEIGHT)}, {0, 0}};
    return info;
}

void CHyprBar::onPositioningReply(const SDecorationPositioningReply& reply) {
    if (reply.assignedGeometry.size() != m_bAssignedBox.size())
        m_bWindowSizeChanged = true;

    m_bAssignedBox = reply.assignedGeometry;
}

std::string CHyprBar::getDisplayName() {
    return "EnoshimaDecoration";
}

bool CHyprBar::inputIsValid() {
    if (!g_pGlobalState->config.enabled->value())
        return false;

    if (!m_pWindow->m_workspace || !m_pWindow->m_workspace->isVisible() || !g_pInputManager->m_exclusiveLSes.empty() ||
        (g_pSeatManager->m_seatGrab && !g_pSeatManager->m_seatGrab->accepts(m_pWindow->wlSurface()->resource())))
        return false;

    const auto WINDOWATCURSOR = g_pCompositor->vectorToWindowUnified(g_pInputManager->getMouseCoordsInternal(),
                                                                     Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS | Desktop::View::ALLOW_FLOATING);

    auto       focusState = Desktop::focusState();
    auto       window     = focusState->window();
    auto       monitor    = focusState->monitor();

    if (WINDOWATCURSOR != m_pWindow && m_pWindow != window)
        return false;

    // check if input is on top or overlay shell layers
    auto     PMONITOR     = monitor;
    PHLLS    foundSurface = nullptr;
    Vector2D surfaceCoords;

    // check top layer
    g_pCompositor->vectorToLayerSurface(g_pInputManager->getMouseCoordsInternal(), &PMONITOR->m_layerSurfaceLayers[ZWLR_LAYER_SHELL_V1_LAYER_TOP], &surfaceCoords, &foundSurface);

    if (foundSurface)
        return false;
    // check overlay layer
    g_pCompositor->vectorToLayerSurface(g_pInputManager->getMouseCoordsInternal(), &PMONITOR->m_layerSurfaceLayers[ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &surfaceCoords,
                                        &foundSurface);

    if (foundSurface)
        return false;

    return true;
}

void CHyprBar::onMouseButton(Event::SCallbackInfo& info, IPointer::SButtonEvent e) {
    if (!inputIsValid())
        return;

    if (e.state != WL_POINTER_BUTTON_STATE_PRESSED) {
        handleUpEvent(info);
        return;
    }

    if (e.button == BTN_RIGHT) {
        const auto coords = cursorRelativeToBar();
        const auto height = g_pGlobalState->config.barHitHeight->value();
        if (VECINRECT(coords, 0, 0, assignedBoxGlobal().w, height - 1)) {
            const auto window = m_pWindow.lock();
            if (window) {
                Desktop::focusState()->fullWindowFocus(window, Desktop::FOCUS_REASON_CLICK);
                const auto cursor = g_pInputManager->getMouseCoordsInternal();
                const auto address = ownerAddress();
                Config::Supplementary::executor()->spawn(std::format(
                    "enoshima-window-menu --address {} --anchor-x {} --anchor-y {} --source titlebar", address,
                    std::lround(cursor.x), std::lround(cursor.y)));
                info.cancelled = true;
            }
        }
        return;
    }

    handleDownEvent(info, std::nullopt);
}

void CHyprBar::onTouchDown(Event::SCallbackInfo& info, ITouch::SDownEvent e) {
    // Don't do anything if you're already grabbed a window with another finger
    if (!inputIsValid() || e.touchID != 0)
        return;

    handleDownEvent(info, e);
}

void CHyprBar::onTouchUp(Event::SCallbackInfo& info, ITouch::SUpEvent e) {
    if (!m_bDragPending || !m_bTouchEv || e.touchID != m_touchId)
        return;

    handleUpEvent(info);
}

void CHyprBar::onMouseMove(Vector2D) {
    // Hover color, destructive close feedback, and tooltips must update even
    // when icons are configured to remain permanently visible.
    damageOnButtonHover();

    if (m_bDraggingThis && !m_bTouchEv) {
        if (const auto window = m_pWindow.lock(); window && Desktop::focusState()->window() != window)
            Desktop::focusState()->fullWindowFocus(window, Desktop::FOCUS_REASON_CLICK);
        updateSnapPreview(g_pInputManager->getMouseCoordsInternal());
        return;
    }

    if (!m_bDragPending || m_bTouchEv || !validMapped(m_pWindow) || m_touchId != 0)
        return;

    m_bDragPending = false;
    handleMovement();
    updateSnapPreview(g_pInputManager->getMouseCoordsInternal());
}

void CHyprBar::onKeyboardKey(Event::SCallbackInfo& info, IKeyboard::SKeyEvent event) {
    if (!m_bDraggingThis || event.state != WL_KEYBOARD_KEY_STATE_PRESSED || event.keycode != KEY_ESC)
        return;

    info.cancelled = true;
    cancelSnapPreview();
    g_pKeybindManager->changeMouseBindMode(MBIND_INVALID);
    m_bDraggingThis = false;
    m_bDragPending  = false;
}

void CHyprBar::onTouchMove(Event::SCallbackInfo&, ITouch::SMotionEvent e) {
    if (!m_bDragPending || !m_bTouchEv || !validMapped(m_pWindow) || e.touchID != m_touchId)
        return;

    auto PMONITOR     = m_pWindow->m_monitor.lock();
    PMONITOR          = PMONITOR ? PMONITOR : Desktop::focusState()->monitor();
    const auto COORDS = Vector2D(PMONITOR->m_position.x + e.pos.x * PMONITOR->m_size.x, PMONITOR->m_position.y + e.pos.y * PMONITOR->m_size.y);

    if (!m_bDraggingThis) {
        // Initial setup for dragging a window.
        const auto selector = std::format("address:{}", ownerAddress());
        g_pKeybindManager->m_dispatchers["setfloating"](selector);
        g_pKeybindManager->m_dispatchers["resizewindowpixel"](std::format("exact 50% 50%,{}", selector));
        // pin it so you can change workspaces while dragging a window
        g_pKeybindManager->m_dispatchers["pin"](selector);
        startSnapSession();
    }
    g_pKeybindManager->m_dispatchers["movewindowpixel"](
        std::format("exact {} {},address:{}", (int)(COORDS.x - (assignedBoxGlobal().w / 2)), (int)COORDS.y, ownerAddress()));
    m_bDraggingThis = true;
    updateSnapPreview(COORDS);
}

void CHyprBar::handleDownEvent(Event::SCallbackInfo& info, std::optional<ITouch::SDownEvent> touchEvent) {
    m_bTouchEv = touchEvent.has_value();
    if (m_bTouchEv)
        m_touchId = touchEvent.value().touchID;

    const auto PWINDOW = m_pWindow.lock();

    auto       COORDS = cursorRelativeToBar();
    if (m_bTouchEv) {
        ITouch::SDownEvent e        = touchEvent.value();
        auto               PMONITOR = g_pCompositor->getMonitorFromName(!e.device->m_boundOutput.empty() ? e.device->m_boundOutput : "");
        PMONITOR                    = PMONITOR ? PMONITOR : Desktop::focusState()->monitor();
        COORDS = Vector2D(PMONITOR->m_position.x + e.pos.x * PMONITOR->m_size.x, PMONITOR->m_position.y + e.pos.y * PMONITOR->m_size.y) - assignedBoxGlobal().pos();
    }

    const auto HEIGHT           = g_pGlobalState->config.barHitHeight->value();
    const auto BARBUTTONPADDING = g_pGlobalState->config.barButtonPadding->value();
    const auto BARPADDING       = g_pGlobalState->config.barPadding->value();
    const auto ALIGNBUTTONS     = g_pGlobalState->config.barButtonsAlignment->value();
    const auto ON_DOUBLE_CLICK  = g_pGlobalState->config.onDoubleClick->value();

    const bool BUTTONSRIGHT = ALIGNBUTTONS != "left";

    if (!VECINRECT(COORDS, 0, 0, assignedBoxGlobal().w, HEIGHT - 1)) {

        if (m_bDraggingThis) {
            if (m_bTouchEv)
                g_pKeybindManager->m_dispatchers["settiled"](std::format("address:{}", ownerAddress()));
            g_pKeybindManager->m_dispatchers["mouse"]("0movewindow");
            Log::logger->log(Log::DEBUG, "[enoshima-decoration] Dragging ended on {:x}", (uintptr_t)PWINDOW.get());
        }

        m_bDraggingThis = false;
        m_bDragPending  = false;
        m_bTouchEv      = false;
        return;
    }

    if (Desktop::focusState()->window() != PWINDOW)
        Desktop::focusState()->fullWindowFocus(PWINDOW, Desktop::FOCUS_REASON_CLICK);

    if (PWINDOW->m_isFloating)
        g_pCompositor->changeWindowZOrder(PWINDOW, true);

    info.cancelled   = true;
    m_bCancelledDown = true;

    if (doButtonPress(BARPADDING, BARBUTTONPADDING, HEIGHT, COORDS, BUTTONSRIGHT))
        return;

    if (!ON_DOUBLE_CLICK.empty() &&
        std::chrono::duration_cast<std::chrono::milliseconds>(Time::steadyNow() - m_lastMouseDown).count() < 400 /* Arbitrary delay I found suitable */) {
        executeForOwner(ON_DOUBLE_CLICK);
        m_bDragPending = false;
    } else {
        m_lastMouseDown = Time::steadyNow();
        m_bDragPending  = true;
    }
}

void CHyprBar::handleUpEvent(Event::SCallbackInfo& info) {
    if (!m_pWindow.lock())
        return;

    if (m_bCancelledDown)
        info.cancelled = true;

    m_bCancelledDown = false;

    if (m_bDraggingThis) {
        commitSnapPreview();
        g_pKeybindManager->changeMouseBindMode(MBIND_INVALID);
        m_bDraggingThis = false;
        if (m_bTouchEv)
            (void)Config::Actions::floatWindow(Config::Actions::eTogglableAction::TOGGLE_ACTION_DISABLE);

        Log::logger->log(Log::DEBUG, "[enoshima-decoration] Dragging ended on {:x}", (uintptr_t)m_pWindow.lock().get());
    }

    m_bDragPending = false;
    m_bTouchEv     = false;
    m_touchId      = 0;
}

void CHyprBar::handleMovement() {
    g_pKeybindManager->changeMouseBindMode(MBIND_MOVE);
    m_bDraggingThis = true;
    startSnapSession();
    Log::logger->log(Log::DEBUG, "[enoshima-decoration] Dragging initiated on {:x}", (uintptr_t)m_pWindow.lock().get());
    return;
}

void CHyprBar::updateSnapPreview(Vector2D coords) {
    if (std::chrono::duration_cast<std::chrono::milliseconds>(Time::steadyNow() - m_lastSnapPreview).count() < 40)
        return;

    const auto window = m_pWindow.lock();
    if (!window)
        return;

    m_lastSnapPreview = Time::steadyNow();
    sendSnapRequest("preview", coords);
}

void CHyprBar::commitSnapPreview() {
    sendSnapRequest("commit");
    m_snapSession  = 0;
    m_snapSequence = 0;
}

void CHyprBar::cancelSnapPreview() {
    sendSnapRequest("cancel");
    m_snapSession  = 0;
    m_snapSequence = 0;
}

void CHyprBar::startSnapSession() {
    m_snapSession = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(Time::steadyNow().time_since_epoch()).count());
    if (m_snapSession == 0)
        m_snapSession = 1;
    m_snapSequence = 0;
}

bool CHyprBar::sendSnapRequest(const std::string& type, std::optional<Vector2D> coords) {
    const auto address = ownerAddress();
    if (address.empty() || m_snapSession == 0)
        return false;

    const auto runtime = std::getenv("XDG_RUNTIME_DIR");
    if (!runtime || runtime[0] != '/')
        return false;

    const auto socketPath = std::format("{}/enoshima/windowd.sock", runtime);
    sockaddr_un endpoint  = {};
    endpoint.sun_family   = AF_UNIX;
    if (socketPath.size() >= sizeof(endpoint.sun_path))
        return false;
    std::memcpy(endpoint.sun_path, socketPath.c_str(), socketPath.size() + 1);

    const int descriptor = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (descriptor < 0)
        return false;

    timeval timeout = {.tv_sec = 0, .tv_usec = 50000};
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    if (connect(descriptor, reinterpret_cast<sockaddr*>(&endpoint), sizeof(endpoint)) < 0) {
        close(descriptor);
        return false;
    }

    ++m_snapSequence;
    auto request = std::format(
        R"({{"schema":1,"type":"{}","address":"{}","session":{},"sequence":{},"source":"titlebar"}})",
        type, address, m_snapSession, m_snapSequence);
    if (coords)
        request = std::format(
            R"({{"schema":1,"type":"{}","address":"{}","session":{},"sequence":{},"source":"titlebar","x":{},"y":{}}})",
            type, address, m_snapSession, m_snapSequence, std::lround(coords->x), std::lround(coords->y));

    const auto sent = send(descriptor, request.data(), request.size(), MSG_NOSIGNAL);
    char       response[256];
    const auto received = sent == static_cast<ssize_t>(request.size()) ? recv(descriptor, response, sizeof(response), 0) : -1;
    close(descriptor);
    return sent == static_cast<ssize_t>(request.size()) && received > 0;
}

std::string CHyprBar::ownerAddress() const {
    const auto window = m_pWindow.lock();
    if (!window)
        return {};
    return std::format("0x{:x}", reinterpret_cast<uintptr_t>(window.get()));
}

std::string CHyprBar::commandForOwner(const std::string& command) const {
    auto expanded      = command;
    const auto address = ownerAddress();
    if (address.empty())
        return {};

    constexpr std::string_view PLACEHOLDER = "{address}";
    for (size_t offset = expanded.find(PLACEHOLDER); offset != std::string::npos; offset = expanded.find(PLACEHOLDER, offset + address.size()))
        expanded.replace(offset, PLACEHOLDER.size(), address);
    return expanded;
}

void CHyprBar::executeForOwner(const std::string& command) const {
    const auto expanded = commandForOwner(command);
    if (!expanded.empty())
        Config::Supplementary::executor()->spawn(expanded);
}

bool CHyprBar::doButtonPress(Config::INTEGER barPadding, Config::INTEGER barButtonPadding, Config::INTEGER barHeight, Vector2D COORDS, const bool BUTTONSRIGHT) {
    //check if on a button
    float offset = barPadding;

    for (auto& b : g_pGlobalState->buttons) {
        const auto BARBUF     = Vector2D{assignedBoxGlobal().w, static_cast<double>(barHeight)};
        Vector2D   currentPos = Vector2D{(BUTTONSRIGHT ? BARBUF.x - barButtonPadding - b.size - offset : offset), (BARBUF.y - b.size) / 2.0}.floor();

        if (VECINRECT(COORDS, currentPos.x, 0, currentPos.x + b.size + barButtonPadding, barHeight - 1)) {
            // hit on close
            executeForOwner(b.cmd);
            return true;
        }

        offset += barButtonPadding + b.size;
    }
    return false;
}

void CHyprBar::renderBarTitle(const Vector2D& bufferSize, const float scale) {
    const auto COLORVAL         = g_pGlobalState->config.textColor->value();
    const auto SIZE             = g_pGlobalState->config.barTextSize->value();
    const auto FONT             = g_pGlobalState->config.barTextFont->value();
    const auto ALIGN            = g_pGlobalState->config.barTextAlign->value();
    const auto BARPADDING       = g_pGlobalState->config.barPadding->value();
    const auto BARBUTTONPADDING = g_pGlobalState->config.barButtonPadding->value();

    float      buttonSizes = BARBUTTONPADDING;
    for (auto& b : g_pGlobalState->buttons) {
        buttonSizes += b.size + BARBUTTONPADDING;
    }

    const int  scaledSize        = std::round(SIZE * scale);
    const auto scaledButtonsSize = buttonSizes * scale;
    const auto scaledBarPadding  = BARPADDING * scale;
    const int  scaledAppIconSlot = std::round(24 * scale);
    const int  paddingTotal      = scaledBarPadding * 2 + scaledAppIconSlot + scaledButtonsSize + (ALIGN != "left" ? scaledButtonsSize : 0);
    const int  maxWidth          = std::clamp(static_cast<int>(bufferSize.x - paddingTotal), 0, INT_MAX);

    if (m_szLastTitle.empty() || maxWidth < 1) {
        m_pTextTex = nullptr;
        return;
    }

    const CHyprColor COLOR = m_bForcedTitleColor.value_or(configColor(COLORVAL));
    m_pTextTex             = g_pHyprRenderer->renderText(m_szLastTitle, COLOR, scaledSize, false, FONT, maxWidth);
}

size_t CHyprBar::getVisibleButtonCount(Config::INTEGER barButtonPadding, Config::INTEGER barPadding, const Vector2D& bufferSize, const float scale) {
    float  availableSpace = bufferSize.x - barPadding * scale * 2;
    size_t count          = 0;

    for (const auto& button : g_pGlobalState->buttons) {
        const float buttonSpace = (button.size + barButtonPadding) * scale;
        if (availableSpace >= buttonSpace) {
            count++;
            availableSpace -= buttonSpace;
        } else
            break;
    }

    return count;
}

void CHyprBar::renderBarButtons(CBox* barBox, const float scale, const float a) {
    const auto BARBUTTONPADDING = g_pGlobalState->config.barButtonPadding->value();
    const auto BARPADDING       = g_pGlobalState->config.barPadding->value();
    const auto ALIGNBUTTONS     = g_pGlobalState->config.barButtonsAlignment->value();
    const auto INACTIVECOLOR    = g_pGlobalState->config.inactiveButtonColor->value();

    const bool BUTTONSRIGHT    = ALIGNBUTTONS != "left";
    const auto visibleCount    = getVisibleButtonCount(BARBUTTONPADDING, BARPADDING, Vector2D{barBox->w, barBox->h}, scale);
    const bool INVALIDATEICONS = m_bButtonsDirty || m_bWindowSizeChanged;

    int        offset = BARPADDING * scale;
    for (size_t i = 0; i < visibleCount; ++i) {
        auto&      button           = g_pGlobalState->buttons[i];
        const auto scaledButtonSize = button.size * scale;
        const auto scaledButtonsPad = BARBUTTONPADDING * scale;

        auto       color = button.bgcol;

        const bool hovering = (m_iButtonHoverState & (1U << i)) != 0;
        if (hovering) {
            const bool isClose = button.cmd.find(" close ") != std::string::npos || button.cmd.ends_with(" close");
            color              = isClose ? CHyprColor(0xFFFF5D8F) : CHyprColor(0x4462D8FF);
        }

        if (INACTIVECOLOR > 0) {
            color = m_bWindowHasFocus ? color : configColor(INACTIVECOLOR);
            if (INVALIDATEICONS && button.userfg && button.iconTex)
                button.iconTex = nullptr;
        }

        color.a *= a;

        CBox buttonBox = {barBox->x + (BUTTONSRIGHT ? barBox->w - offset - scaledButtonSize : offset), barBox->y + (barBox->h - scaledButtonSize) / 2.0, scaledButtonSize,
                          scaledButtonSize};
        buttonBox.round();

        g_pHyprOpenGL->renderRect(buttonBox, color, {.round = static_cast<int>(std::round(scaledButtonSize / 2.0)), .roundingPower = 2.F});

        offset += scaledButtonsPad + scaledButtonSize;
    }
}

void CHyprBar::renderBarButtonsText(CBox* barBox, const float scale, const float a) {
    const auto BARBUTTONPADDING = g_pGlobalState->config.barButtonPadding->value();
    const auto BARPADDING       = g_pGlobalState->config.barPadding->value();
    const auto ALIGNBUTTONS     = g_pGlobalState->config.barButtonsAlignment->value();
    const auto ICONONHOVER      = g_pGlobalState->config.iconOnHover->value();

    const bool BUTTONSRIGHT = ALIGNBUTTONS != "left";
    const auto visibleCount = getVisibleButtonCount(BARBUTTONPADDING, BARPADDING, Vector2D{barBox->w, barBox->h}, scale);
    if (m_vButtonTextures.size() != visibleCount) {
        m_vButtonTextures.resize(visibleCount);
        m_vButtonIcons.resize(visibleCount);
    }

    int offset = BARPADDING * scale;

    for (size_t i = 0; i < visibleCount; ++i) {
        auto&      button           = g_pGlobalState->buttons[i];
        const auto scaledButtonSize = button.size * scale;
        const auto scaledButtonsPad = BARBUTTONPADDING * scale;

        auto icon = button.icon;
        if (button.semantic == "maximize" && !button.alternateIcon.empty()) {
            const auto window = m_pWindow.lock();
            if (window && window->m_fullscreenState.internal == FSMODE_MAXIMIZED)
                icon = button.alternateIcon;
        }
        const auto cacheKey = std::format("{}@{}", icon, std::lround(scale * 100));
        if (m_vButtonIcons[i] != cacheKey || !m_vButtonTextures[i] || m_vButtonTextures[i]->m_texID == 0) {
            const auto fgcol = button.userfg ? button.fgcol : (button.bgcol.r + button.bgcol.g + button.bgcol.b < 1) ? CHyprColor(0xFFFFFFFF) : CHyprColor(0xFF000000);
            m_vButtonTextures[i] = icon.ends_with(".svg") ? svgTexture(icon, std::round(16 * scale), fgcol) :
                                                           g_pHyprRenderer->renderText(icon, fgcol, std::round(button.size * 0.62 * scale), false, "sans", scaledButtonSize);
            m_vButtonIcons[i] = cacheKey;
        }

        const auto& iconTexture = m_vButtonTextures[i];

        if (!iconTexture || iconTexture->m_texID == 0)
            continue;

        const auto iconX = barBox->x + (BUTTONSRIGHT ? barBox->width - offset - scaledButtonSize / 2.0 : offset + scaledButtonSize / 2.0) - iconTexture->m_size.x / 2.0;
        const auto iconY = barBox->y + barBox->height / 2.0 - iconTexture->m_size.y / 2.0;
        CBox       pos   = {iconX, iconY, iconTexture->m_size.x, iconTexture->m_size.y};

        if (!ICONONHOVER || (ICONONHOVER && m_iButtonHoverState > 0)) {
            CHyprOpenGLImpl::STextureRenderData textureData;
            textureData.a = a * (m_bWindowHasFocus ? 1.F : 0.62F);
            g_pHyprOpenGL->renderTexture(iconTexture, pos, textureData);
        }
        offset += scaledButtonsPad + scaledButtonSize;

    }
}

void CHyprBar::renderAppIcon(CBox* barBox, const float scale, const float a) {
    const auto window = m_pWindow.lock();
    if (!window)
        return;
    const auto iconPath = iconPathForClass(window->m_class.empty() ? window->m_initialClass : window->m_class);
    const auto cacheKey = std::format("{}@{}", iconPath, std::lround(scale * 100));
    if (cacheKey != m_szAppIconPath || !m_pAppIconTex || m_pAppIconTex->m_texID == 0) {
        m_pAppIconTex   = svgTexture(iconPath, std::round(18 * scale));
        m_szAppIconPath = cacheKey;
    }
    if (!m_pAppIconTex || m_pAppIconTex->m_texID == 0)
        return;

    const auto padding = g_pGlobalState->config.barPadding->value() * scale;
    CBox       iconBox = {barBox->x + padding, barBox->y + (barBox->h - m_pAppIconTex->m_size.y) / 2.0,
                           m_pAppIconTex->m_size.x, m_pAppIconTex->m_size.y};
    CHyprOpenGLImpl::STextureRenderData textureData;
    textureData.a = a * (m_bWindowHasFocus ? 1.F : 0.62F);
    g_pHyprOpenGL->renderTexture(m_pAppIconTex, iconBox, textureData);
}

void CHyprBar::renderButtonTooltip(CBox* barBox, const float scale, const float a) {
    if (m_iHoveredButton < 0 || static_cast<size_t>(m_iHoveredButton) >= g_pGlobalState->buttons.size())
        return;
    const auto& text = g_pGlobalState->buttons[m_iHoveredButton].tooltip;
    if (text.empty())
        return;
    if (m_szTooltip != text || !m_pTooltipTex || m_pTooltipTex->m_texID == 0) {
        m_pTooltipTex = g_pHyprRenderer->renderText(text, CHyprColor(0xFFF2ECFF), std::round(11 * scale), false, "Pretendard", std::round(180 * scale));
        m_szTooltip   = text;
    }
    if (!m_pTooltipTex || m_pTooltipTex->m_texID == 0)
        return;

    const auto padding = 8 * scale;
    const auto width   = m_pTooltipTex->m_size.x + padding * 2;
    const auto height  = m_pTooltipTex->m_size.y + padding;
    const auto right   = barBox->x + barBox->w - g_pGlobalState->config.barPadding->value() * scale;
    CBox       box     = {std::max(barBox->x, right - width), barBox->y + barBox->h + 4 * scale, width, height};
    g_pHyprOpenGL->renderRect(box, CHyprColor(0xEE161151), {.round = static_cast<int>(std::round(8 * scale)), .roundingPower = 2.F});
    CBox textBox = {box.x + padding, box.y + padding / 2.0, m_pTooltipTex->m_size.x, m_pTooltipTex->m_size.y};
    CHyprOpenGLImpl::STextureRenderData textureData;
    textureData.a = a;
    g_pHyprOpenGL->renderTexture(m_pTooltipTex, textBox, textureData);
}

void CHyprBar::draw(PHLMONITOR, const float& a) {
    const auto ENABLED = g_pGlobalState->config.enabled->value();

    if (m_bLastEnabledState != ENABLED) {
        m_bLastEnabledState = ENABLED;
        g_pDecorationPositioner->repositionDeco(this);
    }

    if (m_hidden || !validMapped(m_pWindow) || !ENABLED)
        return;

    const auto PWINDOW = m_pWindow.lock();

    if (!PWINDOW->m_ruleApplicator->decorate().valueOrDefault())
        return;

    auto data = CBarPassElement::SBarData{this, a};
    g_pHyprRenderer->m_renderPass.add(makeUnique<CBarPassElement>(data));
}

void CHyprBar::renderPass(PHLMONITOR pMonitor, const float& a) {
    const auto  PWINDOW = m_pWindow.lock();

    static auto PENABLEBLURGLOBAL = CConfigValue<Config::BOOL>("decoration:blur:enabled");
    const auto  BARCOLOR          = g_pGlobalState->config.barColor->value();
    const auto  HEIGHT            = g_pGlobalState->config.barHeight->value();
    const auto  HITHEIGHT         = g_pGlobalState->config.barHitHeight->value();
    const auto  PRECEDENCE        = g_pGlobalState->config.barPrecedenceOverBorder->value();
    const auto  ALIGNBUTTONS      = g_pGlobalState->config.barButtonsAlignment->value();
    const auto  ENABLETITLE       = g_pGlobalState->config.barTitleEnabled->value();
    const auto  ENABLEBLUR        = g_pGlobalState->config.barBlur->value();
    const auto  INACTIVECOLOR     = g_pGlobalState->config.inactiveButtonColor->value();

    if (INACTIVECOLOR > 0) {
        bool currentWindowFocus = PWINDOW == Desktop::focusState()->window();
        if (currentWindowFocus != m_bWindowHasFocus) {
            m_bWindowHasFocus = currentWindowFocus;
            m_bButtonsDirty   = true;
        }
    }

    const CHyprColor DEST_COLOR = m_bForcedBarColor.value_or(configColor(BARCOLOR));
    if (DEST_COLOR != m_cRealBarColor->goal())
        *m_cRealBarColor = DEST_COLOR;

    CHyprColor color = m_cRealBarColor->value();

    color.a *= a;
    const bool BUTTONSRIGHT = ALIGNBUTTONS != "left";
    const bool SHOULDBLUR   = ENABLEBLUR && *PENABLEBLURGLOBAL && color.a < 1.F;

    if (HEIGHT < 1) {
        m_iLastHeight = HEIGHT;
        return;
    }

    const auto PWORKSPACE      = PWINDOW->m_workspace;
    const auto WORKSPACEOFFSET = PWORKSPACE && !PWINDOW->m_pinned ? PWORKSPACE->m_renderOffset->value() : Vector2D();

    const auto ROUNDING = PWINDOW->rounding() + (PRECEDENCE ? 0 : PWINDOW->getRealBorderSize());

    const auto scaledRounding = ROUNDING > 0
        ? std::max(0, static_cast<int>(std::lround(ROUNDING * pMonitor->m_scale - 2)))
        : 0;

    m_seExtents = {{0, static_cast<int>(HITHEIGHT)}, {}};

    const auto DECOBOX = assignedBoxGlobal();

    const auto BARBUF = Vector2D{DECOBOX.w, static_cast<double>(HEIGHT)} * pMonitor->m_scale;

    CBox       titleBarBox = {DECOBOX.x - pMonitor->m_position.x,
                              DECOBOX.y - pMonitor->m_position.y + std::max(0.0, (DECOBOX.h - HEIGHT) / 2.0), DECOBOX.w,
                              HEIGHT + ROUNDING * 3 /* to fill the bottom cuz we can't disable rounding there */};

    titleBarBox.translate(PWINDOW->m_floatingOffset).scale(pMonitor->m_scale).round();

    if (titleBarBox.w < 1 || titleBarBox.h < 1)
        return;

    g_pHyprOpenGL->scissor(titleBarBox);

    if (ROUNDING) {
        // the +1 is a shit garbage temp fix until renderRect supports an alpha matte
        CBox windowBox = {PWINDOW->m_realPosition->value().x + PWINDOW->m_floatingOffset.x - pMonitor->m_position.x + 1,
                          PWINDOW->m_realPosition->value().y + PWINDOW->m_floatingOffset.y - pMonitor->m_position.y + 1, PWINDOW->m_realSize->value().x - 2,
                          PWINDOW->m_realSize->value().y - 2};

        if (windowBox.w < 1 || windowBox.h < 1)
            return;

        glClearStencil(0);
        glClear(GL_STENCIL_BUFFER_BIT);

        g_pHyprOpenGL->setCapStatus(GL_STENCIL_TEST, true);

        glStencilFunc(GL_ALWAYS, 1, -1);
        glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);

        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);

        windowBox.translate(WORKSPACEOFFSET).scale(pMonitor->m_scale).round();
        g_pHyprOpenGL->renderRect(windowBox, CHyprColor(0, 0, 0, 0), {.round = scaledRounding, .roundingPower = m_pWindow->roundingPower()});
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

        glStencilFunc(GL_NOTEQUAL, 1, -1);
        glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
    }

    if (SHOULDBLUR)
        g_pHyprOpenGL->renderRect(titleBarBox, color, {.round = scaledRounding, .roundingPower = m_pWindow->roundingPower(), .blur = true, .blurA = a});
    else
        g_pHyprOpenGL->renderRect(titleBarBox, color, {.round = scaledRounding, .roundingPower = m_pWindow->roundingPower()});

    // render title
    if (ENABLETITLE && (m_szLastTitle != PWINDOW->m_title || m_bWindowSizeChanged || !m_pTextTex || m_pTextTex->m_texID == 0 || m_bTitleColorChanged)) {
        m_szLastTitle = PWINDOW->m_title;
        renderBarTitle(BARBUF, pMonitor->m_scale);
    }

    if (ROUNDING) {
        // cleanup stencil
        glClearStencil(0);
        glClear(GL_STENCIL_BUFFER_BIT);
        g_pHyprOpenGL->setCapStatus(GL_STENCIL_TEST, false);
        glStencilMask(-1);
        glStencilFunc(GL_ALWAYS, 1, 0xFF);
    }

    CBox textBox = {titleBarBox.x, titleBarBox.y, BARBUF.x, BARBUF.y};
    if (ENABLETITLE && m_pTextTex) {
        const auto BARPADDING       = g_pGlobalState->config.barPadding->value();
        const auto BARBUTTONPADDING = g_pGlobalState->config.barButtonPadding->value();
        const auto ALIGN            = g_pGlobalState->config.barTextAlign->value();

        float      buttonSizes = BARBUTTONPADDING;
        for (auto& b : g_pGlobalState->buttons) {
            buttonSizes += b.size + BARBUTTONPADDING;
        }

        const auto scaledBorderSize  = PWINDOW->getRealBorderSize() * pMonitor->m_scale;
        const auto scaledButtonsSize = buttonSizes * pMonitor->m_scale;
        const auto scaledBarPadding  = BARPADDING * pMonitor->m_scale;
        const auto scaledAppIconSlot = 24 * pMonitor->m_scale;
        const auto xOffset           = ALIGN == "left" ? std::round(scaledBarPadding + scaledAppIconSlot + (BUTTONSRIGHT ? 0 : scaledButtonsSize)) :
                                                         std::round(((BARBUF.x - scaledBorderSize) / 2.0 - m_pTextTex->m_size.x / 2.0));
        const auto yOffset           = std::round((BARBUF.y - m_pTextTex->m_size.y) / 2.0);
        CBox       titleBox          = {textBox.x + xOffset, textBox.y + yOffset, m_pTextTex->m_size.x, m_pTextTex->m_size.y};

        CHyprOpenGLImpl::STextureRenderData textureData;
        textureData.a = a * (m_bWindowHasFocus ? 1.F : 0.72F);
        g_pHyprOpenGL->renderTexture(m_pTextTex, titleBox, textureData);
    }

    renderBarButtons(&textBox, pMonitor->m_scale, a);
    m_bButtonsDirty = false;

    g_pHyprOpenGL->scissor(nullptr);

    renderAppIcon(&textBox, pMonitor->m_scale, a);
    renderBarButtonsText(&textBox, pMonitor->m_scale, a);
    renderButtonTooltip(&textBox, pMonitor->m_scale, a);

    m_bWindowSizeChanged = false;
    m_bTitleColorChanged = false;

    // dynamic updates change the extents
    if (m_iLastHeight != HITHEIGHT) {
        PWINDOW->layoutTarget()->recalc();
        m_iLastHeight = HITHEIGHT;
    }
}

eDecorationType CHyprBar::getDecorationType() {
    return DECORATION_CUSTOM;
}

void CHyprBar::updateWindow(PHLWINDOW) {
    damageEntire();
}

void CHyprBar::onConfigReloaded() {
    m_bButtonsDirty      = true;
    m_bTitleColorChanged = true;
    m_pTextTex           = nullptr;
    m_pAppIconTex        = nullptr;
    m_pTooltipTex        = nullptr;
    m_vButtonTextures.clear();
    m_vButtonIcons.clear();

    g_pDecorationPositioner->repositionDeco(this);
    damageEntire();
}

void CHyprBar::damageEntire() {
    g_pHyprRenderer->damageBox(assignedBoxGlobal());
}

Vector2D CHyprBar::cursorRelativeToBar() {
    return g_pInputManager->getMouseCoordsInternal() - assignedBoxGlobal().pos();
}

eDecorationLayer CHyprBar::getDecorationLayer() {
    return DECORATION_LAYER_UNDER;
}

uint64_t CHyprBar::getDecorationFlags() {
    return DECORATION_ALLOWS_MOUSE_INPUT | (g_pGlobalState->config.barPartOfWindow->value() ? DECORATION_PART_OF_MAIN_WINDOW : 0);
}

CBox CHyprBar::assignedBoxGlobal() {
    if (!validMapped(m_pWindow))
        return {};

    CBox box = m_bAssignedBox;
    box.translate(g_pDecorationPositioner->getEdgeDefinedPoint(DECORATION_EDGE_TOP, m_pWindow.lock()));

    const auto PWORKSPACE      = m_pWindow->m_workspace;
    const auto WORKSPACEOFFSET = PWORKSPACE && !m_pWindow->m_pinned ? PWORKSPACE->m_renderOffset->value() : Vector2D();

    return box.translate(WORKSPACEOFFSET);
}

PHLWINDOW CHyprBar::getOwner() {
    return m_pWindow.lock();
}

void CHyprBar::updateRules() {
    const auto PWINDOW              = m_pWindow.lock();
    auto       prevHidden           = m_hidden;
    auto       prevForcedTitleColor = m_bForcedTitleColor;

    m_bForcedBarColor   = std::nullopt;
    m_bForcedTitleColor = std::nullopt;
    m_hidden            = false;

    if (PWINDOW->m_ruleApplicator->m_otherProps.props.contains(g_pGlobalState->nobarRuleIdx))
        m_hidden = truthy(PWINDOW->m_ruleApplicator->m_otherProps.props.at(g_pGlobalState->nobarRuleIdx)->effect);
    if (PWINDOW->m_ruleApplicator->m_otherProps.props.contains(g_pGlobalState->barColorRuleIdx))
        m_bForcedBarColor = CHyprColor(Config::ParserUtils::parseColor(PWINDOW->m_ruleApplicator->m_otherProps.props.at(g_pGlobalState->barColorRuleIdx)->effect).value_or(0));
    if (PWINDOW->m_ruleApplicator->m_otherProps.props.contains(g_pGlobalState->titleColorRuleIdx))
        m_bForcedTitleColor = CHyprColor(Config::ParserUtils::parseColor(PWINDOW->m_ruleApplicator->m_otherProps.props.at(g_pGlobalState->titleColorRuleIdx)->effect).value_or(0));

    if (prevHidden != m_hidden)
        g_pDecorationPositioner->repositionDeco(this);
    if (prevForcedTitleColor != m_bForcedTitleColor)
        m_bTitleColorChanged = true;
}

void CHyprBar::damageOnButtonHover() {
    const auto BARPADDING       = g_pGlobalState->config.barPadding->value();
    const auto BARBUTTONPADDING = g_pGlobalState->config.barButtonPadding->value();
    const auto HEIGHT           = g_pGlobalState->config.barHitHeight->value();
    const auto ALIGNBUTTONS     = g_pGlobalState->config.barButtonsAlignment->value();
    const bool BUTTONSRIGHT     = ALIGNBUTTONS != "left";

    float        offset   = BARPADDING;
    unsigned int newState = 0;
    int          hovered  = -1;

    const auto COORDS = cursorRelativeToBar();

    for (size_t index = 0; index < g_pGlobalState->buttons.size(); ++index) {
        auto&      b          = g_pGlobalState->buttons[index];
        const auto BARBUF     = Vector2D{assignedBoxGlobal().w, static_cast<double>(HEIGHT)};
        Vector2D   currentPos = Vector2D{(BUTTONSRIGHT ? BARBUF.x - BARBUTTONPADDING - b.size - offset : offset), (BARBUF.y - b.size) / 2.0}.floor();

        bool       hover = VECINRECT(COORDS, currentPos.x, 0, currentPos.x + b.size + BARBUTTONPADDING, HEIGHT - 1);
        if (hover) {
            newState |= 1U << index;
            hovered = static_cast<int>(index);
        }

        offset += BARBUTTONPADDING + b.size;
    }

    if (newState != m_iButtonHoverState || hovered != m_iHoveredButton) {
        m_iButtonHoverState = newState;
        m_iHoveredButton    = hovered;
        m_bButtonHovered    = hovered >= 0;
        m_lastButtonHover   = Time::steadyNow();
        m_pTooltipTex       = nullptr;
        m_szTooltip.clear();
        auto damage = assignedBoxGlobal();
        damage.h += 40;
        g_pHyprRenderer->damageBox(damage);
    }
}
