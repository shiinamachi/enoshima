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
    property bool osdVisible: false
    property string osdScreenName: ""
    property string osdKind: "volume"
    property int osdValue: 0
    property bool osdMuted: false

    // Semantic colors mirror the shared GTK palette while keeping QML free
    // from a runtime file parser. Tests guard these values against drift.
    readonly property color colorCanvasOverlay: "#f2050623"
    readonly property color colorSurfaceOverlay: "#f20a0c3e"
    readonly property color colorRaisedOverlay: "#cc161151"
    readonly property color colorFocus: "#62d8ff"
    readonly property color colorFocusBorder: "#cc62d8ff"
    readonly property color colorFocusHover: "#4462d8ff"
    readonly property color colorFocusSelected: "#3362d8ff"
    readonly property color colorSelection: "#9a5cff"
    readonly property color colorSelectionBorder: "#cc9a5cff"
    readonly property color colorSelectionStrong: "#ff9a5cff"
    readonly property color colorAccent: "#e56bff"
    readonly property color colorText: "#f2ecff"
    readonly property color colorInfo: "#6d8cff"
    readonly property color colorCritical: "#ff5d8f"

    readonly property var pinnedApps: [
        {
            "id": "ghostty",
            "name": "Ghostty",
            "icon": "com.mitchellh.ghostty",
            "command": ["ghostty"],
            "pattern": "^(com\\.mitchellh\\.ghostty|ghostty)$"
        },
        {
            "id": "thunar",
            "name": "Files",
            "icon": "org.xfce.thunar",
            "command": ["thunar"],
            "pattern": "^(thunar)$"
        },
        {
            "id": "zed",
            "name": "Zed",
            "icon": "zed",
            "command": ["zeditor"],
            "pattern": "^(dev\\.zed\\.zed|zed)$"
        },
        {
            "id": "chrome",
            "name": "Google Chrome",
            "icon": "google-chrome",
            "command": ["google-chrome-stable"],
            "pattern": "^(google-chrome(-stable)?|com\\.google\\.chrome)$"
        },
        {
            "id": "launcher",
            "name": "Applications",
            "icon": "view-app-grid-symbolic",
            "command": [Quickshell.env("HOME") + "/.local/bin/cyberlauncher-toggle"],
            "pattern": "a^"
        }
    ]

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
        target: "osd"

        function show(kind: string, value: int, muted: bool): void {
            root.showOsd(kind, value, muted);
        }
    }

    Timer {
        id: osdHideTimer
        interval: 1400
        repeat: false
        onTriggered: root.osdVisible = false
    }

    function windowClass(window) {
        return String(window.initialClass || window.class || "");
    }

    function pinnedIndex(window) {
        const candidate = windowClass(window);
        for (let index = 0; index < pinnedApps.length; ++index) {
            if (new RegExp(pinnedApps[index].pattern, "i").test(candidate))
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
            "icon": entry && entry.icon ? entry.icon : "application-x-executable"
        };
    }

    function buildDockApps() {
        const groups = pinnedApps.map(app => ({
            "id": app.id,
            "name": app.name,
            "icon": app.icon,
            "command": app.command,
            "pinned": true,
            "windows": []
        }));
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
                    "name": metadata.name,
                    "icon": metadata.icon,
                    "command": [],
                    "pinned": false,
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
        return groups.concat(runningOnly);
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
                    if (next.version === 1)
                        root.snapshot = next;
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
                    Region { item: dockWindow.revealed ? dockHitArea : null; radius: 13 }
                    Region { item: contextMenu.visible ? contextMenu : null; radius: 16 }
                    Region { item: chooser.visible ? chooser : null; radius: 16 }
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
                    tooltipText = app.name;
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

                    if (!app.windows || app.windows.length === 0)
                        return [{"id": "launch", "label": "Open"}];

                    const actions = [];
                    if (app.command && app.command.length > 0)
                        actions.push({"id": "launch", "label": "New Window"});
                    actions.push({
                        "id": "show",
                        "label": app.windows.length > 1 ? "Show Windows…" : "Show Window"
                    });
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
                    }
                    refreshSoon.restart();
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
                    color: root.colorSelection
                    opacity: dockWindow.revealed ? 0 : 0.72

                    Behavior on opacity { NumberAnimation { duration: 120 } }
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
                    width: Math.min(parent.width - 17, Math.max(68, dockRow.implicitWidth + 17))
                    height: 58
                    radius: 15
                    color: root.colorSurfaceOverlay
                    border.width: 1
                    border.color: root.colorFocusBorder
                    opacity: dockWindow.revealed ? 1 : 0
                    scale: dockWindow.revealed ? 1 : 0.985

                    transform: Translate {
                        y: dockWindow.revealed ? 0 : 13
                        Behavior on y {
                            NumberAnimation {
                                duration: dockWindow.revealed ? 190 : 145
                                easing.type: dockWindow.revealed ? Easing.OutCubic : Easing.InCubic
                            }
                        }
                    }

                    Behavior on opacity {
                        NumberAnimation { duration: dockWindow.revealed ? 150 : 115 }
                    }
                    Behavior on scale {
                        NumberAnimation {
                            duration: dockWindow.revealed ? 190 : 145
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
                        clip: true

                        Row {
                            id: dockRow
                            height: parent.height
                            spacing: 5

                            Repeater {
                                model: dockWindow.dockApps

                                delegate: Item {
                                    id: appItem
                                    required property var modelData
                                    readonly property var app: modelData
                                    readonly property bool running: app.windows.length > 0
                                    readonly property bool minimized: app.windows.some(window => window.minimized)
                                    readonly property bool active: app.windows.some(window =>
                                        window.address === root.snapshot.activeAddress)

                                    width: app.id === "launcher" ? 54 : 44
                                    height: 46

                                    Rectangle {
                                        visible: appItem.app.id === "launcher"
                                        anchors.right: parent.right
                                        anchors.rightMargin: 1
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 1
                                        height: 28
                                        color: root.colorSelectionBorder
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 11
                                        color: appMouse.containsMouse
                                            ? root.colorFocusHover
                                            : (appItem.active ? root.colorFocusSelected : "transparent")
                                        border.width: appItem.active ? 1 : 0
                                        border.color: root.colorSelectionStrong
                                    }

                                    IconImage {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.top: parent.top
                                        anchors.topMargin: 4
                                        implicitWidth: 29
                                        implicitHeight: 29
                                        source: Quickshell.iconPath(appItem.app.icon,
                                            "application-x-executable")
                                        opacity: appItem.minimized ? 0.62 : 1
                                        scale: appMouse.containsMouse ? 1.09 : 1
                                        Behavior on scale { NumberAnimation { duration: 110 } }
                                    }

                                    Rectangle {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 1.5
                                        width: appItem.running ? (appItem.active ? 16 : 7) : 0
                                        height: 3
                                        radius: 1.5
                                        color: appItem.minimized ? root.colorAccent : root.colorFocus
                                        Behavior on width { NumberAnimation { duration: 120 } }
                                    }

                                    Rectangle {
                                        visible: appItem.app.windows.length > 1
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        width: 15
                                        height: 15
                                        radius: 7.5
                                        color: root.colorSelectionStrong

                                        Text {
                                            anchors.centerIn: parent
                                            text: appItem.app.windows.length
                                            color: root.colorText
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
                                            } else if (!appItem.running) {
                                                dockWindow.clearContextMenu();
                                                root.launchApp(appItem.app);
                                            } else if (appItem.app.windows.length > 1) {
                                                dockWindow.showChooser(appItem.app);
                                            } else {
                                                dockWindow.clearContextMenu();
                                                root.activateWindow(appItem.app.windows[0].address);
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
                    radius: 9
                    color: root.colorCanvasOverlay
                    border.width: 1
                    border.color: root.colorFocusBorder
                    opacity: visible ? 1 : 0
                    z: 12

                    Behavior on opacity { NumberAnimation { duration: 90 } }

                    Text {
                        id: tooltipLabel
                        anchors.centerIn: parent
                        text: dockWindow.tooltipText
                        color: root.colorText
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
                    radius: 14
                    color: root.colorCanvasOverlay
                    border.width: 1
                    border.color: root.colorSelectionBorder
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
                            color: root.colorFocus
                            font.family: "Pretendard"
                            font.pixelSize: 13
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: root.colorSelectionBorder
                        }

                        Repeater {
                            model: dockWindow.contextActions()

                            delegate: Rectangle {
                                required property var modelData
                                width: contextColumn.width
                                height: 40
                                radius: 9
                                color: contextActionMouse.containsMouse ? root.colorFocusHover : "transparent"

                                Text {
                                    anchors.fill: parent
                                    anchors.leftMargin: 9
                                    anchors.rightMargin: 9
                                    verticalAlignment: Text.AlignVCenter
                                    text: modelData.label
                                    color: modelData.destructive ? root.colorCritical : root.colorText
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
                    radius: 16
                    color: root.colorCanvasOverlay
                    border.width: 1
                    border.color: root.colorSelectionBorder
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
                        color: root.colorFocus
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
                            radius: 10
                            color: chooserItemMouse.containsMouse
                                ? root.colorFocusHover : root.colorRaisedOverlay

                            Text {
                                anchors.left: parent.left
                                anchors.right: stateLabel.left
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 10
                                anchors.rightMargin: 8
                                text: root.windowTitle(modelData)
                                color: root.colorText
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
                                color: modelData.minimized ? root.colorAccent : root.colorInfo
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

        delegate: CyberLauncher {
            required property var modelData
            targetScreen: modelData
            launcherOpen: root.launcherOpen
            activeScreenName: root.launcherScreenName
            onCloseRequested: root.launcherOpen = false
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
        }
    }
}
