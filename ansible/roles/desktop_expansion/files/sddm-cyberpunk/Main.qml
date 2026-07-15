import QtQuick 2.0
import SddmComponents 2.0

Rectangle {
    id: root
    width: 1920
    height: 1080
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
        width: 600
        height: panelContent.implicitHeight + 56
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 84
        anchors.bottomMargin: 72
        color: "#f00a0c3e"
        radius: 18
        border.width: 1
        border.color: "#7a62d8ff"

        Column {
            id: panelContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 28
            spacing: 8

            Text {
                text: "SESSION SIGN-IN"
                color: root.mutedTextColor
                font.family: "Pretendard"
                font.pixelSize: 13
                font.weight: Font.Medium
            }

            Text {
                id: clock
                text: Qt.formatTime(new Date(), "HH:mm")
                color: root.textColor
                font.family: "Pretendard"
                font.pixelSize: 72
                font.weight: Font.Light
            }

            Text {
                id: dateText
                text: Qt.formatDate(new Date(), "dddd, dd MMMM yyyy")
                color: root.mutedTextColor
                font.family: "Pretendard"
                font.pixelSize: 18

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
                font.pixelSize: 13
                font.weight: Font.Medium
            }

            TextBox {
                id: username
                width: parent.width
                height: 48
                text: root.greeterUsers.lastUser
                color: root.surfaceRaised
                textColor: root.textColor
                borderColor: "#6d8cff"
                focusColor: root.focusColor
                hoverColor: root.selectionColor
                radius: 10
                font.family: "Pretendard"
                font.pixelSize: 16
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
                font.pixelSize: 13
                font.weight: Font.Medium
            }

            PasswordBox {
                id: password
                width: parent.width
                height: 48
                color: root.surfaceRaised
                textColor: root.textColor
                borderColor: "#6d8cff"
                focusColor: root.focusColor
                hoverColor: root.selectionColor
                radius: 10
                tooltipFG: root.textColor
                tooltipBG: root.surfaceRaised
                font.family: "Pretendard"
                font.pixelSize: 16
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
                font.pixelSize: 13
                font.weight: Font.Medium
            }

            Row {
                id: sessionRow
                width: parent.width
                height: 48
                spacing: 12
                z: session.activeFocus ? 10 : 1

                ComboBox {
                    id: session
                    width: parent.width - login.width - parent.spacing
                    height: 48
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
                    font.pixelSize: 14
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
                    width: 176
                    height: 48
                    radius: 10
                    enabled: !root.authenticating
                    text: root.authenticating ? "AUTHENTICATING..." : "SIGN IN"
                    color: Qt.darker(root.selectionColor, 1.25)
                    activeColor: Qt.darker(root.selectionColor, 1.4)
                    pressedColor: root.surfaceRaised
                    disabledColor: root.surface
                    textColor: root.textColor
                    font.family: "Pretendard"
                    font.pixelSize: 14
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
                height: 42
                text: root.idleMessage
                color: root.statusKind === "failure" ? root.criticalColor
                    : root.statusKind === "success" ? root.successColor
                    : root.statusKind === "authenticating" ? root.warningColor
                    : root.focusColor
                font.family: "Pretendard"
                font.pixelSize: 13
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
                height: visibleCount > 0 ? 44 : 0
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
                    height: 44
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
                    font.pixelSize: 13
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
                    height: 44
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
                    font.pixelSize: 13
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
                    height: 44
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
                    font.pixelSize: 13
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
