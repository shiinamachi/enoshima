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
    readonly property bool koreanLocale:
        String(Quickshell.env("LANG") || "").toLowerCase().startsWith("ko")
    readonly property bool criticalState:
        osdMuted && (osdKind === "volume" || osdKind === "microphone")

    function titleFor(kind) {
        const labels = {
            "volume": ["음량", "Volume"],
            "microphone": ["마이크", "Microphone"],
            "brightness": ["밝기", "Brightness"],
            "keyboard-backlight": ["키보드 백라이트", "Keyboard backlight"],
            "airplane-mode": ["비행기 모드", "Airplane mode"]
        };
        const value = labels[String(kind || "")] || ["시스템", "System"];
        return koreanLocale ? value[0] : value[1];
    }

    function valueText() {
        if (osdKind === "airplane-mode")
            return osdMuted
                ? (koreanLocale ? "켜짐" : "On")
                : (koreanLocale ? "꺼짐" : "Off");
        if (osdMuted)
            return koreanLocale ? "음소거" : "Muted";
        return osdValue + "%";
    }

    function iconName() {
        if (osdKind === "brightness")
            return "xfpm-brightness-lcd";
        if (osdKind === "keyboard-backlight")
            return "keyboard-brightness-symbolic";
        if (osdKind === "microphone")
            return osdMuted ? "microphone-sensitivity-muted-symbolic" : "audio-input-microphone-symbolic";
        if (osdKind === "airplane-mode")
            return osdMuted ? "airplane-mode-symbolic" : "network-wireless-signal-good-symbolic";
        return osdMuted ? "audio-volume-muted"
            : (osdValue < 34 ? "audio-volume-low"
                : (osdValue < 67 ? "audio-volume-medium" : "audio-volume-high"));
    }

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
        Accessible.name: osd.titleFor(osd.osdKind)
        Accessible.description: osd.valueText()

        IconImage {
            anchors.left: parent.left
            anchors.leftMargin: 18
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: 24
            implicitHeight: 24
            source: Quickshell.iconPath(osd.iconName(),
                "audio-volume-high")
            opacity: osd.osdMuted ? 0.82 : 1
            Accessible.ignored: true
        }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 58
            anchors.top: parent.top
            anchors.topMargin: 9
            text: osd.titleFor(osd.osdKind)
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
            text: osd.valueText()
            color: osd.criticalState ? osd.theme.colorCritical : osd.theme.colorText
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
                color: osd.criticalState
                    ? osd.theme.colorCritical
                    : (osd.osdKind === "airplane-mode" && osd.osdMuted
                        ? osd.theme.colorInfo : osd.theme.colorSelection)

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
