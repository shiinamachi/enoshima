import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets

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
    required property var theme
    required property bool reducedMotion

    screen: targetScreen
    // Keep the transparent layer mapped so Quickshell has a valid content
    // geometry before the first transient OSD event. The empty input region
    // below keeps this display-only surface fully click-through.
    visible: true
    readonly property bool showing:
        osdVisible && targetScreen.name === activeScreenName
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
        id: osdSurface
        visible: osd.showing
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 86
        width: 330
        height: 64
        radius: osd.theme.radiusPanel
        color: osd.theme.colorSurfaceOverlay
        border.width: 1
        border.color: osd.theme.colorFocusBorder

        Accessible.role: Accessible.ProgressBar
        Accessible.name: osd.osdKind === "brightness" ? "밝기" : "음량"
        Accessible.description: osd.osdMuted ? "음소거" : osd.osdValue + "%"

        IconImage {
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: 24
            implicitHeight: 24
            source: Quickshell.iconPath(osd.osdKind === "brightness"
                ? "xfpm-brightness-lcd"
                : (osd.osdMuted
                    ? "audio-volume-muted"
                    : (osd.osdValue < 34
                        ? "audio-volume-low"
                        : (osd.osdValue < 67
                            ? "audio-volume-medium"
                            : "audio-volume-high"))),
                "audio-volume-high")
            opacity: osd.osdMuted ? 0.82 : 1
            Accessible.ignored: true
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 58
            anchors.top: parent.top
            anchors.topMargin: 9
            text: osd.osdKind === "brightness" ? "밝기" : "음량"
            color: osd.theme.colorTextMuted
            font.family: "Pretendard"
            font.pixelSize: 12
            font.bold: true
        }

        Text {
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.top: parent.top
            anchors.topMargin: 8
            text: osd.osdMuted ? "음소거" : osd.osdValue + "%"
            color: osd.osdMuted ? osd.theme.colorCritical : osd.theme.colorText
            font.family: "Pretendard"
            font.pixelSize: 13
            font.bold: true
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 58
            anchors.rightMargin: 16
            anchors.bottomMargin: 13
            height: 8
            radius: height / 2
            color: osd.theme.colorTrack

            Rectangle {
                width: parent.width * Math.max(0, Math.min(100, osd.osdValue)) / 100
                height: parent.height
                radius: height / 2
                color: osd.osdMuted
                    ? osd.theme.colorCritical
                    : osd.theme.colorSelection

                Behavior on width {
                    enabled: !osd.reducedMotion
                    NumberAnimation {
                        duration: osd.theme.durationDirect
                        easing.type: Easing.OutCubic
                    }
                }
            }
        }
    }
}
