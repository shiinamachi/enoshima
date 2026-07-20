pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets

// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: menu

    required property var targetScreen
    required property bool menuOpen
    required property string activeScreenName
    required property string targetAddress
    required property var targetWindow
    required property int anchorX
    required property int anchorY
    required property string invocationSource
    required property var theme
    required property bool reducedMotion

    signal closeRequested()

    property int selectedIndex: 0
    property string adjustmentMode: ""
    property var originalGeometry: null
    readonly property bool koreanLocale:
        String(Quickshell.env("LANG") || "").toLowerCase().startsWith("ko")
    readonly property bool showing: menuOpen
        && targetScreen.name === activeScreenName
        && /^0x[0-9A-Fa-f]+$/.test(targetAddress)
        && Object.keys(targetWindow || {}).length > 0
    readonly property var entries: [
        {"id": "restore", "ko": "복원", "en": "Restore", "icon": "window-restore-symbolic", "key": "R"},
        {"id": "move", "ko": "이동", "en": "Move", "icon": "transform-move-symbolic", "key": "M"},
        {"id": "resize", "ko": "크기 조절", "en": "Resize", "icon": "transform-scale-symbolic", "key": "S"},
        {"id": "minimize", "ko": "최소화", "en": "Minimize", "icon": "window-minimize-symbolic", "key": "N"},
        {"id": "maximize", "ko": "최대화", "en": "Maximize", "icon": "window-maximize-symbolic", "key": "X"},
        {"id": "close", "ko": "닫기", "en": "Close", "icon": "window-close-symbolic", "key": "Alt+F4"}
    ]

    screen: targetScreen
    visible: showing
    color: "transparent"
    aboveWindows: true
    focusable: showing
    exclusiveZone: 0

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    WlrLayershell.namespace: "enoshima-window-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: showing
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    mask: Region { item: menu.showing ? scrimInput : null }

    onShowingChanged: {
        if (showing) {
            selectedIndex = 0;
            adjustmentMode = "";
            originalGeometry = null;
            Qt.callLater(() => scrimInput.forceActiveFocus());
        }
    }

    onTargetWindowChanged: {
        if (menuOpen && Object.keys(targetWindow || {}).length === 0)
            closeRequested();
    }

    function labelFor(entry) {
        return koreanLocale ? entry.ko : entry.en;
    }

    function isFullscreen() {
        return Number(targetWindow.fullscreen || targetWindow.fullscreenClient || 0) > 0;
    }

    function entryEnabled(entry) {
        if (entry.id === "restore")
            return isFullscreen();
        if (entry.id === "maximize")
            return !isFullscreen();
        if (entry.id === "move" || entry.id === "resize")
            return !isFullscreen();
        return true;
    }

    function captureGeometry() {
        const position = targetWindow.at || [0, 0];
        const size = targetWindow.size || [640, 480];
        return {
            "x": Number(position[0] || 0),
            "y": Number(position[1] || 0),
            "width": Math.max(1, Number(size[0] || 640)),
            "height": Math.max(1, Number(size[1] || 480)),
            "floating": Boolean(targetWindow.floating),
            "fullscreen": Number(targetWindow.fullscreen || 0),
            "fullscreenClient": Number(targetWindow.fullscreenClient
                || targetWindow.fullscreen || 0)
        };
    }

    function finishAdjustment(commit) {
        if (!commit && originalGeometry) {
            Quickshell.execDetached([
                "desktop-window-action", "restore-geometry",
                "--address", targetAddress,
                "--x", String(originalGeometry.x),
                "--y", String(originalGeometry.y),
                "--width", String(originalGeometry.width),
                "--height", String(originalGeometry.height),
                "--floating", originalGeometry.floating ? "true" : "false",
                "--fullscreen", String(originalGeometry.fullscreen),
                "--fullscreen-client", String(originalGeometry.fullscreenClient)
            ]);
        }
        adjustmentMode = "";
        originalGeometry = null;
        closeRequested();
    }

    function dismiss() {
        if (adjustmentMode !== "")
            finishAdjustment(false);
        else
            closeRequested();
    }

    function runWindowAction(action) {
        Quickshell.execDetached([
            "desktop-window-action", action,
            "--address", targetAddress,
            "--origin", "titlebar"
        ]);
        closeRequested();
    }

    function trigger(entry) {
        if (!entry || !entryEnabled(entry))
            return;
        switch (entry.id) {
        case "restore":
            if (Number(targetWindow.fullscreen || targetWindow.fullscreenClient || 0) > 0)
                runWindowAction("maximize");
            break;
        case "move":
        case "resize":
            originalGeometry = captureGeometry();
            adjustmentMode = entry.id;
            break;
        case "minimize":
        case "maximize":
        case "close":
            runWindowAction(entry.id);
            break;
        }
    }

    function adjust(key) {
        const step = 20;
        let x = 0;
        let y = 0;
        if (key === Qt.Key_Left)
            x = -step;
        else if (key === Qt.Key_Right)
            x = step;
        else if (key === Qt.Key_Up)
            y = -step;
        else if (key === Qt.Key_Down)
            y = step;
        else
            return false;
        Quickshell.execDetached([
            "desktop-window-action",
            adjustmentMode === "move" ? "move-by" : "resize-by",
            "--address", targetAddress,
            "--x", String(x), "--y", String(y),
            "--origin", "titlebar"
        ]);
        return true;
    }

    function handleKey(event) {
        if (event.key === Qt.Key_Escape) {
            if (adjustmentMode !== "")
                finishAdjustment(false);
            else
                closeRequested();
            event.accepted = true;
            return;
        }
        if (adjustmentMode !== "") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                finishAdjustment(true);
                event.accepted = true;
            } else if (adjust(event.key)) {
                event.accepted = true;
            }
            return;
        }
        if (event.key === Qt.Key_Up) {
            selectedIndex = (selectedIndex + entries.length - 1) % entries.length;
            event.accepted = true;
        } else if (event.key === Qt.Key_Down) {
            selectedIndex = (selectedIndex + 1) % entries.length;
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            trigger(entries[selectedIndex]);
            event.accepted = true;
        } else {
            const pressed = String(event.text || "").toUpperCase();
            const index = entries.findIndex(entry => entry.key === pressed);
            if (index >= 0 && entryEnabled(entries[index])) {
                selectedIndex = index;
                trigger(entries[index]);
                event.accepted = true;
            }
        }
    }

    Rectangle {
        id: scrimInput
        anchors.fill: parent
        color: menu.theme.colorScrim
        focus: true

        Keys.onPressed: event => menu.handleKey(event)

        MouseArea {
            anchors.fill: parent
            onClicked: menu.dismiss()
        }

        Rectangle {
            id: menuCard
            x: Math.max(14, Math.min(menu.anchorX,
                parent.width - width - 14))
            y: Math.max(14, Math.min(menu.anchorY,
                parent.height - height - 14))
            width: 300
            height: menu.adjustmentMode === "" ? 354 : 164
            radius: menu.theme.radiusPanel
            color: menu.theme.colorSurfaceOverlay
            border.width: 1
            border.color: menu.theme.colorFocusBorder

            Accessible.role: Accessible.List
            Accessible.name: "시스템 창 메뉴"

            MouseArea {
                anchors.fill: parent
                onClicked: mouse => mouse.accepted = true
            }

            Column {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 4

                Text {
                    width: parent.width
                    height: 34
                    text: menu.adjustmentMode === ""
                        ? String(menu.targetWindow.title || "애플리케이션")
                        : (menu.adjustmentMode === "move" ? "창 이동" : "창 크기 조절")
                    elide: Text.ElideRight
                    color: menu.theme.colorText
                    font.family: "Pretendard"
                    font.pixelSize: 13
                    font.bold: true
                    verticalAlignment: Text.AlignVCenter
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    color: menu.theme.colorDivider
                }

                Repeater {
                    model: menu.adjustmentMode === "" ? menu.entries : []

                    Rectangle {
                        id: menuEntry
                        required property var modelData
                        required property int index
                        readonly property bool available:
                            menu.entryEnabled(modelData)
                        width: parent.width
                        height: 44
                        radius: menu.theme.radiusSmall
                        color: !available
                            ? "transparent"
                            : (index === menu.selectedIndex
                            ? menu.theme.colorFocusSelected
                            : (entryMouse.containsMouse
                                ? menu.theme.colorFocusHover
                                : "transparent"))
                        border.width: index === menu.selectedIndex && available ? 1 : 0
                        border.color: menu.theme.colorFocus
                        opacity: available ? 1 : 0.5

                        Accessible.role: Accessible.ListItem
                        Accessible.name: menu.labelFor(menuEntry.modelData)
                        Accessible.description: menuEntry.available
                            ? menuEntry.modelData.key
                            : (menu.koreanLocale ? "사용할 수 없음" : "Unavailable")
                        Accessible.onPressAction: menu.trigger(menuEntry.modelData)

                        IconImage {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: 18
                            implicitHeight: 18
                            source: Quickshell.iconPath(menuEntry.modelData.icon,
                                "application-x-executable")
                            opacity: menuEntry.available ? 1 : 0.56
                            Accessible.ignored: true
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 42
                            anchors.verticalCenter: parent.verticalCenter
                            text: menu.labelFor(menuEntry.modelData)
                            color: menuEntry.modelData.id === "close"
                                    && (menuEntry.index === menu.selectedIndex
                                        || entryMouse.containsMouse)
                                ? menu.theme.colorCritical : menu.theme.colorText
                            font.family: "Pretendard"
                            font.pixelSize: 13
                            font.bold: true
                        }

                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: menuEntry.modelData.key
                            color: menu.theme.colorTextMuted
                            font.family: "Pretendard"
                            font.pixelSize: 10
                        }

                        MouseArea {
                            id: entryMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: menuEntry.available
                            onEntered: menu.selectedIndex = menuEntry.index
                            onClicked: menu.trigger(menuEntry.modelData)
                        }
                    }
                }

                Column {
                    visible: menu.adjustmentMode !== ""
                    width: parent.width
                    spacing: 10

                    Text {
                        width: parent.width
                        text: "방향키로 20px씩 조절합니다."
                        color: menu.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                        width: parent.width
                        text: "Enter 완료  ·  Esc 취소"
                        color: menu.theme.colorInfo
                        font.family: "Pretendard"
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            Behavior on height {
                enabled: !menu.reducedMotion
                NumberAnimation { duration: menu.theme.durationDirect; easing.type: Easing.OutCubic }
            }
        }
    }
}
