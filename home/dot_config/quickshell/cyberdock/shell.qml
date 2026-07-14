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
                readonly property int dockBottomMargin: 10

                screen: modelData
                color: "transparent"
                aboveWindows: true
                focusable: false
                exclusiveZone: 0
                implicitHeight: revealed ? (chooser.visible ? 322 : 102) : 1

                anchors {
                    left: true
                    right: true
                    bottom: true
                }

                mask: Region {
                    Region { item: hotspot }
                    Region { item: dockHitArea; radius: 18 }
                    Region { item: chooser; radius: 16 }
                }

                HoverHandler {
                    id: panelHover
                    blocking: false
                    onHoveredChanged: {
                        if (hovered)
                            dockWindow.reveal();
                        else
                            dockWindow.scheduleHide();
                    }
                }

                Behavior on implicitHeight {
                    NumberAnimation { duration: 170; easing.type: Easing.OutCubic }
                }

                function reveal() {
                    hideTimer.stop();
                    revealed = true;
                }

                function scheduleHide() {
                    hideTimer.restart();
                }

                function showChooser(app) {
                    chooserTitle = app.name;
                    chooserWindows = root.recentWindows(app.windows);
                    reveal();
                }

                function clearChooser() {
                    chooserWindows = [];
                    chooserTitle = "";
                }

                Timer {
                    id: hideTimer
                    interval: 360
                    repeat: false
                    onTriggered: {
                        if (!panelHover.hovered) {
                            dockWindow.clearChooser();
                            dockWindow.revealed = false;
                        }
                    }
                }

                Rectangle {
                    id: hotspot
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: "transparent"
                }

                Item {
                    id: dockHitArea
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: dockSurface.width
                    height: dockSurface.height + dockWindow.dockBottomMargin
                }

                Rectangle {
                    id: dockSurface
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: dockWindow.dockBottomMargin
                    width: Math.min(parent.width - 24, Math.max(96, dockRow.implicitWidth + 24))
                    height: 78
                    radius: 18
                    color: "#ee111447"
                    border.width: 1
                    border.color: "#cc33d6ff"
                    opacity: dockWindow.revealed ? 1 : 0
                    scale: dockWindow.revealed ? 1 : 0.96

                    Behavior on opacity { NumberAnimation { duration: 130 } }
                    Behavior on scale { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

                    Flickable {
                        anchors.fill: parent
                        anchors.margins: 10
                        contentWidth: dockRow.implicitWidth
                        contentHeight: height
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.HorizontalFlick
                        clip: true

                        Row {
                            id: dockRow
                            height: parent.height
                            spacing: 6

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

                                    width: 52
                                    height: 58

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 13
                                        color: appMouse.containsMouse
                                            ? "#448b5cff"
                                            : (appItem.active ? "#338b5cff" : "transparent")
                                        border.width: appItem.active ? 1 : 0
                                        border.color: "#ff8b5cff"
                                    }

                                    IconImage {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.top: parent.top
                                        anchors.topMargin: 5
                                        implicitWidth: 38
                                        implicitHeight: 38
                                        source: Quickshell.iconPath(appItem.app.icon,
                                            "application-x-executable")
                                        opacity: appItem.minimized ? 0.62 : 1
                                        scale: appMouse.containsMouse ? 1.09 : 1
                                        Behavior on scale { NumberAnimation { duration: 110 } }
                                    }

                                    Rectangle {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 2
                                        width: appItem.running ? (appItem.active ? 18 : 8) : 0
                                        height: 3
                                        radius: 2
                                        color: appItem.minimized ? "#ff3cc7" : "#33d6ff"
                                        Behavior on width { NumberAnimation { duration: 120 } }
                                    }

                                    Rectangle {
                                        visible: appItem.app.windows.length > 1
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        width: 18
                                        height: 18
                                        radius: 9
                                        color: "#ff8b5cff"

                                        Text {
                                            anchors.centerIn: parent
                                            text: appItem.app.windows.length
                                            color: "#e9e8ff"
                                            font.family: "Pretendard"
                                            font.pixelSize: 10
                                            font.bold: true
                                        }
                                    }

                                    MouseArea {
                                        id: appMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: {
                                            if (!appItem.running) {
                                                root.launchApp(appItem.app);
                                            } else if (appItem.app.windows.length > 1) {
                                                dockWindow.showChooser(appItem.app);
                                            } else {
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
