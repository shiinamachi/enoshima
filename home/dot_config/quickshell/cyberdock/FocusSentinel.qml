pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: sentinel

    required property var targetScreen
    required property bool pulseActive
    required property string activeScreenName
    required property string targetAddress

    signal pulseCompleted()

    screen: targetScreen
    visible: pulseActive && targetScreen.name === activeScreenName
    color: "transparent"
    focusable: true
    aboveWindows: true
    implicitWidth: 2
    implicitHeight: 2
    exclusionMode: ExclusionMode.Ignore

    anchors {
        left: true
        top: true
    }

    WlrLayershell.namespace: "kakao-focus-sentinel"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    onVisibleChanged: {
        if (visible)
            returnFocus.restart();
    }

    Timer {
        id: returnFocus
        interval: 90
        repeat: false
        onTriggered: {
            Quickshell.execDetached([
                "desktop-window-action", "focus", "--address", sentinel.targetAddress
            ]);
            sentinel.pulseCompleted();
        }
    }
}
