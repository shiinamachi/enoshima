import QtQuick 2.0
import SddmComponents 2.0

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: "#050623"

    property int sessionIndex: session.index

    Background {
        anchors.fill: parent
        source: "background.jpg"
        fillMode: Image.PreserveAspectCrop
    }

    Rectangle {
        anchors.fill: parent
        color: "#78050623"
    }

    Connections {
        target: sddm
        onLoginFailed: {
            password.text = ""
            status.text = "AUTHENTICATION FAILED"
            status.color = "#ff5d8f"
            password.focus = true
        }
    }

    Column {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: 88
        anchors.bottomMargin: 88
        spacing: 14

        Text {
            text: "SHIINAMACHI // ACCESS NODE"
            color: "#62d8ff"
            font.family: "Pretendard"
            font.pixelSize: 17
            font.bold: true
        }

        Text {
            id: clock
            text: Qt.formatTime(new Date(), "HH:mm")
            color: "#f2ecff"
            font.family: "Pretendard"
            font.pixelSize: 76
            font.bold: true

            Timer {
                interval: 1000
                running: true
                repeat: true
                onTriggered: clock.text = Qt.formatTime(new Date(), "HH:mm")
            }
        }

        Text {
            text: Qt.formatDate(new Date(), "dddd, dd MMMM yyyy")
            color: "#c9bfe8"
            font.family: "Pretendard"
            font.pixelSize: 19
        }

        Rectangle {
            width: 470
            height: 226
            radius: 18
            color: "#ed0a0c3e"
            border.color: "#c662d8ff"
            border.width: 2

            Column {
                anchors.fill: parent
                anchors.margins: 22
                spacing: 12

                TextBox {
                    id: username
                    width: parent.width
                    height: 46
                    text: userModel.lastUser
                    color: "#ef161151"
                    textColor: "#f2ecff"
                    borderColor: "#6d8cff"
                    focusColor: "#62d8ff"
                    hoverColor: "#e56bff"
                    radius: 10
                    font.family: "Pretendard"
                    font.pixelSize: 16
                    KeyNavigation.tab: password
                }

                PasswordBox {
                    id: password
                    width: parent.width
                    height: 46
                    color: "#ef161151"
                    textColor: "#f2ecff"
                    borderColor: "#6d8cff"
                    focusColor: "#62d8ff"
                    hoverColor: "#e56bff"
                    radius: 10
                    font.family: "Pretendard"
                    font.pixelSize: 16
                    KeyNavigation.backtab: username
                    KeyNavigation.tab: login
                    Keys.onPressed: {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            sddm.login(username.text, password.text, sessionIndex)
                            event.accepted = true
                        }
                    }
                    onTextChanged: {
                        status.text = "PASSWORD OR FINGERPRINT"
                        status.color = "#ffb86b"
                    }
                }

                Row {
                    spacing: 10

                    ComboBox {
                        id: session
                        width: 270
                        height: 42
                        model: sessionModel
                        index: sessionModel.lastIndex
                        color: "#161151"
                        textColor: "#f2ecff"
                        menuColor: "#161151"
                        borderColor: "#6d8cff"
                        focusColor: "#62d8ff"
                        hoverColor: "#e56bff"
                        arrowColor: "#62d8ff"
                        font.family: "Pretendard"
                        font.pixelSize: 14
                    }

                    Button {
                        id: login
                        width: 144
                        height: 42
                        text: "ENTER"
                        color: "#9a5cff"
                        activeColor: "#62d8ff"
                        pressedColor: "#e56bff"
                        textColor: "#050623"
                        font.family: "Pretendard"
                        font.pixelSize: 15
                        onClicked: sddm.login(username.text, password.text, sessionIndex)
                    }
                }

                Text {
                    id: status
                    text: "PASSWORD OR FINGERPRINT"
                    color: "#ffb86b"
                    font.family: "Pretendard"
                    font.pixelSize: 12
                }
            }
        }

        Row {
            spacing: 22

            Text {
                text: "SUSPEND"
                color: "#62d8ff"
                visible: sddm.canSuspend
                font.family: "Pretendard"
                font.pixelSize: 13
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: sddm.suspend()
                }
            }

            Text {
                text: "REBOOT"
                color: "#ffb86b"
                font.family: "Pretendard"
                font.pixelSize: 13
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: sddm.reboot()
                }
            }

            Text {
                text: "POWER OFF"
                color: "#ff5d8f"
                font.family: "Pretendard"
                font.pixelSize: 13
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: sddm.powerOff()
                }
            }
        }
    }

    Component.onCompleted: {
        if (username.text === "")
            username.focus = true
        else
            password.focus = true
    }
}
