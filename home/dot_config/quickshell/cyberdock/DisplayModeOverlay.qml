pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

// Quickshell's generated qmltypes marks this runtime-provided interface as
// uncreatable even though the layer-shell plugin creates it at runtime.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: overlay

    required property var targetScreen
    required property bool overlayOpen
    required property string activeScreenName
    required property var displayStatus
    required property var theme
    required property bool reducedMotion
    required property var strings
    property string reviewState: ""

    signal closeRequested()

    property int selectedIndex: 0
    property bool applying: false
    property string applyError: ""
    property int statusClock: 0
    readonly property int secondsRemaining: {
        void statusClock;
        const deadline = Number(displayStatus.deadline || 0);
        return deadline > 0
            ? Math.max(0, Math.ceil(deadline - Date.now() / 1000))
            : Number(displayStatus.seconds_remaining || 0);
    }
    readonly property bool koreanLocale:
        String(Quickshell.env("LANG") || "").toLowerCase().startsWith("ko")
    readonly property var choices: [
        {"id": "internal", "label": tr("display.internal"), "description": tr("display.internalDescription")},
        {"id": "mirror", "label": tr("display.mirror"), "description": tr("display.mirrorDescription")},
        {"id": "extend", "label": tr("display.extend"), "description": tr("display.extendDescription")},
        {"id": "external", "label": tr("display.external"), "description": tr("display.externalDescription")}
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

    function tr(key) {
        const value = strings?.[key];
        if (value !== undefined && String(value) !== "")
            return String(value);
        return key;
    }

    function choiceAvailable(index) {
        return index === 0 || Number(displayStatus.external_count || 0) > 0;
    }

    function applySelected() {
        if (!choiceAvailable(selectedIndex) || applying)
            return;
        applyError = "";
        applying = true;
        applyProcess.exec([
            "bash", "-c",
            "output=$(\"$@\" 2>&1); exit_code=$?; printf '%s\\n%s' \"$exit_code\" \"$output\"",
            "cyberdisplay-apply",
            "desktop-display-mode", "apply", choices[selectedIndex].id
        ]);
    }

    function applyFailureMessage(detail) {
        const normalized = String(detail || "").toLowerCase();
        if (normalized.includes("no compatible duplicate mode"))
            return tr("display.errorMirror");
        if (normalized.includes("no external output"))
            return tr("display.errorExternal");
        return tr("display.errorGeneric");
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

    function applyReviewState() {
        if (!visible || reviewState === "")
            return;
        selectedIndex = ["hover", "focus", "selected", "applying"].includes(reviewState)
            ? 2 : 0;
        applying = reviewState === "applying";
        applyError = reviewState === "error" ? tr("display.errorGeneric") : "";
    }

    Timer {
        interval: 1000
        repeat: true
        running: overlay.visible && Boolean(overlay.displayStatus.pending)
        onTriggered: overlay.statusClock += 1
    }

    Process {
        id: applyProcess
        stdout: StdioCollector {
            id: applyResultCollector
            onStreamFinished: {
                const separator = text.indexOf("\n");
                const exitCode = Number(separator >= 0
                    ? text.slice(0, separator) : text);
                const detail = separator >= 0
                    ? text.slice(separator + 1) : "";
                overlay.applying = false;
                if (exitCode === 0) {
                    overlay.applyError = "";
                } else {
                    overlay.applyError = overlay.applyFailureMessage(detail);
                    console.warn("cyberdisplay: apply failed:", exitCode,
                        detail.trim());
                }
            }
        }
    }

    onVisibleChanged: {
        if (visible) {
            applying = false;
            applyError = "";
            selectedIndex = Math.max(0, choices.findIndex(choice =>
                choice.id === displayStatus.mode));
            Qt.callLater(() => {
                overlay.applyReviewState();
                keyHandler.forceActiveFocus();
            });
        }
    }

    onReviewStateChanged: Qt.callLater(() => applyReviewState())

    onDisplayStatusChanged: {
        if (visible && !applying)
            selectedIndex = Math.max(0, choices.findIndex(choice =>
                choice.id === displayStatus.mode));
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
            anchors.rightMargin: confirmation.visible ? 28 : 190
            anchors.topMargin: 24
            text: confirmation.visible ? overlay.tr("display.keepHeading") : overlay.tr("display.heading")
            color: overlay.theme.colorText
            font.family: "Pretendard"
            font.pixelSize: 22
            font.bold: true
        }

        Rectangle {
            id: topologyPreview
            visible: !confirmation.visible
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: 24
            anchors.topMargin: 18
            width: 150
            height: 54
            radius: overlay.theme.radiusSmall
            color: overlay.theme.colorSurfaceSubtle
            border.width: 1
            border.color: overlay.theme.colorQuietBorder

            Item {
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 58
                height: 32
                Rectangle {
                    x: 0
                    y: 9
                    width: 25
                    height: 17
                    radius: 2
                    color: "transparent"
                    border.width: 1
                    border.color: overlay.theme.colorText
                    opacity: overlay.choices[overlay.selectedIndex].id === "external" ? 0.35 : 1
                }
                Rectangle {
                    x: overlay.choices[overlay.selectedIndex].id === "mirror" ? 20 : 31
                    y: overlay.choices[overlay.selectedIndex].id === "mirror" ? 4 : 6
                    width: 27
                    height: 20
                    radius: 2
                    color: "transparent"
                    border.width: 1
                    border.color: overlay.theme.colorText
                    opacity: overlay.choices[overlay.selectedIndex].id === "internal" ? 0.35 : 1
                }
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 74
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: overlay.choices[overlay.selectedIndex].label
                color: overlay.theme.colorTextMuted
                font.family: "Pretendard"
                font.pixelSize: 10
                font.bold: true
                elide: Text.ElideRight
            }
        }

        Text {
            id: supportingText
            anchors.left: heading.left
            anchors.right: heading.right
            anchors.top: heading.bottom
            anchors.topMargin: 7
            text: confirmation.visible
                ? overlay.tr("display.rollbackPrefix") + " " + overlay.secondsRemaining + " " + overlay.tr("display.rollbackSuffix")
                : overlay.tr("display.supporting")
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
                    readonly property bool hovered: choiceMouse.containsMouse
                        || (overlay.reviewState === "hover" && index === 2)
                    readonly property bool pressed: choiceMouse.pressed
                        || (overlay.reviewState === "focus" && index === 2)
                    width: 280
                    height: 100
                    radius: overlay.theme.radiusControl
                    color: !available
                        ? overlay.theme.colorSurfaceSubtle
                        : (pressed
                            ? overlay.theme.colorFocusSelected
                            : (index === overlay.selectedIndex
                                ? overlay.theme.colorSelectionSoft
                                : (hovered
                                    ? overlay.theme.colorFocusHover
                                    : overlay.theme.colorRaisedSoft)))
                    border.width: index === overlay.selectedIndex && available ? 2 : 1
                    border.color: index === overlay.selectedIndex && available
                        ? overlay.theme.colorFocus
                        : overlay.theme.colorQuietBorder
                    opacity: available ? 1 : 0.5
                    scale: pressed ? 0.985 : 1

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

                    Rectangle {
                        id: shortcut
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.leftMargin: 10
                        anchors.topMargin: 10
                        width: 24
                        height: 24
                        radius: 5
                        color: choiceButton.index === overlay.selectedIndex
                            ? overlay.theme.colorSelectionStrong : overlay.theme.colorRaisedSoft

                        Text {
                            anchors.centerIn: parent
                            text: String(choiceButton.index + 1)
                            color: overlay.theme.colorText
                            font.family: "JetBrains Mono"
                            font.pixelSize: 13
                            font.bold: true
                        }
                    }

                    Item {
                        id: diagram
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 10
                        width: 92
                        height: 34

                        Rectangle {
                            id: laptopDiagram
                            x: choiceButton.modelData.id === "mirror" ? 16 : 4
                            y: choiceButton.modelData.id === "mirror" ? 8 : 10
                            width: choiceButton.modelData.id === "extend" ? 39 : 36
                            height: 21
                            radius: 2
                            color: "transparent"
                            border.width: 2
                            border.color: choiceButton.available
                                ? overlay.theme.colorText : overlay.theme.colorTextMuted
                            opacity: choiceButton.modelData.id === "external" ? 0.35 : 1

                            Text {
                                anchors.centerIn: parent
                                visible: ["mirror", "extend"].includes(choiceButton.modelData.id)
                                text: "1"
                                color: overlay.theme.colorText
                                font.family: "JetBrains Mono"
                                font.pixelSize: 10
                            }
                        }

                        Rectangle {
                            x: choiceButton.modelData.id === "mirror" ? 39 : 49
                            y: choiceButton.modelData.id === "mirror" ? 3 : 6
                            width: choiceButton.modelData.id === "extend" ? 39 : 40
                            height: 25
                            radius: 2
                            color: "transparent"
                            border.width: 2
                            border.color: choiceButton.available
                                ? overlay.theme.colorText : overlay.theme.colorTextMuted
                            opacity: choiceButton.modelData.id === "internal" ? 0.35 : 1

                            Text {
                                anchors.centerIn: parent
                                visible: ["mirror", "extend"].includes(choiceButton.modelData.id)
                                text: choiceButton.modelData.id === "mirror" ? "1" : "2"
                                color: overlay.theme.colorText
                                font.family: "JetBrains Mono"
                                font.pixelSize: 10
                            }
                        }
                    }

                    IconImage {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.rightMargin: 10
                        anchors.topMargin: 11
                        width: 20
                        height: 20
                        visible: !choiceButton.available
                            || choiceButton.index === overlay.selectedIndex
                        source: Quickshell.iconPath(
                            !choiceButton.available ? "action-unavailable-symbolic"
                                : (overlay.applying ? "process-working-symbolic" : "emblem-default-symbolic"),
                            "dialog-information-symbolic")
                        RotationAnimator on rotation {
                            running: choiceButton.visible && choiceButton.available
                                && overlay.applying && choiceButton.index === overlay.selectedIndex
                                && !overlay.reducedMotion && overlay.reviewState === ""
                            from: 0
                            to: 360
                            duration: 900
                            loops: Animation.Infinite
                        }
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        anchors.topMargin: 48
                        horizontalAlignment: Text.AlignHCenter
                        text: choiceButton.modelData.label
                        color: choiceButton.available
                            ? overlay.theme.colorText : overlay.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 14
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        anchors.bottomMargin: 10
                        horizontalAlignment: Text.AlignHCenter
                        text: overlay.applying && choiceButton.index === overlay.selectedIndex
                            ? overlay.tr("display.applying") : choiceButton.modelData.description
                        color: overlay.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 11
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
            Accessible.name: overlay.tr("display.advanced")
            Accessible.onPressAction: {
                Quickshell.execDetached(["uwsm", "app", "--", "nwg-displays"]);
                overlay.closeRequested();
            }

            Text {
                anchors.centerIn: parent
                text: overlay.applying ? overlay.tr("display.applying") : overlay.tr("display.advanced")
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

        Rectangle {
            id: confirmationPreview
            visible: confirmation.visible
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: supportingText.bottom
            anchors.topMargin: 18
            width: 280
            height: 100
            radius: overlay.theme.radiusControl
            color: overlay.theme.colorSurfaceSubtle
            border.width: 1
            border.color: overlay.theme.colorQuietBorder

            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 15
                width: 124
                height: 42

                Rectangle {
                    x: 4
                    y: 12
                    width: 48
                    height: 27
                    radius: 3
                    color: "transparent"
                    border.width: 2
                    border.color: overlay.theme.colorText
                    opacity: overlay.displayStatus.mode === "external" ? 0.35 : 1
                }
                Rectangle {
                    x: overlay.displayStatus.mode === "mirror" ? 42 : 68
                    y: overlay.displayStatus.mode === "mirror" ? 4 : 8
                    width: 52
                    height: 31
                    radius: 3
                    color: "transparent"
                    border.width: 2
                    border.color: overlay.theme.colorText
                    opacity: overlay.displayStatus.mode === "internal" ? 0.35 : 1
                }
            }

            Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                anchors.bottomMargin: 12
                horizontalAlignment: Text.AlignHCenter
                text: (overlay.choices.find(choice =>
                    choice.id === overlay.displayStatus.mode) || overlay.choices[0]).label
                color: overlay.theme.colorText
                font.family: "Pretendard"
                font.pixelSize: 13
                font.bold: true
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
                    {"label": overlay.tr("display.revert"), "primary": false},
                    {"label": overlay.tr("display.keep"), "primary": true}
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
