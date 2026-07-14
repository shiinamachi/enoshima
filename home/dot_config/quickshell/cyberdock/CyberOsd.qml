import QtQuick
import Quickshell
import Quickshell.Wayland

// Quickshell's generated qmltypes marks this runtime-provided window interface
// as uncreatable even though the plugin registers it for normal shell use.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: osd

    required property var targetScreen
    required property bool osdVisible
    required property string activeScreenName
    required property string osdKind
    required property int osdValue
    required property bool osdMuted

    screen: targetScreen
    visible: osdVisible && targetScreen.name === activeScreenName
    color: "transparent"
    aboveWindows: true
    focusable: false
    exclusiveZone: 0
    implicitHeight: 150

    anchors {
        left: true
        right: true
        bottom: true
    }

    WlrLayershell.namespace: "cyberosd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // The OSD is display-only; keep its transparent panel from intercepting
    // pointer input across the bottom of the active screen.
    mask: Region {}

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 86
        width: 330
        height: 64
        radius: 16
        color: "#f20a0c3e"
        border.width: 1
        border.color: "#cc62d8ff"

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            text: osd.osdKind === "brightness"
                ? "☀"
                : (osd.osdMuted ? "×" : "♪")
            color: osd.osdMuted ? "#ff5d8f" : "#62d8ff"
            font.family: "Jetendard"
            font.pixelSize: 24
            font.bold: true
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: osd.osdMuted ? "음소거" : osd.osdValue + "%"
            color: "#f2ecff"
            font.family: "Pretendard"
            font.pixelSize: 13
            font.bold: true
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 58
            anchors.rightMargin: 74
            height: 8
            radius: 4
            color: "#443f477a"

            Rectangle {
                width: parent.width * Math.max(0, Math.min(100, osd.osdValue)) / 100
                height: parent.height
                radius: 4
                color: osd.osdMuted ? "#ff5d8f" : "#9a5cff"

                Behavior on width {
                    NumberAnimation {
                        duration: 120
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }
}
