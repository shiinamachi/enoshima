pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// A display-only preview for the geometry selected by the native title-bar
// drag path or the shared keyboard snap controller.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: assist

    required property var targetScreen
    required property var snapState
    required property var theme
    required property bool reducedMotion
    required property bool reducedTransparency

    readonly property bool fresh: Number(snapState.updatedAt || 0) > 0
        && Date.now() - Number(snapState.updatedAt) <= 900
    readonly property bool showing: Boolean(snapState.active)
        && fresh
        && String(snapState.monitor || "") === String(targetScreen.name || "")
    readonly property var geometry: snapState.geometry || ({})

    screen: targetScreen
    visible: true
    color: "transparent"
    aboveWindows: true
    focusable: false
    exclusiveZone: 0

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    WlrLayershell.namespace: "enoshima-snap-assist"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    mask: Region {}

    Rectangle {
        id: preview
        visible: assist.showing
        x: Number(assist.geometry.localX || 0)
        y: Number(assist.geometry.localY || 0)
        width: Math.max(0, Number(assist.geometry.width || 0))
        height: Math.max(0, Number(assist.geometry.height || 0))
        radius: assist.theme.radiusPanel
        color: assist.reducedTransparency
            ? assist.theme.colorRaisedOverlay
            : assist.theme.colorSelectionSoft
        border.width: 2
        border.color: assist.theme.colorFocus
        opacity: assist.showing ? 1 : 0

        Accessible.role: Accessible.Indicator
        Accessible.name: "창 배치 미리보기"
        Accessible.description: String(assist.snapState.label || "")

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: 12
            anchors.topMargin: 12
            width: Math.min(214, labelRow.implicitWidth + 24)
            height: 34
            radius: assist.theme.radiusSmall
            color: assist.theme.colorSurfaceOverlay
            border.width: 1
            border.color: assist.theme.colorFocusBorder

            Row {
                id: labelRow
                anchors.centerIn: parent
                spacing: 8

                Text {
                    text: String(assist.snapState.label || "창 배치")
                    color: assist.theme.colorText
                    font.family: "Pretendard"
                    font.pixelSize: 12
                    font.bold: true
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 1
                    height: 14
                    color: assist.theme.colorDivider
                }

                Text {
                    text: "Esc 취소"
                    color: assist.theme.colorTextMuted
                    font.family: "Pretendard"
                    font.pixelSize: 11
                }
            }
        }

        Behavior on x {
            enabled: !assist.reducedMotion
            NumberAnimation { duration: assist.theme.durationDirect; easing.type: Easing.OutCubic }
        }
        Behavior on y {
            enabled: !assist.reducedMotion
            NumberAnimation { duration: assist.theme.durationDirect; easing.type: Easing.OutCubic }
        }
        Behavior on width {
            enabled: !assist.reducedMotion
            NumberAnimation { duration: assist.theme.durationDirect; easing.type: Easing.OutCubic }
        }
        Behavior on height {
            enabled: !assist.reducedMotion
            NumberAnimation { duration: assist.theme.durationDirect; easing.type: Easing.OutCubic }
        }
        Behavior on opacity {
            enabled: !assist.reducedMotion
            NumberAnimation { duration: assist.theme.durationFast }
        }
    }
}
