import QtQuick 2.0
import SddmComponents 2.0

Rectangle {
    id: root
    width: 1920
    height: 1080
    color: "#070b2a"

    property int sessionIndex: session.index

    Background {
        anchors.fill: parent
        source: "background.png"
        fillMode: Image.PreserveAspectCrop
    }

    Rectangle {
        anchors.fill: parent
        color: "#73070b2a"
    }

    Connections {
        target: sddm
        onLoginFailed: {
            password.text = ""
            status.text = "AUTHENTICATION FAILED"
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
            color: "#33d6ff"
            font.family: "Pretendard"
            font.pixelSize: 17
            font.bold: true
        }

        Text {
            id: clock
            text: Qt.formatTime(new Date(), "HH:mm")
            color: "#e9e8ff"
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
            color: "#c6c4e8"
            font.family: "Pretendard"
            font.pixelSize: 19
        }

        Rectangle {
            width: 470
            height: 226
            radius: 18
            color: "#e6111447"
            border.color: "#aa33d6ff"
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
                    color: "#ee111447"
                    textColor: "#e9e8ff"
                    borderColor: "#8b5cff"
                    focusColor: "#33d6ff"
                    hoverColor: "#ff3cc7"
                    radius: 10
                    font.family: "Pretendard"
                    font.pixelSize: 16
                    KeyNavigation.tab: password
                }

                PasswordBox {
                    id: password
                    width: parent.width
                    height: 46
                    color: "#ee111447"
                    textColor: "#e9e8ff"
                    borderColor: "#8b5cff"
                    focusColor: "#33d6ff"
                    hoverColor: "#ff3cc7"
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
                }

                Row {
                    spacing: 10

                    ComboBox {
                        id: session
                        width: 270
                        height: 42
                        model: sessionModel
                        index: sessionModel.lastIndex
                        color: "#111447"
                        textColor: "#e9e8ff"
                        menuColor: "#111447"
                        borderColor: "#8b5cff"
                        focusColor: "#33d6ff"
                        hoverColor: "#ff3cc7"
                        arrowColor: "#33d6ff"
                        font.family: "Pretendard"
                        font.pixelSize: 14
                    }

                    Button {
                        id: login
                        width: 144
                        height: 42
                        text: "ENTER"
                        color: "#8b5cff"
                        activeColor: "#33d6ff"
                        pressedColor: "#ff3cc7"
                        textColor: "#070b2a"
                        font.family: "Pretendard"
                        font.pixelSize: 15
                        onClicked: sddm.login(username.text, password.text, sessionIndex)
                    }
                }

                Text {
                    id: status
                    text: "PASSWORD OR FINGERPRINT"
                    color: "#ffb84d"
                    font.family: "Pretendard"
                    font.pixelSize: 12
                }
            }
        }

        Row {
            spacing: 22

            Text {
                text: "SUSPEND"
                color: "#33d6ff"
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
                color: "#ffb84d"
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
                color: "#ff426d"
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
