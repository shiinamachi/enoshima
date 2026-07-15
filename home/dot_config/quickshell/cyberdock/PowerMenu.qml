pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Quickshell's generated qmltypes marks this runtime-provided interface as
// uncreatable even though the layer-shell plugin creates it at runtime.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: menu

    required property var targetScreen
    required property bool menuOpen
    required property string activeScreenName
    required property var theme
    required property bool reducedMotion

    signal closeRequested()

    property int selectedIndex: 0
    property string confirmationAction: ""
    property var powerStatus: ({
        "availability": {
            "lock": "yes",
            "logout": "yes",
            "suspend": "unknown",
            "reboot": "unknown",
            "poweroff": "unknown"
        }
    })
    readonly property var actions: [
        {"id": "lock", "label": "잠금", "description": "화면을 잠그고 세션 유지"},
        {"id": "logout", "label": "로그아웃", "description": "앱을 정리하고 세션 종료"},
        {"id": "suspend", "label": "절전", "description": "현재 작업을 메모리에 유지"},
        {"id": "reboot", "label": "재시작", "description": "앱을 정리하고 시스템 재시작"},
        {"id": "poweroff", "label": "시스템 종료", "description": "앱을 정리하고 전원 끄기"}
    ]

    screen: targetScreen
    visible: menuOpen && targetScreen.name === activeScreenName
    color: "transparent"
    aboveWindows: true
    focusable: true
    exclusionMode: ExclusionMode.Ignore

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    WlrLayershell.namespace: "cyberpower"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    function actionAvailable(index) {
        const state = String(powerStatus.availability?.[actions[index].id] || "unknown");
        return state !== "no" && state !== "na";
    }

    function requestAction(index) {
        if (!actionAvailable(index))
            return;
        const action = actions[index].id;
        if (action === "reboot" || action === "poweroff") {
            confirmationAction = action;
            return;
        }
        closeRequested();
        Quickshell.execDetached(["desktop-power", action]);
    }

    function confirmAction() {
        const action = confirmationAction;
        confirmationAction = "";
        closeRequested();
        Quickshell.execDetached(["desktop-power", action]);
    }

    function moveSelection(delta) {
        let candidate = selectedIndex;
        for (let step = 0; step < actions.length; ++step) {
            candidate = (candidate + delta + actions.length) % actions.length;
            if (actionAvailable(candidate)) {
                selectedIndex = candidate;
                return;
            }
        }
    }

    Process {
        id: statusProcess
        command: ["desktop-power", "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const next = JSON.parse(text);
                    if (next.schema === 1)
                        menu.powerStatus = next;
                } catch (error) {
                    console.warn("cyberpower: invalid status:", error);
                }
            }
        }
    }

    onVisibleChanged: {
        if (visible) {
            confirmationAction = "";
            statusProcess.running = true;
            Qt.callLater(() => keyHandler.forceActiveFocus());
        }
    }

    Rectangle {
        anchors.fill: parent
        color: menu.theme.colorScrim
    }

    MouseArea {
        anchors.fill: parent
        onClicked: menu.closeRequested()
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 440)
        height: confirmation.visible ? 276 : 438
        radius: menu.theme.radiusPanel
        color: menu.theme.colorLauncherSurface
        border.width: 1
        border.color: menu.theme.colorSelectionBorder
        scale: menu.visible ? 1 : 0.98

        Behavior on scale {
            enabled: !menu.reducedMotion
            NumberAnimation { duration: menu.theme.durationEnter; easing.type: Easing.OutCubic }
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
        }

        Item {
            id: keyHandler
            anchors.fill: parent
            focus: true

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    if (menu.confirmationAction !== "")
                        menu.confirmationAction = "";
                    else
                        menu.closeRequested();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up) {
                    menu.moveSelection(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Down) {
                    menu.moveSelection(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (menu.confirmationAction !== "")
                        menu.confirmAction();
                    else
                        menu.requestAction(menu.selectedIndex);
                    event.accepted = true;
                }
            }
        }

        Text {
            id: heading
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: 26
            anchors.rightMargin: 26
            anchors.topMargin: 24
            text: confirmation.visible
                ? (menu.confirmationAction === "reboot" ? "시스템을 재시작할까요?" : "시스템을 종료할까요?")
                : "전원 및 세션"
            color: menu.theme.colorText
            font.family: "Pretendard"
            font.pixelSize: 21
            font.bold: true
        }

        Text {
            id: supportingText
            anchors.left: heading.left
            anchors.right: heading.right
            anchors.top: heading.bottom
            anchors.topMargin: 7
            text: confirmation.visible
                ? "열려 있는 앱을 정리한 뒤 요청을 실행합니다."
                : "잠금, 절전 또는 세션 종료 작업을 선택하세요."
            color: confirmation.visible
                ? menu.theme.colorWarning
                : menu.theme.colorTextMuted
            font.family: "Pretendard"
            font.pixelSize: 13
        }

        Column {
            id: actionColumn
            visible: !confirmation.visible
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: supportingText.bottom
            anchors.leftMargin: 22
            anchors.rightMargin: 22
            anchors.topMargin: 20
            spacing: 8

            Repeater {
                model: menu.actions

                delegate: Rectangle {
                    id: actionButton
                    required property var modelData
                    required property int index
                    readonly property bool available: menu.actionAvailable(index)
                    width: actionColumn.width
                    height: 56
                    radius: menu.theme.radiusControl
                    color: !available
                        ? menu.theme.colorSurfaceSubtle
                        : (actionMouse.pressed
                            ? menu.theme.colorFocusSelected
                            : (index === menu.selectedIndex
                                ? menu.theme.colorSelectionSoft
                                : (actionMouse.containsMouse
                                    ? menu.theme.colorFocusHover
                                    : "transparent")))
                    border.width: index === menu.selectedIndex && available ? 2 : 1
                    border.color: index === menu.selectedIndex && available
                        ? menu.theme.colorFocus
                        : menu.theme.colorQuietBorder
                    opacity: available ? 1 : 0.5

                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.label
                    Accessible.description: modelData.description
                    Accessible.selected: index === menu.selectedIndex
                    Accessible.onPressAction: menu.requestAction(index)

                    Text {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 15
                        text: actionButton.modelData.label
                        color: menu.theme.colorText
                        font.family: "Pretendard"
                        font.pixelSize: 15
                        font.bold: true
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.rightMargin: 15
                        text: actionButton.available
                            ? actionButton.modelData.description
                            : "사용할 수 없음"
                        color: menu.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 12
                    }

                    MouseArea {
                        id: actionMouse
                        anchors.fill: parent
                        enabled: actionButton.available
                        hoverEnabled: true
                        onEntered: menu.selectedIndex = actionButton.index
                        onClicked: menu.requestAction(actionButton.index)
                    }
                }
            }
        }

        Row {
            id: confirmation
            visible: menu.confirmationAction !== ""
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 22
            anchors.rightMargin: 22
            anchors.bottomMargin: 24
            height: 48
            spacing: 10

            Rectangle {
                width: Math.floor((confirmation.width - confirmation.spacing) / 2)
                height: 48
                radius: menu.theme.radiusControl
                color: cancelMouse.containsMouse ? menu.theme.colorFocusHover : "transparent"
                border.width: 1
                border.color: menu.theme.colorQuietBorder
                Accessible.role: Accessible.Button
                Accessible.name: "취소"
                Accessible.onPressAction: menu.confirmationAction = ""

                Text {
                    anchors.centerIn: parent
                    text: "취소"
                    color: menu.theme.colorText
                    font.family: "Pretendard"
                    font.pixelSize: 14
                    font.bold: true
                }
                MouseArea {
                    id: cancelMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: menu.confirmationAction = ""
                }
            }

            Rectangle {
                width: Math.floor((confirmation.width - confirmation.spacing) / 2)
                height: 48
                radius: menu.theme.radiusControl
                color: confirmMouse.pressed
                    ? menu.theme.colorFocusSelected
                    : menu.theme.colorSelectionStrong
                border.width: 1
                border.color: menu.theme.colorWarning
                Accessible.role: Accessible.Button
                Accessible.name: menu.confirmationAction === "reboot" ? "재시작 확인" : "시스템 종료 확인"
                Accessible.onPressAction: menu.confirmAction()

                Text {
                    anchors.centerIn: parent
                    text: menu.confirmationAction === "reboot" ? "재시작" : "시스템 종료"
                    color: menu.theme.colorText
                    font.family: "Pretendard"
                    font.pixelSize: 14
                    font.bold: true
                }
                MouseArea {
                    id: confirmMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: menu.confirmAction()
                }
            }
        }
    }
}
