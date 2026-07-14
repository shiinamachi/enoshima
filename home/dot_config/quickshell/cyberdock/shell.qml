//@ pragma IconTheme Papirus

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Widgets

ShellRoot {
    id: root

    property var snapshot: ({
        "activeAddress": "",
        "monitors": [],
        "windows": []
    })

    readonly property var pinnedApps: [
        {
            "id": "thunar",
            "name": "Thunar",
            "icon": "org.xfce.thunar",
            "command": ["thunar"],
            "pattern": "^(thunar)$"
        },
        {
            "id": "chrome",
            "name": "Google Chrome",
            "icon": "google-chrome",
            "command": ["google-chrome-stable"],
            "pattern": "^(google-chrome(-stable)?|com\\.google\\.chrome)$"
        },
        {
            "id": "ghostty",
            "name": "Ghostty",
            "icon": "com.mitchellh.ghostty",
            "command": ["ghostty"],
            "pattern": "^(com\\.mitchellh\\.ghostty|ghostty)$"
        },
        {
            "id": "zed",
            "name": "Zed",
            "icon": "zed",
            "command": ["zeditor"],
            "pattern": "^(dev\\.zed\\.zed|zed)$"
        },
        {
            "id": "kakaotalk",
            "name": "KakaoTalk",
            "icon": "com.usebottles.bottles",
            "command": [Quickshell.env("HOME") + "/.local/bin/kakaotalk"],
            "pattern": "^(kakaotalk(\\.exe)?|kakao.*)$"
        },
        {
            "id": "thunderbird",
            "name": "Thunderbird",
            "icon": "thunderbird",
            "command": ["thunderbird-wayland"],
            "pattern": "^(thunderbird|org\\.mozilla\\.thunderbird)$"
        },
        {
            "id": "obsidian",
            "name": "Obsidian",
            "icon": "obsidian",
            "command": ["obsidian"],
            "pattern": "^(obsidian|md\\.obsidian)$"
        },
        {
            "id": "bottles",
            "name": "Bottles",
            "icon": "com.usebottles.bottles",
            "command": ["flatpak", "run", "com.usebottles.bottles"],
            "pattern": "^(com\\.usebottles\\.bottles|bottles)$"
        },
        {
            "id": "photogimp",
            "name": "PhotoGIMP",
            "icon": "gimp",
            "command": ["photogimp"],
            "pattern": "^(photogimp|gimp(-[0-9.]+)?)$"
        },
        {
            "id": "onlyoffice",
            "name": "ONLYOFFICE",
            "icon": "onlyoffice-desktopeditors",
            "command": ["onlyoffice-desktopeditors"],
            "pattern": "^(onlyoffice.*|desktopeditors)$"
        },
        {
            "id": "rhwp",
            "name": "RHWP Desktop",
            "icon": "rhwp-desktop",
            "command": ["rhwp-desktop"],
            "pattern": "^(rhwp(-desktop)?|.*rhwp.*)$"
        }
    ]

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
            PanelWindow {
                id: dockWindow

                required property var modelData
                property bool revealed: false
                property var chooserWindows: []
                property string chooserTitle: ""
                property var dockApps: root.buildDockApps()
                property string tooltipAppId: ""
                property string tooltipText: ""
                property real tooltipCenterX: width / 2
                property var menuApp: null
                property real menuCenterX: width / 2
                readonly property int dockBottomMargin: 7
                readonly property bool pointerInInteractiveArea:
                    hotspotHover.hovered || dockAreaHover.hovered
                    || contextMenuHover.hovered || chooserHover.hovered

                screen: modelData
                color: "transparent"
                aboveWindows: true
                focusable: false
                exclusiveZone: 0
                implicitHeight: 380

                anchors {
                    left: true
                    right: true
                    bottom: true
                }

                mask: Region {
                    Region { item: hotspot }
                    Region { item: dockHitArea; radius: 13 }
                    Region { item: contextMenu; radius: 16 }
                    Region { item: chooser; radius: 16 }
                }

                onPointerInInteractiveAreaChanged: {
                    if (pointerInInteractiveArea)
                        reveal();
                    else
                        scheduleHide();
                }

                function reveal() {
                    hideTimer.stop();
                    revealed = true;
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
                    interval: 280
                    repeat: false
                    onTriggered: {
                        if (!dockWindow.pointerInInteractiveArea) {
                            dockWindow.clearChooser();
                            dockWindow.clearContextMenu();
                            dockWindow.clearTooltip();
                            dockWindow.revealed = false;
                        }
                    }
                }

                Rectangle {
                    id: hotspot
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: dockSurface.width
                    height: 1
                    color: "transparent"

                    HoverHandler {
                        id: hotspotHover
                        blocking: false
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
                    width: Math.min(parent.width - 17, Math.max(68, dockRow.implicitWidth + 17))
                    height: 51
                    radius: 13
                    color: "#ee111447"
                    border.width: 1
                    border.color: "#cc33d6ff"
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

                                    width: 34
                                    height: 40

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 11
                                        color: appMouse.containsMouse
                                            ? "#448b5cff"
                                            : (appItem.active ? "#338b5cff" : "transparent")
                                        border.width: appItem.active ? 1 : 0
                                        border.color: "#ff8b5cff"
                                    }

                                    IconImage {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.top: parent.top
                                        anchors.topMargin: 4
                                        implicitWidth: 26
                                        implicitHeight: 26
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
                                        width: appItem.running ? (appItem.active ? 13 : 6) : 0
                                        height: 2
                                        radius: 1
                                        color: appItem.minimized ? "#ff3cc7" : "#33d6ff"
                                        Behavior on width { NumberAnimation { duration: 120 } }
                                    }

                                    Rectangle {
                                        visible: appItem.app.windows.length > 1
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        width: 15
                                        height: 15
                                        radius: 7.5
                                        color: "#ff8b5cff"

                                        Text {
                                            anchors.centerIn: parent
                                            text: appItem.app.windows.length
                                            color: "#e9e8ff"
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
                    color: "#f2070b2a"
                    border.width: 1
                    border.color: "#aa33d6ff"
                    opacity: visible ? 1 : 0
                    z: 12

                    Behavior on opacity { NumberAnimation { duration: 90 } }

                    Text {
                        id: tooltipLabel
                        anchors.centerIn: parent
                        text: dockWindow.tooltipText
                        color: "#e9e8ff"
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
                    color: "#f2070b2a"
                    border.width: 1
                    border.color: "#cc8b5cff"
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
                            color: "#33d6ff"
                            font.family: "Pretendard"
                            font.pixelSize: 13
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: "#558b5cff"
                        }

                        Repeater {
                            model: dockWindow.contextActions()

                            delegate: Rectangle {
                                required property var modelData
                                width: contextColumn.width
                                height: 36
                                radius: 9
                                color: contextActionMouse.containsMouse ? "#448b5cff" : "transparent"

                                Text {
                                    anchors.fill: parent
                                    anchors.leftMargin: 9
                                    anchors.rightMargin: 9
                                    verticalAlignment: Text.AlignVCenter
                                    text: modelData.label
                                    color: modelData.destructive ? "#ff7abf" : "#e9e8ff"
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
                    color: "#f2070b2a"
                    border.width: 1
                    border.color: "#ccff3cc7"
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
                        color: "#33d6ff"
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
                            color: chooserItemMouse.containsMouse ? "#448b5cff" : "#cc111447"

                            Text {
                                anchors.left: parent.left
                                anchors.right: stateLabel.left
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 10
                                anchors.rightMargin: 8
                                text: root.windowTitle(modelData)
                                color: "#e9e8ff"
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
                                color: modelData.minimized ? "#ff3cc7" : "#8b5cff"
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
}
