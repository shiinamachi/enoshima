//@ pragma IconTheme Papirus-Dark

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

ShellRoot {
    id: root

    property var snapshot: ({
        "activeAddress": "",
        "monitors": [],
        "windows": []
    })
    property bool launcherOpen: false
    property string launcherScreenName: ""
    property bool displayOverlayOpen: false
    property string displayOverlayScreenName: ""
    property bool powerMenuOpen: false
    property string powerMenuScreenName: ""
    property bool windowMenuOpen: false
    property string windowMenuScreenName: ""
    property string windowMenuAddress: ""
    property int windowMenuAnchorX: 14
    property int windowMenuAnchorY: 48
    property string windowMenuSource: "keyboard"
    property bool kakaoFocusPulseActive: false
    property string kakaoFocusScreenName: ""
    property string kakaoFocusTargetAddress: ""
    property bool osdVisible: false
    property string osdScreenName: ""
    property string osdKind: "volume"
    property int osdValue: 0
    property bool osdMuted: false
    property var pinIds: []
    property bool pinsLoaded: false

    readonly property alias theme: themeTokens
    readonly property string appearanceStateHome: {
        const configured = Quickshell.env("XDG_STATE_HOME");
        return configured !== ""
            ? configured
            : Quickshell.env("HOME") + "/.local/state";
    }
    readonly property string configHome: {
        const configured = Quickshell.env("XDG_CONFIG_HOME");
        return configured !== ""
            ? configured
            : Quickshell.env("HOME") + "/.config";
    }
    readonly property string runtimeHome: Quickshell.env("XDG_RUNTIME_DIR")
    property int snapClock: 0
    readonly property var snapState: parseSnapState(snapStateFile.text, snapClock)
    readonly property string pinsPath:
        configHome + "/enoshima/user/cyberdock-pins.json"
    readonly property string appearanceMode: {
        const candidate = appearanceModeFile.text().trim();
        if (["default", "reduced-motion", "reduced-transparency", "accessible"]
                .includes(candidate))
            return candidate;
        return "default";
    }
    readonly property bool reducedMotion: appearanceMode === "reduced-motion"
        || appearanceMode === "accessible"
    readonly property bool reducedTransparency: appearanceMode === "reduced-transparency"
        || appearanceMode === "accessible"

    // Semantic colors mirror the shared GTK palette while keeping QML free
    // from a runtime palette parser. Launcher and OSD receive this same object
    // so color, geometry, and motion roles cannot drift between shell surfaces.
    QtObject {
        id: themeTokens

        readonly property color colorCanvas: "#050623"
        readonly property color colorSurface: "#0a0c3e"
        readonly property color colorRaised: "#161151"
        readonly property color colorCanvasOverlay: root.reducedTransparency
            ? "#ff050623" : "#f2050623"
        readonly property color colorSurfaceOverlay: root.reducedTransparency
            ? "#ff0a0c3e" : "#f20a0c3e"
        readonly property color colorRaisedOverlay: root.reducedTransparency
            ? "#ff161151" : "#f2161151"
        readonly property color colorLauncherSurface: root.reducedTransparency
            ? "#ff0a0c3e" : "#f70a0c3e"
        readonly property color colorScrim: root.reducedTransparency
            ? "#b3050623" : "#99050623"
        readonly property color colorFooter: root.reducedTransparency
            ? "#cc050623" : "#66050623"
        readonly property color colorSurfaceSubtle: root.reducedTransparency
            ? "#66161151" : "#33161151"
        readonly property color colorRaisedSoft: root.reducedTransparency
            ? "#dd161151" : "#88161151"
        readonly property color colorDivider: "#556d8cff"
        readonly property color colorQuietBorder: "#886d8cff"
        readonly property color colorInfoBorder: "#996d8cff"
        readonly property color colorFocus: "#62d8ff"
        readonly property color colorFocusBorder: "#cc62d8ff"
        readonly property color colorFocusHover: "#4462d8ff"
        readonly property color colorFocusSelected: "#3362d8ff"
        readonly property color colorSelection: "#9a5cff"
        readonly property color colorSelectionSoft: "#669a5cff"
        readonly property color colorSelectionHover: "#cc6541b8"
        readonly property color colorSelectionBorder: "#cc9a5cff"
        readonly property color colorSelectionStrong: "#6541b8"
        readonly property color colorAccent: "#e56bff"
        readonly property color colorText: "#f2ecff"
        readonly property color colorTextMuted: "#c9bfe8"
        readonly property color colorTextSubtle: "#b3c9bfe8"
        readonly property color colorOnSelection: "#f2ecff"
        readonly property color colorInfo: "#6d8cff"
        readonly property color colorCritical: "#ff5d8f"
        readonly property color colorSuccess: "#77e0c6"
        readonly property color colorWarning: "#ffb86b"
        readonly property color colorTrack: "#446d8cff"

        readonly property int radiusPanel: 14
        readonly property int radiusControl: 12
        readonly property int radiusSmall: 10

        readonly property int durationInstant: 90
        readonly property int durationFast: 110
        readonly property int durationDirect: 120
        readonly property int durationExit: 145
        readonly property int durationStandard: 150
        readonly property int durationEnter: 190
        readonly property int durationOsdVisible: 1400
    }

    FileView {
        id: appearanceModeFile
        path: root.appearanceStateHome + "/desktop-appearance/mode"
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
    }

    function parseSnapState(text, clock) {
        void clock;
        try {
            const document = JSON.parse(text || "{}");
            if (document.schema === 2)
                return document;
        } catch (error) {
            // A writer uses atomic rename, but an absent first-run state is
            // still expected before the first title-bar drag.
        }
        return {"schema": 2, "active": false, "updatedAt": 0};
    }

    FileView {
        id: snapStateFile
        path: root.runtimeHome + "/enoshima/snap.json"
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
    }

    Timer {
        interval: 100
        repeat: true
        running: Boolean(root.snapState.active)
        onTriggered: root.snapClock += 1
    }

    // The mode file is created only after the user first selects a profile.
    // Retry only while it is absent; once loaded, FileView handles updates.
    Timer {
        interval: 2000
        repeat: true
        running: !appearanceModeFile.loaded
        onTriggered: appearanceModeFile.reload()
    }

    readonly property var systemLauncherApp: ({
        "id": "launcher",
        "desktopId": "",
        "name": "Applications",
        "icon": "view-app-grid-symbolic",
        "command": [Quickshell.env("HOME") + "/.local/bin/cyberlauncher-toggle"],
        "pinned": false,
        "systemControl": true,
        "unavailable": false,
        "windows": []
    })

    FileView {
        id: pinsFile
        path: root.pinsPath
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: {
            reload();
            root.schedulePinsRefresh();
        }
    }

    Process {
        id: pinsProcess
        command: ["cyberdock-pins", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const document = JSON.parse(text);
                    if (document.schema === 1 && Array.isArray(document.entries)) {
                        root.pinIds = document.entries.map(entry => String(entry));
                        root.pinsLoaded = true;
                    }
                } catch (error) {
                    console.warn("cyberdock: invalid pin state:", error);
                }
            }
        }
    }

    Timer {
        id: refreshPinsSoon
        interval: 180
        repeat: false
        onTriggered: {
            if (!pinsProcess.running)
                pinsProcess.running = true;
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: !root.pinsLoaded
        triggeredOnStart: true
        onTriggered: refreshPinsSoon.restart()
    }

    function runPinAction(arguments_) {
        Quickshell.execDetached(["cyberdock-pins"].concat(arguments_));
        refreshPinsSoon.restart();
    }

    function schedulePinsRefresh() {
        refreshPinsSoon.restart();
    }

    function normalizeDesktopId(value) {
        const id = String(value || "").toLocaleLowerCase();
        if (id === "")
            return "";
        return /\.desktop$/.test(id) ? id : id + ".desktop";
    }

    function canonicalDesktopId(value) {
        const id = String(value || "");
        if (id === "")
            return "";
        return /\.desktop$/i.test(id) ? id : id + ".desktop";
    }

    function desktopEntryById(id) {
        const target = normalizeDesktopId(id);
        for (const entry of DesktopEntries.applications.values) {
            if (entry && normalizeDesktopId(entry.id) === target)
                return entry;
        }
        return null;
    }

    function pinPosition(id) {
        const target = normalizeDesktopId(id);
        for (let index = 0; index < pinIds.length; ++index) {
            if (normalizeDesktopId(pinIds[index]) === target)
                return index;
        }
        return -1;
    }

    function reorderPinnedFromDrag(id, offsetX, slotWidth) {
        const currentIndex = pinPosition(id);
        if (currentIndex < 0 || pinIds.length < 2)
            return;

        const normalizedSlot = Math.max(1, Number(slotWidth || 1));
        const rawDelta = Number(offsetX || 0) / normalizedSlot;
        const delta = rawDelta >= 0
            ? Math.floor(rawDelta + 0.5)
            : Math.ceil(rawDelta - 0.5);
        const targetIndex = Math.max(0,
            Math.min(pinIds.length - 1, currentIndex + delta));
        if (targetIndex === currentIndex)
            return;

        runPinAction([
            "move", id,
            targetIndex < currentIndex ? "--before" : "--after",
            pinIds[targetIndex]
        ]);
    }

    function pinnedMetadata(id) {
        const entry = desktopEntryById(id);
        const fallbackName = String(id).replace(/\.desktop$/i, "");
        return {
            "id": "pinned-" + normalizeDesktopId(id),
            "desktopId": String(id),
            "name": entry ? entry.name : fallbackName,
            "icon": entry && entry.icon ? entry.icon : "application-x-executable",
            "command": entry ? [...entry.command] : [],
            "pinned": true,
            "systemControl": false,
            "unavailable": entry === null,
            "windows": []
        };
    }

    function focusedScreenName() {
        const monitors = snapshot.monitors || [];
        for (const monitor of monitors) {
            if (monitor.focused)
                return String(monitor.name || "");
        }
        return monitors.length > 0 ? String(monitors[0].name || "") : "";
    }

    function toggleLauncher() {
        if (launcherOpen) {
            launcherOpen = false;
            return;
        }
        launcherScreenName = focusedScreenName();
        launcherOpen = true;
    }

    function toggleDisplayOverlay() {
        if (displayOverlayOpen) {
            displayOverlayOpen = false;
            return;
        }
        launcherOpen = false;
        displayOverlayScreenName = focusedScreenName();
        displayOverlayOpen = true;
    }

    function togglePowerMenu() {
        if (powerMenuOpen) {
            powerMenuOpen = false;
            return;
        }
        launcherOpen = false;
        displayOverlayOpen = false;
        powerMenuScreenName = focusedScreenName();
        powerMenuOpen = true;
    }

    function windowByAddress(address) {
        return (snapshot.windows || []).find(window =>
            String(window.address || "") === String(address || "")) || ({});
    }

    function screenForWindow(address) {
        const window = windowByAddress(address);
        const monitor = (snapshot.monitors || []).find(candidate =>
            Number(candidate.id) === Number(window.monitor));
        return monitor ? String(monitor.name || "") : focusedScreenName();
    }

    function showOsd(kind, value, muted) {
        osdScreenName = focusedScreenName();
        osdKind = kind;
        osdValue = Math.max(0, Math.min(100, value));
        osdMuted = muted;
        osdVisible = true;
        osdHideTimer.restart();
    }

    IpcHandler {
        target: "launcher"

        function toggle(): void { root.toggleLauncher(); }
        function open(): void {
            root.launcherScreenName = root.focusedScreenName();
            root.launcherOpen = true;
        }
        function close(): void { root.launcherOpen = false; }
    }

    IpcHandler {
        target: "display"

        function toggle(): void { root.toggleDisplayOverlay(); }
        function open(): void {
            root.launcherOpen = false;
            root.displayOverlayScreenName = root.focusedScreenName();
            root.displayOverlayOpen = true;
        }
        function close(): void { root.displayOverlayOpen = false; }
    }

    IpcHandler {
        target: "power"

        function toggle(): void { root.togglePowerMenu(); }
        function open(): void {
            root.launcherOpen = false;
            root.displayOverlayOpen = false;
            root.powerMenuScreenName = root.focusedScreenName();
            root.powerMenuOpen = true;
        }
        function close(): void { root.powerMenuOpen = false; }
    }

    IpcHandler {
        target: "windowmenu"

        function open(address: string, anchorX: int, anchorY: int,
                source: string): void {
            if (!/^0x[0-9A-Fa-f]+$/.test(address)
                    || Object.keys(root.windowByAddress(address)).length === 0)
                return;
            root.launcherOpen = false;
            root.displayOverlayOpen = false;
            root.powerMenuOpen = false;
            root.windowMenuAddress = address;
            root.windowMenuScreenName = root.screenForWindow(address);
            root.windowMenuAnchorX = anchorX;
            root.windowMenuAnchorY = anchorY;
            root.windowMenuSource = source;
            root.windowMenuOpen = true;
        }
        function close(): void { root.windowMenuOpen = false; }
    }

    IpcHandler {
        target: "kakaofocus"

        function pulse(address: string): void {
            if (!/^0x[0-9A-Fa-f]+$/.test(address))
                return;
            root.kakaoFocusPulseActive = false;
            root.kakaoFocusScreenName = root.focusedScreenName();
            root.kakaoFocusTargetAddress = address;
            Qt.callLater(() => root.kakaoFocusPulseActive = true);
        }
    }

    IpcHandler {
        target: "osd"

        function show(kind: string, value: int, muted: bool): void {
            root.showOsd(kind, value, muted);
        }
    }

    Timer {
        id: osdHideTimer
        interval: root.theme.durationOsdVisible
        repeat: false
        onTriggered: root.osdVisible = false
    }

    function windowClass(window) {
        return String(window.initialClass || window.class || "");
    }

    function pinnedIndex(window) {
        const candidate = windowClass(window);
        const entry = DesktopEntries.heuristicLookup(candidate);
        const desktopId = entry ? normalizeDesktopId(entry.id) : "";
        for (let index = 0; index < pinIds.length; ++index) {
            if (desktopId !== "" && desktopId === normalizeDesktopId(pinIds[index]))
                return index;
        }
        return -1;
    }

    function recentWindows(windows) {
        return windows.slice().sort((left, right) =>
            Number(left.focusHistoryID === undefined ? 999999 : left.focusHistoryID)
            - Number(right.focusHistoryID === undefined ? 999999 : right.focusHistoryID));
    }

    function dynamicMetadata(window) {
        const candidate = windowClass(window);
        const entry = DesktopEntries.heuristicLookup(candidate);
        return {
            "name": entry ? entry.name : candidate,
            "icon": entry && entry.icon ? entry.icon : "application-x-executable",
            "desktopId": entry ? canonicalDesktopId(entry.id) : ""
        };
    }

    function buildDockApps() {
        const groups = pinIds.map(id => pinnedMetadata(id));
        const dynamic = {};
        const windows = snapshot.windows || [];

        for (const window of windows) {
            const index = pinnedIndex(window);
            if (index >= 0) {
                groups[index].windows.push(window);
                continue;
            }

            const key = windowClass(window).toLowerCase();
            if (!key)
                continue;
            if (!dynamic[key]) {
                const metadata = dynamicMetadata(window);
                dynamic[key] = {
                    "id": "running-" + key,
                    "desktopId": metadata.desktopId,
                    "name": metadata.name,
                    "icon": metadata.icon,
                    "command": [],
                    "pinned": false,
                    "systemControl": false,
                    "unavailable": false,
                    "windows": []
                };
            }
            dynamic[key].windows.push(window);
        }

        for (const group of groups)
            group.windows = recentWindows(group.windows);
        const runningOnly = Object.values(dynamic);
        for (const group of runningOnly)
            group.windows = recentWindows(group.windows);
        runningOnly.sort((left, right) => left.name.localeCompare(right.name));
        return groups.concat(runningOnly).concat([systemLauncherApp]);
    }

    function launchApp(app) {
        if (!app.command || app.command.length === 0)
            return;
        Quickshell.execDetached(["uwsm", "app", "--"].concat(app.command));
        refreshSoon.restart();
    }

    function activateWindow(address) {
        Quickshell.execDetached(["cyberdock-activate", address]);
        refreshSoon.restart();
    }

    function minimizeWindow(address) {
        Quickshell.execDetached(["cyberdock-minimize", address]);
        refreshSoon.restart();
    }

    function closeWindow(address) {
        Quickshell.execDetached(["cyberdock-close", address]);
        refreshSoon.restart();
    }

    function windowTitle(window) {
        const title = String(window.title || "").trim();
        return title || windowClass(window) || "Window";
    }

    Process {
        id: snapshotProcess
        command: ["cyberdock-state", "snapshot"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const next = JSON.parse(text);
                    if (next.version === 2) {
                        root.snapshot = next;
                        if (root.displayOverlayOpen
                                && !next.monitors.some(monitor =>
                                    String(monitor.name || "")
                                        === root.displayOverlayScreenName)) {
                            root.displayOverlayScreenName = root.focusedScreenName();
                        }
                        if (root.powerMenuOpen
                                && !next.monitors.some(monitor =>
                                    String(monitor.name || "")
                                        === root.powerMenuScreenName)) {
                            root.powerMenuScreenName = root.focusedScreenName();
                        }
                    }
                } catch (error) {
                    console.warn("cyberdock: invalid snapshot:", error);
                }
            }
        }
    }

    Timer {
        id: snapshotTimer
        interval: 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (!snapshotProcess.running)
                snapshotProcess.running = true;
        }
    }

    Timer {
        id: refreshSoon
        interval: 180
        repeat: false
        onTriggered: {
            if (!snapshotProcess.running)
                snapshotProcess.running = true;
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: Component {
            // Quickshell's generated qmltypes marks this runtime-provided
            // window interface as uncreatable even though the plugin creates it.
            // qmllint disable uncreatable-type
            PanelWindow {
                // qmllint enable uncreatable-type
                id: dockWindow

                required property var modelData
                property bool manualReveal: false
                property var chooserWindows: []
                property string chooserTitle: ""
                property var dockApps: root.buildDockApps()
                property string tooltipAppId: ""
                property string tooltipText: ""
                property real tooltipCenterX: width / 2
                property var menuApp: null
                property real menuCenterX: width / 2
                property bool pinDragActive: false
                readonly property int dockBottomMargin: 7
                readonly property var monitorState: (root.snapshot.monitors || []).find(monitor =>
                    String(monitor.name || "") === String(modelData.name || "")) || null
                readonly property bool fullscreenActive: {
                    if (!monitorState)
                        return false;
                    const activeWorkspace = monitorState.activeWorkspace || {};
                    const specialWorkspace = monitorState.specialWorkspace || {};
                    return (root.snapshot.windows || []).some(window => {
                        const workspaceName = String((window.workspace || {}).name || "");
                        const onVisibleWorkspace = workspaceName === String(activeWorkspace.name || "")
                            || (String(specialWorkspace.name || "") !== ""
                                && workspaceName === String(specialWorkspace.name));
                        return Number(window.monitor) === Number(monitorState.id)
                            && onVisibleWorkspace
                            && Number(window.fullscreen || window.fullscreenClient || 0) >= 2;
                    });
                }
                readonly property bool revealed:
                    !root.launcherOpen && (!fullscreenActive || manualReveal)
                readonly property bool pointerInInteractiveArea:
                    hotspotHover.hovered || dockAreaHover.hovered
                    || contextMenuHover.hovered || chooserHover.hovered

                screen: modelData
                color: "transparent"
                aboveWindows: true
                focusable: false
                exclusiveZone: fullscreenActive ? 0 : 74
                implicitHeight: 380

                WlrLayershell.namespace: "cyberdock"
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

                anchors {
                    left: true
                    right: true
                    bottom: true
                }

                mask: Region {
                    Region { item: hotspot }
                    Region {
                        item: dockWindow.revealed ? dockHitArea : null
                        radius: root.theme.radiusPanel
                    }
                    Region {
                        item: contextMenu.visible ? contextMenu : null
                        radius: root.theme.radiusPanel
                    }
                    Region {
                        item: chooser.visible ? chooser : null
                        radius: root.theme.radiusPanel
                    }
                }

                onPointerInInteractiveAreaChanged: {
                    if (pointerInInteractiveArea)
                        reveal();
                    else
                        scheduleHide();
                }

                function reveal() {
                    hideTimer.stop();
                    manualReveal = true;
                }

                function scheduleHide() {
                    hideTimer.restart();
                }

                function showChooser(app) {
                    clearContextMenu();
                    clearTooltip();
                    chooserTitle = app.name;
                    chooserWindows = root.recentWindows(app.windows);
                    reveal();
                }

                function clearChooser() {
                    chooserWindows = [];
                    chooserTitle = "";
                }

                function showTooltip(app, item) {
                    const point = item.mapToItem(null, item.width / 2, 0);
                    tooltipAppId = app.id;
                    tooltipText = app.unavailable
                        ? app.name + " · Unavailable"
                        : app.name;
                    tooltipCenterX = point.x;
                }

                function clearTooltip(appId) {
                    if (!appId || tooltipAppId === appId) {
                        tooltipAppId = "";
                        tooltipText = "";
                    }
                }

                function showContextMenu(app, item) {
                    const point = item.mapToItem(null, item.width / 2, 0);
                    clearChooser();
                    clearTooltip();
                    menuApp = app;
                    menuCenterX = point.x;
                    reveal();
                }

                function clearContextMenu() {
                    menuApp = null;
                }

                function contextActions() {
                    const app = menuApp;
                    if (!app)
                        return [];

                    if (app.systemControl)
                        return [{"id": "launch", "label": "Open Applications"}];

                    const actions = [];
                    if (app.command && app.command.length > 0) {
                        actions.push({
                            "id": "launch",
                            "label": app.windows && app.windows.length > 0
                                ? "New Window"
                                : "Open"
                        });
                    }
                    if (app.windows && app.windows.length > 0) {
                        actions.push({
                            "id": "show",
                            "label": app.windows.length > 1 ? "Show Windows…" : "Show Window"
                        });
                        if (app.windows.some(window =>
                                /^(kakaotalk(\.exe)?|kakao.*)$/i.test(
                                    root.windowClass(window)))) {
                            actions.push({
                                "id": "repair-kakao-focus",
                                "label": "입력 포커스 복구"
                            });
                        }
                        if (app.windows.some(window => !window.minimized)) {
                            actions.push({
                                "id": "minimize",
                                "label": app.windows.length > 1 ? "Minimize All" : "Minimize"
                            });
                        }
                        actions.push({
                            "id": "close",
                            "label": app.windows.length > 1 ? "Close All Windows" : "Close Window",
                            "destructive": true
                        });
                    }

                    const pinIndex = root.pinPosition(app.desktopId);
                    if (pinIndex >= 0) {
                        actions.push({"id": "unpin", "label": "Unpin from Dock"});
                        if (pinIndex > 0)
                            actions.push({"id": "move-left", "label": "Move Left"});
                        if (pinIndex < root.pinIds.length - 1)
                            actions.push({"id": "move-right", "label": "Move Right"});
                    } else if (app.desktopId) {
                        actions.push({"id": "pin", "label": "Pin to Dock"});
                    }
                    return actions;
                }

                function performContextAction(actionId) {
                    const app = menuApp;
                    clearContextMenu();
                    if (!app)
                        return;

                    if (actionId === "launch") {
                        root.launchApp(app);
                    } else if (actionId === "show") {
                        if (app.windows.length > 1)
                            showChooser(app);
                        else
                            root.activateWindow(app.windows[0].address);
                    } else if (actionId === "minimize") {
                        for (const window of app.windows) {
                            if (!window.minimized)
                                root.minimizeWindow(window.address);
                        }
                    } else if (actionId === "close") {
                        for (const window of app.windows)
                            root.closeWindow(window.address);
                    } else if (actionId === "repair-kakao-focus") {
                        Quickshell.execDetached(["kakaotalk-focus-repair"]);
                    } else if (actionId === "pin") {
                        root.runPinAction(["add", app.desktopId]);
                    } else if (actionId === "unpin") {
                        root.runPinAction(["remove", app.desktopId]);
                    } else if (actionId === "move-left") {
                        const index = root.pinPosition(app.desktopId);
                        if (index > 0) {
                            root.runPinAction([
                                "move", app.desktopId, "--before", root.pinIds[index - 1]
                            ]);
                        }
                    } else if (actionId === "move-right") {
                        const index = root.pinPosition(app.desktopId);
                        if (index >= 0 && index < root.pinIds.length - 1) {
                            root.runPinAction([
                                "move", app.desktopId, "--after", root.pinIds[index + 1]
                            ]);
                        }
                    }
                    refreshSoon.restart();
                }

                function performPrimaryAction(app) {
                    clearContextMenu();
                    const windows = app.windows || [];
                    if (windows.length === 0) {
                        root.launchApp(app);
                    } else if (windows.length > 1) {
                        showChooser(app);
                    } else if (windows[0].address !== root.snapshot.activeAddress) {
                        root.activateWindow(windows[0].address);
                    }
                }

                Timer {
                    id: hideTimer
                    interval: 420
                    repeat: false
                    onTriggered: {
                        if (!dockWindow.pointerInInteractiveArea) {
                            dockWindow.clearChooser();
                            dockWindow.clearContextMenu();
                            dockWindow.clearTooltip();
                            dockWindow.manualReveal = false;
                        }
                    }
                }

                Rectangle {
                    id: hotspot
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: dockSurface.width
                    height: 6
                    color: "transparent"

                    HoverHandler {
                        id: hotspotHover
                        blocking: false
                    }
                }

                Rectangle {
                    id: revealIndicator
                    visible: !root.launcherOpen
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: 42
                    height: 3
                    radius: 1.5
                    color: root.theme.colorSelection
                    opacity: dockWindow.revealed ? 0 : 0.72

                    Behavior on opacity {
                        enabled: !root.reducedMotion
                        NumberAnimation { duration: root.theme.durationDirect }
                    }
                }

                Item {
                    id: dockHitArea
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: dockSurface.width
                    height: dockSurface.height + dockWindow.dockBottomMargin

                    HoverHandler {
                        id: dockAreaHover
                        blocking: false
                    }
                }

                Rectangle {
                    id: dockSurface
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: dockWindow.dockBottomMargin
                    width: Math.min(parent.width - 28, Math.max(72, dockRow.implicitWidth + 24))
                    height: 58
                    radius: root.theme.radiusPanel
                    color: root.theme.colorSurfaceOverlay
                    border.width: 1
                    border.color: root.theme.colorQuietBorder
                    opacity: dockWindow.revealed ? 1 : 0
                    scale: dockWindow.revealed ? 1 : 0.985

                    transform: Translate {
                        y: dockWindow.revealed ? 0 : 13
                        Behavior on y {
                            enabled: !root.reducedMotion
                            NumberAnimation {
                                duration: dockWindow.revealed
                                    ? root.theme.durationEnter
                                    : root.theme.durationExit
                                easing.type: dockWindow.revealed ? Easing.OutCubic : Easing.InCubic
                            }
                        }
                    }

                    Behavior on opacity {
                        enabled: !root.reducedMotion
                        NumberAnimation {
                            duration: dockWindow.revealed
                                ? root.theme.durationStandard
                                : root.theme.durationFast
                        }
                    }
                    Behavior on scale {
                        enabled: !root.reducedMotion
                        NumberAnimation {
                            duration: dockWindow.revealed
                                ? root.theme.durationEnter
                                : root.theme.durationExit
                            easing.type: dockWindow.revealed ? Easing.OutCubic : Easing.InCubic
                        }
                    }

                    Flickable {
                        anchors.fill: parent
                        anchors.margins: 6
                        contentWidth: dockRow.implicitWidth
                        contentHeight: height
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.HorizontalFlick
                        interactive: !dockWindow.pinDragActive
                        clip: true

                        Row {
                            id: dockRow
                            height: parent.height
                            spacing: 8

                            Repeater {
                                model: dockWindow.dockApps

                                delegate: Item {
                                    id: appItem
                                    required property var modelData
                                    readonly property var app: modelData
                                    readonly property bool running: app.windows.length > 0
                                    readonly property bool minimized: app.windows.some(window => window.minimized)
                                    readonly property bool transitioning: app.windows.some(window =>
                                        ["minimizing", "restoring", "closing"]
                                            .includes(String(window.state || "")))
                                    readonly property bool active: app.windows.some(window =>
                                        window.address === root.snapshot.activeAddress)
                                    property real dragOffsetX: 0
                                    property bool dragWasActive: false

                                    width: app.id === "launcher" ? 54 : 44
                                    height: 46
                                    scale: pinDrag.active ? 1.04 : (appMouse.pressed ? 0.97 : 1)
                                    z: pinDrag.active ? 2 : 0

                                    transform: Translate { x: appItem.dragOffsetX }

                                    Accessible.role: Accessible.Button
                                    Accessible.name: app.name
                                    Accessible.description: appItem.minimized
                                        ? "최소화됨, 선택하면 복원"
                                        : (appItem.active
                                        ? "현재 활성화된 애플리케이션"
                                        : (appItem.app.unavailable
                                            ? "현재 설치되어 있지 않은 고정 애플리케이션"
                                            : (appItem.running
                                                ? "실행 중인 애플리케이션"
                                                : "애플리케이션 열기")))
                                    Accessible.pressed: appMouse.pressed
                                    Accessible.onPressAction:
                                        dockWindow.performPrimaryAction(appItem.app)

                                    Behavior on scale {
                                        enabled: !root.reducedMotion
                                        NumberAnimation { duration: root.theme.durationFast }
                                    }

                                    Rectangle {
                                        visible: appItem.app.id === "launcher"
                                        anchors.right: parent.right
                                        anchors.rightMargin: 1
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 1
                                        height: 28
                                        color: root.theme.colorSelectionBorder
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: root.theme.radiusControl
                                        color: pinDrag.active
                                            ? root.theme.colorSelectionSoft
                                            : (appMouse.containsMouse
                                            ? root.theme.colorFocusHover
                                            : (appItem.active
                                                ? root.theme.colorFocusSelected
                                                : "transparent"))
                                        border.width: pinDrag.active || appItem.active ? 1 : 0
                                        border.color: pinDrag.active
                                            ? root.theme.colorFocus
                                            : root.theme.colorSelectionBorder
                                    }

                                    IconImage {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.top: parent.top
                                        anchors.topMargin: 4
                                        implicitWidth: 29
                                        implicitHeight: 29
                                        source: Quickshell.iconPath(appItem.app.icon,
                                            "application-x-executable")
                                        opacity: appItem.app.unavailable
                                            ? 0.38
                                            : (appItem.minimized ? 0.62 : 1)
                                        scale: appMouse.containsMouse ? 1.09 : 1
                                        Behavior on scale {
                                            enabled: !root.reducedMotion
                                            NumberAnimation { duration: root.theme.durationFast }
                                        }
                                    }

                                    Item {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        anchors.leftMargin: 7
                                        anchors.rightMargin: 7
                                        anchors.bottomMargin: 1
                                        height: 3
                                        visible: appItem.running

                                        Rectangle {
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: appItem.active ? parent.width
                                                : (appItem.app.windows.length > 1 ? 22 : 14)
                                            height: appItem.active ? 2 : 1
                                            radius: 1
                                            color: appItem.active
                                                ? root.theme.colorFocus
                                                : root.theme.colorSelection

                                            Behavior on width {
                                                enabled: !root.reducedMotion
                                                NumberAnimation { duration: root.theme.durationDirect }
                                            }
                                        }

                                        Row {
                                            visible: appItem.minimized
                                            anchors.centerIn: parent
                                            spacing: 2

                                            Repeater {
                                                model: 3
                                                Rectangle {
                                                    required property int index
                                                    width: index === 1 ? 7 : 4
                                                    height: 2
                                                    radius: 1
                                                    color: root.theme.colorAccent
                                                }
                                            }
                                        }

                                        Rectangle {
                                            visible: appItem.transitioning
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 3
                                            height: 3
                                            radius: 1.5
                                            color: root.theme.colorWarning

                                            SequentialAnimation on opacity {
                                                running: appItem.transitioning && !root.reducedMotion
                                                loops: Animation.Infinite
                                                NumberAnimation { to: 0.32; duration: root.theme.durationStandard }
                                                NumberAnimation { to: 1; duration: root.theme.durationStandard }
                                            }
                                        }

                                        Behavior on opacity {
                                            enabled: !root.reducedMotion
                                            NumberAnimation { duration: root.theme.durationFast }
                                        }
                                    }

                                    Rectangle {
                                        visible: appItem.app.windows.length > 1
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        width: appItem.app.windows.length > 9 ? 20 : 15
                                        height: 15
                                        radius: 7.5
                                        color: root.theme.colorSelectionStrong

                                        Text {
                                            anchors.centerIn: parent
                                            text: appItem.app.windows.length > 9
                                                ? "9+"
                                                : appItem.app.windows.length
                                            color: root.theme.colorOnSelection
                                            font.family: "Pretendard"
                                            font.pixelSize: 11
                                            font.bold: true
                                        }
                                    }

                                    MouseArea {
                                        id: appMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onEntered: dockWindow.showTooltip(appItem.app, appItem)
                                        onExited: dockWindow.clearTooltip(appItem.app.id)
                                        onClicked: mouse => {
                                            if (mouse.button === Qt.RightButton) {
                                                dockWindow.showContextMenu(appItem.app, appItem);
                                            } else {
                                                dockWindow.performPrimaryAction(appItem.app);
                                            }
                                        }
                                    }

                                    DragHandler {
                                        id: pinDrag
                                        enabled: appItem.app.pinned
                                            && !appItem.app.systemControl
                                        target: null
                                        acceptedButtons: Qt.LeftButton
                                        xAxis.enabled: true
                                        yAxis.enabled: false
                                        grabPermissions: PointerHandler.CanTakeOverFromItems
                                            | PointerHandler.ApprovesTakeOverByAnything

                                        onTranslationChanged: {
                                            if (active)
                                                appItem.dragOffsetX = activeTranslation.x;
                                        }
                                        onActiveChanged: {
                                            if (active) {
                                                appItem.dragWasActive = true;
                                                dockWindow.pinDragActive = true;
                                                dockWindow.hideTimer.stop();
                                                dockWindow.clearContextMenu();
                                                dockWindow.clearTooltip();
                                            } else if (appItem.dragWasActive) {
                                                root.reorderPinnedFromDrag(
                                                    appItem.app.desktopId,
                                                    appItem.dragOffsetX,
                                                    appItem.width + dockRow.spacing);
                                                appItem.dragOffsetX = 0;
                                                appItem.dragWasActive = false;
                                                dockWindow.pinDragActive = false;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: appTooltip
                    visible: dockWindow.tooltipText !== ""
                        && !contextMenu.visible && !chooser.visible
                    x: Math.max(8, Math.min(parent.width - width - 8,
                        dockWindow.tooltipCenterX - width / 2))
                    anchors.bottom: dockSurface.top
                    anchors.bottomMargin: 8
                    width: Math.min(parent.width - 16, tooltipLabel.implicitWidth + 22)
                    height: 32
                    radius: root.theme.radiusSmall
                    color: root.theme.colorCanvasOverlay
                    border.width: 1
                    border.color: root.theme.colorFocusBorder
                    opacity: visible ? 1 : 0
                    z: 12

                    Behavior on opacity {
                        enabled: !root.reducedMotion
                        NumberAnimation { duration: root.theme.durationInstant }
                    }

                    Text {
                        id: tooltipLabel
                        anchors.fill: parent
                        anchors.leftMargin: 11
                        anchors.rightMargin: 11
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: dockWindow.tooltipText
                        color: root.theme.colorText
                        font.family: "Pretendard"
                        font.pixelSize: 12
                        font.bold: true
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    id: contextMenu
                    visible: dockWindow.menuApp !== null
                    x: Math.max(8, Math.min(parent.width - width - 8,
                        dockWindow.menuCenterX - width / 2))
                    anchors.bottom: dockSurface.top
                    anchors.bottomMargin: 10
                    width: 244
                    height: contextColumn.implicitHeight + 16
                    radius: root.theme.radiusPanel
                    color: root.theme.colorRaisedOverlay
                    border.width: 1
                    border.color: root.theme.colorSelectionBorder
                    z: 14

                    HoverHandler {
                        id: contextMenuHover
                        blocking: false
                    }

                    Column {
                        id: contextColumn
                        x: 8
                        y: 8
                        width: parent.width - 16
                        spacing: 3

                        Text {
                            width: parent.width
                            height: 34
                            verticalAlignment: Text.AlignVCenter
                            leftPadding: 8
                            rightPadding: 8
                            text: dockWindow.menuApp ? dockWindow.menuApp.name : ""
                            color: root.theme.colorFocus
                            font.family: "Pretendard"
                            font.pixelSize: 13
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: root.theme.colorSelectionBorder
                        }

                        Repeater {
                            model: dockWindow.contextActions()

                            delegate: Rectangle {
                                required property var modelData
                                width: contextColumn.width
                                height: 40
                                radius: root.theme.radiusSmall
                                color: contextActionMouse.pressed
                                    ? root.theme.colorFocusSelected
                                    : (contextActionMouse.containsMouse
                                        ? root.theme.colorFocusHover
                                        : "transparent")

                                Accessible.role: Accessible.Button
                                Accessible.name: modelData.label
                                Accessible.pressed: contextActionMouse.pressed
                                Accessible.onPressAction:
                                    dockWindow.performContextAction(modelData.id)

                                Text {
                                    anchors.fill: parent
                                    anchors.leftMargin: 9
                                    anchors.rightMargin: 9
                                    verticalAlignment: Text.AlignVCenter
                                    text: modelData.label
                                    color: modelData.destructive
                                        ? root.theme.colorCritical
                                        : root.theme.colorText
                                    font.family: "Pretendard"
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                }

                                MouseArea {
                                    id: contextActionMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: dockWindow.performContextAction(modelData.id)
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: chooser
                    visible: chooserWindows.length > 1
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: dockSurface.top
                    anchors.bottomMargin: 10
                    width: visible ? Math.min(parent.width - 32, 420) : 0
                    height: visible ? Math.min(258, chooserList.contentHeight + 48) : 0
                    radius: root.theme.radiusPanel
                    color: root.theme.colorRaisedOverlay
                    border.width: 1
                    border.color: root.theme.colorSelectionBorder
                    clip: true

                    HoverHandler {
                        id: chooserHover
                        blocking: false
                    }

                    Text {
                        id: chooserHeading
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 12
                        text: dockWindow.chooserTitle
                        color: root.theme.colorFocus
                        font.family: "Pretendard"
                        font.pixelSize: 14
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    ListView {
                        id: chooserList
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: chooserHeading.bottom
                        anchors.bottom: parent.bottom
                        anchors.margins: 8
                        spacing: 4
                        clip: true
                        model: dockWindow.chooserWindows

                        delegate: Rectangle {
                            required property var modelData
                            width: ListView.view.width
                            height: 42
                            radius: root.theme.radiusControl
                            color: chooserItemMouse.pressed
                                ? root.theme.colorFocusSelected
                                : (chooserItemMouse.containsMouse
                                    ? root.theme.colorFocusHover
                                    : root.theme.colorSurfaceSubtle)

                            Accessible.role: Accessible.Button
                            Accessible.name: root.windowTitle(modelData)
                            Accessible.description: stateLabel.text
                            Accessible.pressed: chooserItemMouse.pressed
                            Accessible.onPressAction: {
                                root.activateWindow(modelData.address);
                                dockWindow.clearChooser();
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.right: stateLabel.left
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 10
                                anchors.rightMargin: 8
                                text: root.windowTitle(modelData)
                                color: root.theme.colorText
                                font.family: "Pretendard"
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }

                            Text {
                                id: stateLabel
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.rightMargin: 10
                                text: modelData.minimized
                                    ? "MINIMIZED"
                                    : String(modelData.workspace && modelData.workspace.name || "")
                                color: modelData.minimized
                                    ? root.theme.colorAccent
                                    : root.theme.colorInfo
                                font.family: "Pretendard"
                                font.pixelSize: 10
                                font.bold: true
                            }

                            MouseArea {
                                id: chooserItemMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    root.activateWindow(modelData.address);
                                    dockWindow.clearChooser();
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: EnoshimaWindowMenu {
            required property var modelData
            targetScreen: modelData
            menuOpen: root.windowMenuOpen
            activeScreenName: root.windowMenuScreenName
            targetAddress: root.windowMenuAddress
            targetWindow: root.windowByAddress(root.windowMenuAddress)
            anchorX: root.windowMenuAnchorX
            anchorY: root.windowMenuAnchorY
            invocationSource: root.windowMenuSource
            theme: root.theme
            reducedMotion: root.reducedMotion
            onCloseRequested: root.windowMenuOpen = false
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: EnoshimaSnapAssist {
            required property var modelData
            targetScreen: modelData
            snapState: root.snapState
            theme: root.theme
            reducedMotion: root.reducedMotion
            reducedTransparency: root.reducedTransparency
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: PowerMenu {
            required property var modelData
            targetScreen: modelData
            menuOpen: root.powerMenuOpen
            activeScreenName: root.powerMenuScreenName
            theme: root.theme
            reducedMotion: root.reducedMotion
            onCloseRequested: root.powerMenuOpen = false
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: FocusSentinel {
            required property var modelData
            targetScreen: modelData
            pulseActive: root.kakaoFocusPulseActive
            activeScreenName: root.kakaoFocusScreenName
            targetAddress: root.kakaoFocusTargetAddress
            onPulseCompleted: root.kakaoFocusPulseActive = false
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: DisplayModeOverlay {
            required property var modelData
            targetScreen: modelData
            overlayOpen: root.displayOverlayOpen
            activeScreenName: root.displayOverlayScreenName
            theme: root.theme
            reducedMotion: root.reducedMotion
            onCloseRequested: root.displayOverlayOpen = false
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: CyberLauncher {
            required property var modelData
            targetScreen: modelData
            launcherOpen: root.launcherOpen
            activeScreenName: root.launcherScreenName
            theme: root.theme
            reducedMotion: root.reducedMotion
            pinIds: root.pinIds
            onCloseRequested: root.launcherOpen = false
            onPinsChanged: root.schedulePinsRefresh()
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: CyberOsd {
            required property var modelData
            targetScreen: modelData
            osdVisible: root.osdVisible
            activeScreenName: root.osdScreenName
            osdKind: root.osdKind
            osdValue: root.osdValue
            osdMuted: root.osdMuted
            theme: root.theme
            reducedMotion: root.reducedMotion
        }
    }
}
