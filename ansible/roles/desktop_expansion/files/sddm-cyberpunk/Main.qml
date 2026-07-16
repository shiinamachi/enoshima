import QtQuick 2.0
import SddmComponents 2.0

Rectangle {
    id: root
    color: canvas

    readonly property color canvas: "#050623"
    readonly property color surface: "#0a0c3e"
    readonly property color surfaceRaised: "#161151"
    readonly property color focusColor: "#62d8ff"
    readonly property color selectionColor: "#9a5cff"
    readonly property color textColor: "#f2ecff"
    readonly property color mutedTextColor: "#c9bfe8"
    readonly property color successColor: "#77e0c6"
    readonly property color warningColor: "#ffb86b"
    readonly property color criticalColor: "#ff5d8f"

    readonly property real shortSide: Math.min(width, height)
    readonly property real uiScale: Math.max(0.9, Math.min(1.2, shortSide / 1080))
    readonly property int panelWidth: Math.round(Math.max(420, Math.min(640, width * 0.34)))
    readonly property int safeMargin: Math.round(Math.max(24, Math.min(72, shortSide * 0.04)))
    readonly property int panelPadding: Math.round(Math.max(20, Math.min(28, shortSide * 0.026)))
    readonly property int controlHeight: Math.round(Math.max(44, Math.min(52, 48 * uiScale)))
    readonly property int labelSize: Math.round(Math.max(12, Math.min(14, 13 * uiScale)))
    readonly property int bodySize: Math.round(Math.max(14, Math.min(17, 16 * uiScale)))

    // These context objects are injected by sddm-greeter at runtime. Its QML
    // module does not publish qmltypes metadata for static analysis.
    // qmllint disable unqualified
    readonly property var greeter: sddm
    readonly property var greeterUsers: userModel
    readonly property var greeterSessions: sessionModel
    // qmllint enable unqualified

    readonly property string idleMessage: "Enter your password, or leave it blank and select Sign in to scan your fingerprint."
    property bool authenticating: false
    property string statusKind: "idle"
    property int sessionIndex: session.index

    function setStatus(kind, message) {
        statusKind = kind
        status.text = message
    }

    function submitLogin() {
        if (authenticating)
            return

        authenticating = true
        setStatus("authenticating", "Authenticating... Follow the fingerprint prompt if requested.")
        greeter.login(username.text, password.text, sessionIndex)
    }

    Background {
        anchors.fill: parent
        source: root.width / Math.max(root.height, 1) < 1.7
            ? "background-16x10.jpg"
            : "background-16x9.jpg"
        fillMode: Image.PreserveAspectCrop
    }

    Rectangle {
        anchors.fill: parent
        color: "#80050623"
    }

    Connections {
        target: root.greeter

        function onLoginSucceeded() {
            root.setStatus("success", "Authentication succeeded.")
        }

        function onLoginFailed() {
            root.authenticating = false
            password.text = ""
            root.setStatus("failure", "Authentication failed. Check your password or try the fingerprint reader again.")
            password.forceActiveFocus()
        }

        function onInformationMessage(message) {
            if (message && message.length > 0)
                root.setStatus("information", message)
        }
    }

    Rectangle {
        id: authPanel
        width: root.panelWidth
        height: Math.min(root.height - root.safeMargin * 2,
            panelContent.implicitHeight + root.panelPadding * 2)
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: root.safeMargin
        anchors.bottomMargin: root.safeMargin
        color: "#f00a0c3e"
        radius: 18
        border.width: 1
        border.color: "#7a62d8ff"

        Column {
            id: panelContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: root.panelPadding
            spacing: 8

            Text {
                text: "SESSION SIGN-IN"
                color: root.mutedTextColor
                font.family: "Pretendard"
                font.pixelSize: root.labelSize
                font.weight: Font.Medium
            }

            Text {
                id: clock
                text: Qt.formatTime(new Date(), "HH:mm")
                color: root.textColor
                font.family: "Pretendard"
                font.pixelSize: Math.round(Math.max(52, Math.min(72,
                    root.shortSide * 0.067)))
                font.weight: Font.Light
            }

            Text {
                id: dateText
                text: Qt.formatDate(new Date(), "dddd, dd MMMM yyyy")
                color: root.mutedTextColor
                font.family: "Pretendard"
                font.pixelSize: Math.round(Math.max(16, Math.min(20,
                    18 * root.uiScale)))

                Timer {
                    interval: 30000
                    running: true
                    repeat: true
                    onTriggered: {
                        const now = new Date()
                        clock.text = Qt.formatTime(now, "HH:mm")
                        dateText.text = Qt.formatDate(now, "dddd, dd MMMM yyyy")
                    }
                }
            }

            Item {
                width: 1
                height: 4
            }

            Text {
                text: "Username"
                color: root.mutedTextColor
                font.family: "Pretendard"
                font.pixelSize: root.labelSize
                font.weight: Font.Medium
            }

            TextBox {
                id: username
                width: parent.width
                height: root.controlHeight
                text: root.greeterUsers.lastUser
                color: root.surfaceRaised
                textColor: root.textColor
                borderColor: "#6d8cff"
                focusColor: root.focusColor
                hoverColor: root.selectionColor
                radius: 10
                font.family: "Pretendard"
                font.pixelSize: root.bodySize
                KeyNavigation.backtab: powerOff
                KeyNavigation.tab: password

                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    radius: 10
                    border.width: username.activeFocus ? 2 : 0
                    border.color: root.focusColor
                    z: 2
                }
            }

            Text {
                text: "Password"
                color: root.mutedTextColor
                font.family: "Pretendard"
                font.pixelSize: root.labelSize
                font.weight: Font.Medium
            }

            PasswordBox {
                id: password
                width: parent.width
                height: root.controlHeight
                color: root.surfaceRaised
                textColor: root.textColor
                borderColor: "#6d8cff"
                focusColor: root.focusColor
                hoverColor: root.selectionColor
                radius: 10
                tooltipFG: root.textColor
                tooltipBG: root.surfaceRaised
                font.family: "Pretendard"
                font.pixelSize: root.bodySize
                KeyNavigation.backtab: username
                KeyNavigation.tab: session
                Keys.onPressed: function(keyEvent) {
                    if (keyEvent.key === Qt.Key_Return || keyEvent.key === Qt.Key_Enter) {
                        root.submitLogin()
                        keyEvent.accepted = true
                    }
                }
                onTextChanged: {
                    if (!root.authenticating && root.statusKind === "failure" && text !== "")
                        root.setStatus("idle", root.idleMessage)
                }

                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    radius: 10
                    border.width: password.activeFocus ? 2 : 0
                    border.color: root.focusColor
                    z: 2
                }
            }

            Text {
                text: "Session"
                color: root.mutedTextColor
                font.family: "Pretendard"
                font.pixelSize: root.labelSize
                font.weight: Font.Medium
            }

            Row {
                id: sessionRow
                width: parent.width
                height: root.controlHeight
                spacing: 12
                z: session.activeFocus ? 10 : 1

                ComboBox {
                    id: session
                    width: parent.width - login.width - parent.spacing
                    height: root.controlHeight
                    model: root.greeterSessions
                    index: root.greeterSessions.lastIndex
                    color: root.surfaceRaised
                    textColor: root.textColor
                    menuColor: root.surfaceRaised
                    borderColor: "#6d8cff"
                    focusColor: root.focusColor
                    hoverColor: root.selectionColor
                    arrowColor: root.surfaceRaised
                    borderWidth: 1
                    font.family: "Pretendard"
                    font.pixelSize: Math.round(Math.max(13, Math.min(15,
                        14 * root.uiScale)))
                    KeyNavigation.backtab: password
                    KeyNavigation.tab: login

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 7
                        anchors.verticalCenter: parent.verticalCenter
                        text: "⌄"
                        color: root.focusColor
                        font.family: "Pretendard"
                        font.pixelSize: 18
                        z: 2
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        border.width: session.activeFocus ? 2 : 0
                        border.color: root.focusColor
                        z: 3
                    }
                }

                Button {
                    id: login
                    width: Math.round(Math.max(132, Math.min(176,
                        sessionRow.width * 0.32)))
                    height: root.controlHeight
                    radius: 10
                    enabled: !root.authenticating
                    text: root.authenticating ? "AUTHENTICATING..." : "SIGN IN"
                    color: Qt.darker(root.selectionColor, 1.25)
                    activeColor: Qt.darker(root.selectionColor, 1.4)
                    pressedColor: root.surfaceRaised
                    disabledColor: root.surface
                    textColor: root.textColor
                    font.family: "Pretendard"
                    font.pixelSize: Math.round(Math.max(13, Math.min(15,
                        14 * root.uiScale)))
                    KeyNavigation.backtab: session
                    KeyNavigation.tab: suspend
                    onClicked: root.submitLogin()

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        radius: 10
                        border.width: login.activeFocus ? 2 : 0
                        border.color: root.focusColor
                        z: 2
                    }
                }
            }

            Text {
                id: status
                width: parent.width
                height: Math.max(root.controlHeight, implicitHeight)
                text: root.idleMessage
                color: root.statusKind === "failure" ? root.criticalColor
                    : root.statusKind === "success" ? root.successColor
                    : root.statusKind === "authenticating" ? root.warningColor
                    : root.focusColor
                font.family: "Pretendard"
                font.pixelSize: root.labelSize
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
            }

            Rectangle {
                width: parent.width
                height: 1
                color: "#4d6d8cff"
                visible: powerRow.visible
            }

            Row {
                id: powerRow
                width: parent.width
                height: visibleCount > 0 ? root.controlHeight : 0
                spacing: 8
                visible: visibleCount > 0
                property int visibleCount: (root.greeter.canSuspend ? 1 : 0)
                    + (root.greeter.canReboot ? 1 : 0)
                    + (root.greeter.canPowerOff ? 1 : 0)
                property real controlWidth: visibleCount > 0
                    ? (width - spacing * (visibleCount - 1)) / visibleCount
                    : 0

                Button {
                    id: suspend
                    width: powerRow.controlWidth
                    height: root.controlHeight
                    radius: 10
                    visible: root.greeter.canSuspend
                    enabled: visible && !root.authenticating
                    text: "SUSPEND"
                    color: root.surfaceRaised
                    activeColor: Qt.lighter(root.surfaceRaised, 1.35)
                    pressedColor: root.selectionColor
                    disabledColor: root.surface
                    textColor: root.textColor
                    font.family: "Pretendard"
                    font.pixelSize: root.labelSize
                    KeyNavigation.backtab: login
                    KeyNavigation.tab: reboot
                    onClicked: root.greeter.suspend()

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        radius: 10
                        border.width: suspend.activeFocus ? 2 : 0
                        border.color: root.focusColor
                        z: 2
                    }
                }

                Button {
                    id: reboot
                    width: powerRow.controlWidth
                    height: root.controlHeight
                    radius: 10
                    visible: root.greeter.canReboot
                    enabled: visible && !root.authenticating
                    text: "REBOOT"
                    color: root.surfaceRaised
                    activeColor: Qt.lighter(root.surfaceRaised, 1.35)
                    pressedColor: root.warningColor
                    disabledColor: root.surface
                    textColor: root.warningColor
                    font.family: "Pretendard"
                    font.pixelSize: root.labelSize
                    KeyNavigation.backtab: suspend
                    KeyNavigation.tab: powerOff
                    onClicked: root.greeter.reboot()

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        radius: 10
                        border.width: reboot.activeFocus ? 2 : 0
                        border.color: root.focusColor
                        z: 2
                    }
                }

                Button {
                    id: powerOff
                    width: powerRow.controlWidth
                    height: root.controlHeight
                    radius: 10
                    visible: root.greeter.canPowerOff
                    enabled: visible && !root.authenticating
                    text: "POWER OFF"
                    color: root.surfaceRaised
                    activeColor: Qt.lighter(root.surfaceRaised, 1.35)
                    pressedColor: root.criticalColor
                    disabledColor: root.surface
                    textColor: root.criticalColor
                    font.family: "Pretendard"
                    font.pixelSize: root.labelSize
                    KeyNavigation.backtab: reboot
                    KeyNavigation.tab: username
                    onClicked: root.greeter.powerOff()

                    Rectangle {
                        anchors.fill: parent
                        color: "transparent"
                        radius: 10
                        border.width: powerOff.activeFocus ? 2 : 0
                        border.color: root.focusColor
                        z: 2
                    }
                }
            }
        }
    }

    Component.onCompleted: {
        if (username.text === "")
            username.forceActiveFocus()
        else
            password.forceActiveFocus()
    }
}
