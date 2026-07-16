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
    id: overlay

    required property var targetScreen
    required property bool overlayOpen
    required property string activeScreenName
    required property var theme
    required property bool reducedMotion

    signal closeRequested()

    property int selectedIndex: 0
    property bool applying: false
    property string applyError: ""
    property var displayStatus: ({
        "mode": "none",
        "pending": false,
        "seconds_remaining": 0,
        "external_count": 0
    })
    readonly property var choices: [
        {"id": "internal", "label": "PC 화면만", "description": "노트북 화면만 사용"},
        {"id": "mirror", "label": "복제", "description": "두 화면에 같은 내용 표시"},
        {"id": "extend", "label": "확장", "description": "두 화면을 하나의 작업 공간으로 사용"},
        {"id": "external", "label": "두 번째 화면만", "description": "외부 화면만 사용"}
    ]

    screen: targetScreen
    visible: overlayOpen && targetScreen.name === activeScreenName
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

    WlrLayershell.namespace: "cyberdisplay"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    function choiceAvailable(index) {
        return index === 0 || Number(displayStatus.external_count || 0) > 0;
    }

    function applySelected() {
        if (!choiceAvailable(selectedIndex) || applying)
            return;
        applyError = "";
        applying = true;
        applyProcess.exec([
            "desktop-display-mode", "apply", choices[selectedIndex].id
        ]);
    }

    function applyFailureMessage(detail) {
        const normalized = String(detail || "").toLowerCase();
        if (normalized.includes("no compatible duplicate mode"))
            return "호환되는 복제 모드가 없습니다. 고급 디스플레이 설정에서 해상도를 확인하세요.";
        if (normalized.includes("no external output"))
            return "연결된 외부 화면을 찾지 못했습니다. 케이블 연결을 확인한 뒤 다시 시도하세요.";
        return "디스플레이 설정을 적용하지 못했습니다. 다시 시도하거나 고급 설정을 여세요.";
    }

    function confirm() {
        Quickshell.execDetached(["desktop-display-mode", "confirm"]);
        closeRequested();
    }

    function revert() {
        Quickshell.execDetached(["desktop-display-mode", "revert"]);
        closeRequested();
    }

    function moveSelection(delta) {
        let candidate = selectedIndex;
        for (let step = 0; step < choices.length; ++step) {
            candidate = (candidate + delta + choices.length) % choices.length;
            if (choiceAvailable(candidate)) {
                selectedIndex = candidate;
                return;
            }
        }
    }

    Process {
        id: statusProcess
        command: ["desktop-display-mode", "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const next = JSON.parse(text);
                    if (next.schema === 1)
                        overlay.displayStatus = next;
                } catch (error) {
                    console.warn("cyberdisplay: invalid status:", error);
                }
            }
        }
    }

    Timer {
        id: statusTimer
        interval: 500
        repeat: true
        running: overlay.visible
        triggeredOnStart: true
        onTriggered: {
            if (!statusProcess.running)
                statusProcess.running = true;
        }
    }

    Process {
        id: applyProcess
        stderr: StdioCollector { id: applyErrorCollector }
        onExited: (exitCode, exitStatus) => {
            overlay.applying = false;
            if (exitCode === 0) {
                overlay.applyError = "";
            } else {
                overlay.applyError = overlay.applyFailureMessage(
                    applyErrorCollector.text);
                console.warn("cyberdisplay: apply failed:", exitCode,
                    exitStatus, applyErrorCollector.text.trim());
            }
            if (!statusProcess.running)
                statusProcess.running = true;
        }
    }

    onVisibleChanged: {
        if (visible) {
            applying = false;
            applyError = "";
            selectedIndex = Math.max(0, choices.findIndex(choice =>
                choice.id === displayStatus.mode));
            Qt.callLater(() => keyHandler.forceActiveFocus());
        }
    }

    Rectangle {
        anchors.fill: parent
        color: overlay.theme.colorScrim
    }

    MouseArea {
        anchors.fill: parent
        enabled: !overlay.displayStatus.pending
        onClicked: overlay.closeRequested()
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 620)
        height: confirmation.visible ? 310 : 430
        radius: overlay.theme.radiusPanel
        color: overlay.theme.colorLauncherSurface
        border.width: 1
        border.color: overlay.theme.colorSelectionBorder
        scale: overlay.visible ? 1 : 0.98

        Behavior on scale {
            enabled: !overlay.reducedMotion
            NumberAnimation { duration: overlay.theme.durationEnter; easing.type: Easing.OutCubic }
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
                    if (overlay.displayStatus.pending)
                        overlay.revert();
                    else
                        overlay.closeRequested();
                    event.accepted = true;
                } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) {
                    overlay.moveSelection(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) {
                    overlay.moveSelection(1);
                    event.accepted = true;
                } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_4) {
                    const index = event.key - Qt.Key_1;
                    if (overlay.choiceAvailable(index)) {
                        overlay.selectedIndex = index;
                        overlay.applySelected();
                    }
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    if (overlay.displayStatus.pending)
                        overlay.confirm();
                    else
                        overlay.applySelected();
                    event.accepted = true;
                }
            }
        }

        Text {
            id: heading
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: 28
            anchors.rightMargin: 28
            anchors.topMargin: 24
            text: confirmation.visible ? "디스플레이 설정 유지" : "프로젝션 모드"
            color: overlay.theme.colorText
            font.family: "Pretendard"
            font.pixelSize: 22
            font.bold: true
        }

        Text {
            id: supportingText
            anchors.left: heading.left
            anchors.right: heading.right
            anchors.top: heading.bottom
            anchors.topMargin: 7
            text: confirmation.visible
                ? overlay.displayStatus.seconds_remaining + "초 후 이전 설정으로 자동 복원됩니다."
                : "연결된 화면을 어떻게 사용할지 선택하세요."
            color: confirmation.visible
                ? overlay.theme.colorWarning
                : overlay.theme.colorTextMuted
            font.family: "Pretendard"
            font.pixelSize: 14
        }

        Grid {
            id: choiceGrid
            visible: !confirmation.visible
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: supportingText.bottom
            anchors.leftMargin: 24
            anchors.rightMargin: 24
            anchors.topMargin: 22
            columns: 2
            columnSpacing: 10
            rowSpacing: 10

            Repeater {
                model: overlay.choices

                delegate: Rectangle {
                    id: choiceButton
                    required property var modelData
                    required property int index
                    readonly property bool available: overlay.choiceAvailable(index)
                    width: Math.floor((choiceGrid.width - choiceGrid.columnSpacing) / 2)
                    height: 94
                    radius: overlay.theme.radiusControl
                    color: !available
                        ? overlay.theme.colorSurfaceSubtle
                        : (choiceMouse.pressed
                            ? overlay.theme.colorFocusSelected
                            : (index === overlay.selectedIndex
                                ? overlay.theme.colorSelectionSoft
                                : (choiceMouse.containsMouse
                                    ? overlay.theme.colorFocusHover
                                    : overlay.theme.colorRaisedSoft)))
                    border.width: index === overlay.selectedIndex && available ? 2 : 1
                    border.color: index === overlay.selectedIndex && available
                        ? overlay.theme.colorFocus
                        : overlay.theme.colorQuietBorder
                    opacity: available ? 1 : 0.5
                    scale: choiceMouse.pressed ? 0.985 : 1

                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.label
                    Accessible.description: modelData.description
                    Accessible.selected: index === overlay.selectedIndex
                    Accessible.onPressAction: {
                        if (available) {
                            overlay.selectedIndex = index;
                            overlay.applySelected();
                        }
                    }

                    Behavior on scale {
                        enabled: !overlay.reducedMotion
                        NumberAnimation { duration: overlay.theme.durationFast }
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: shortcut.left
                        anchors.top: parent.top
                        anchors.leftMargin: 14
                        anchors.rightMargin: 8
                        anchors.topMargin: 15
                        text: choiceButton.modelData.label
                        color: choiceButton.available
                            ? overlay.theme.colorText
                            : overlay.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 15
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    Text {
                        id: shortcut
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.rightMargin: 14
                        anchors.topMargin: 15
                        text: String(choiceButton.index + 1)
                        color: overlay.theme.colorFocus
                        font.family: "Jetendard"
                        font.pixelSize: 13
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        anchors.bottomMargin: 15
                        text: choiceButton.modelData.description
                        color: overlay.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        id: choiceMouse
                        anchors.fill: parent
                        enabled: choiceButton.available && !overlay.applying
                        hoverEnabled: true
                        onEntered: overlay.selectedIndex = choiceButton.index
                        onClicked: overlay.applySelected()
                    }
                }
            }
        }

        Text {
            id: applyErrorText
            visible: !confirmation.visible && text !== ""
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: advancedButton.top
            anchors.leftMargin: 28
            anchors.rightMargin: 28
            anchors.bottomMargin: 10
            text: overlay.applyError
            color: overlay.theme.colorCritical
            font.family: "Pretendard"
            font.pixelSize: 12
            font.bold: true
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight

            Accessible.role: Accessible.AlertMessage
            Accessible.name: text
        }

        Rectangle {
            id: advancedButton
            visible: !confirmation.visible
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 24
            anchors.rightMargin: 24
            anchors.bottomMargin: 22
            height: 46
            radius: overlay.theme.radiusControl
            color: advancedMouse.pressed
                ? overlay.theme.colorFocusSelected
                : (advancedMouse.containsMouse
                    ? overlay.theme.colorFocusHover
                    : "transparent")
            border.width: 1
            border.color: overlay.theme.colorQuietBorder

            Accessible.role: Accessible.Button
            Accessible.name: "고급 디스플레이 설정"
            Accessible.onPressAction: {
                Quickshell.execDetached(["uwsm", "app", "--", "nwg-displays"]);
                overlay.closeRequested();
            }

            Text {
                anchors.centerIn: parent
                text: overlay.applying ? "적용 중…" : "고급 디스플레이 설정"
                color: overlay.theme.colorText
                font.family: "Pretendard"
                font.pixelSize: 14
                font.bold: true
            }

            MouseArea {
                id: advancedMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: !overlay.applying
                onClicked: {
                    Quickshell.execDetached(["uwsm", "app", "--", "nwg-displays"]);
                    overlay.closeRequested();
                }
            }
        }

        Row {
            id: confirmation
            visible: overlay.displayStatus.pending
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 24
            anchors.rightMargin: 24
            anchors.bottomMargin: 24
            height: 48
            spacing: 10

            Repeater {
                model: [
                    {"label": "되돌리기", "primary": false},
                    {"label": "변경 내용 유지", "primary": true}
                ]

                delegate: Rectangle {
                    id: confirmButton
                    required property var modelData
                    required property int index
                    width: Math.floor((confirmation.width - confirmation.spacing) / 2)
                    height: 48
                    radius: overlay.theme.radiusControl
                    color: confirmMouse.pressed
                        ? overlay.theme.colorFocusSelected
                        : (modelData.primary
                            ? overlay.theme.colorSelectionStrong
                            : (confirmMouse.containsMouse
                                ? overlay.theme.colorFocusHover
                                : "transparent"))
                    border.width: 1
                    border.color: modelData.primary
                        ? overlay.theme.colorFocus
                        : overlay.theme.colorQuietBorder

                    Accessible.role: Accessible.Button
                    Accessible.name: modelData.label
                    Accessible.onPressAction: index === 0
                        ? overlay.revert()
                        : overlay.confirm()

                    Text {
                        anchors.centerIn: parent
                        text: confirmButton.modelData.label
                        color: overlay.theme.colorText
                        font.family: "Pretendard"
                        font.pixelSize: 14
                        font.bold: true
                    }

                    MouseArea {
                        id: confirmMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: confirmButton.index === 0
                            ? overlay.revert()
                            : overlay.confirm()
                    }
                }
            }
        }
    }
}
