pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: menu

    required property var targetScreen
    required property bool menuOpen
    required property string activeScreenName
    required property string targetAddress
    required property var targetWindow
    required property var theme
    required property bool reducedMotion

    signal closeRequested()

    property int selectedIndex: 0
    property string adjustmentMode: ""
    readonly property bool showing: menuOpen
        && targetScreen.name === activeScreenName
        && /^0x[0-9A-Fa-f]+$/.test(targetAddress)
    readonly property var entries: [
        {"id": "restore", "label": "복원", "hint": "최대화 상태 해제"},
        {"id": "move", "label": "이동", "hint": "방향키로 위치 조절"},
        {"id": "resize", "label": "크기 조절", "hint": "방향키로 크기 조절"},
        {"id": "minimize", "label": "최소화", "hint": "Dock에서 복원 가능"},
        {"id": "maximize", "label": "최대화", "hint": "작업 영역에 맞춤"},
        {"id": "close", "label": "닫기", "hint": "앱에 닫기 요청"}
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

    function runWindowAction(action) {
        Quickshell.execDetached([
            "desktop-window-action", action,
            "--address", targetAddress,
            "--origin", "titlebar"
        ]);
        closeRequested();
    }

    function trigger(entry) {
        if (!entry)
            return;
        switch (entry.id) {
        case "restore":
            if (Number(targetWindow.fullscreen || targetWindow.fullscreenClient || 0) > 0)
                runWindowAction("maximize");
            break;
        case "move":
        case "resize":
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
            "hyprctl", "dispatch",
            adjustmentMode === "move" ? "moveactive" : "resizeactive",
            x + " " + y
        ]);
        return true;
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
            if (adjustmentMode !== "")
                adjustmentMode = "";
            else
                closeRequested();
            event.accepted = true;
            return;
        }
        if (adjustmentMode !== "") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                adjustmentMode = "";
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
        }
    }

    Rectangle {
        id: scrimInput
        anchors.fill: parent
        color: menu.theme.colorScrim

        MouseArea {
            anchors.fill: parent
            onClicked: menu.closeRequested()
        }

        Rectangle {
            id: menuCard
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: 22
            anchors.topMargin: 54
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
                        width: parent.width
                        height: 44
                        radius: menu.theme.radiusSmall
                        color: index === menu.selectedIndex
                            ? menu.theme.colorFocusSelected
                            : (entryMouse.containsMouse
                                ? menu.theme.colorFocusHover
                                : "transparent")
                        border.width: index === menu.selectedIndex ? 1 : 0
                        border.color: menu.theme.colorFocus

                        Accessible.role: Accessible.ListItem
                        Accessible.name: menuEntry.modelData.label
                        Accessible.description: menuEntry.modelData.hint
                        Accessible.onPressAction: menu.trigger(menuEntry.modelData)

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: menuEntry.modelData.label
                            color: menuEntry.modelData.id === "close"
                                ? menu.theme.colorCritical
                                : menu.theme.colorText
                            font.family: "Pretendard"
                            font.pixelSize: 13
                            font.bold: true
                        }

                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: menuEntry.modelData.hint
                            color: menu.theme.colorTextMuted
                            font.family: "Pretendard"
                            font.pixelSize: 10
                        }

                        MouseArea {
                            id: entryMouse
                            anchors.fill: parent
                            hoverEnabled: true
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
