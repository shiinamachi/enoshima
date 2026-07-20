pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

// One broker-owned state drives edge previews and the keyboard/pointer layout
// chooser. The compositor never launches a process for pointer updates.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: assist

    required property var targetScreen
    required property var snapState
    required property var theme
    required property bool reducedMotion
    required property bool reducedTransparency

    property int selectedIndex: 0
    property string selectedCellId: ""
    property string observedSession: ""
    readonly property bool koreanLocale:
        String(Quickshell.env("LANG") || "").toLowerCase().startsWith("ko")
    readonly property bool fresh: Number(snapState.updatedAt || 0) > 0
        && Date.now() - Number(snapState.updatedAt) <= 15100
    readonly property bool showing: Boolean(snapState.active)
        && fresh
        && String(snapState.monitor || "") === String(targetScreen.name || "")
    readonly property var geometry: snapState.geometry || ({})
    readonly property var chooserState: snapState.chooser || ({})
    readonly property bool showingChooser: showing
        && Boolean(chooserState.visible)
    readonly property var layouts: Array.isArray(chooserState.layouts)
        ? chooserState.layouts : []
    readonly property var cells: flattenCells(layouts)

    screen: targetScreen
    visible: true
    color: "transparent"
    aboveWindows: true
    focusable: showingChooser
    exclusiveZone: 0

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    WlrLayershell.namespace: "enoshima-snap-assist"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: showingChooser
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    mask: Region { item: assist.showingChooser ? chooserPanel : null }

    function flattenCells(sourceLayouts) {
        const result = [];
        for (const layout of sourceLayouts) {
            for (const cell of (layout.cells || []))
                result.push(cell);
        }
        return result;
    }

    function labelFor(target) {
        const labels = {
            "left-half": ["왼쪽 절반", "Left half"],
            "right-half": ["오른쪽 절반", "Right half"],
            "upper-left": ["왼쪽 위", "Upper left"],
            "upper-right": ["오른쪽 위", "Upper right"],
            "lower-left": ["왼쪽 아래", "Lower left"],
            "lower-right": ["오른쪽 아래", "Lower right"],
            "bottom-half": ["아래쪽 절반", "Bottom half"],
            "left-third": ["왼쪽 1/3", "Left third"],
            "center-third": ["가운데 1/3", "Center third"],
            "right-third": ["오른쪽 1/3", "Right third"],
            "left-two-thirds": ["왼쪽 2/3", "Left two thirds"],
            "right-two-thirds": ["오른쪽 2/3", "Right two thirds"],
            "maximize": ["최대화", "Maximize"]
        };
        const value = labels[String(target || "")] || ["창 배치", "Snap window"];
        return koreanLocale ? value[0] : value[1];
    }

    function choose(cellId, commit) {
        if (!cellId)
            return;
        Quickshell.execDetached([
            "enoshima-snap-controller", "choose", String(cellId),
            ...(commit ? ["--commit"] : [])
        ]);
    }

    function selectIndex(index, commit) {
        if (cells.length === 0)
            return;
        selectedIndex = (index + cells.length) % cells.length;
        selectedCellId = String(cells[selectedIndex].cellId || "");
        choose(selectedCellId, commit);
    }

    function cancel() {
        Quickshell.execDetached(["enoshima-snap-controller", "cancel"]);
    }

    function handleKey(event) {
        if (!showingChooser)
            return;
        if (event.key === Qt.Key_Escape) {
            cancel();
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Space) {
            selectIndex(selectedIndex, true);
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Right || event.key === Qt.Key_Down
                || event.key === Qt.Key_Tab) {
            selectIndex(selectedIndex + (event.modifiers & Qt.ShiftModifier ? -1 : 1), false);
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Up
                || event.key === Qt.Key_Backtab) {
            selectIndex(selectedIndex - 1, false);
            event.accepted = true;
            return;
        }
        if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
            selectIndex(Number(event.key - Qt.Key_1), true);
            event.accepted = true;
        }
    }

    onShowingChooserChanged: {
        if (!showingChooser)
            return;
        const session = String(snapState.session || "");
        if (session !== observedSession) {
            observedSession = session;
            selectedCellId = String(chooserState.selectedCellId || "");
            selectedIndex = Math.max(0, cells.findIndex(
                cell => String(cell.cellId || "") === selectedCellId));
        }
        Qt.callLater(() => keyboardInput.forceActiveFocus());
    }

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
        Accessible.name: assist.koreanLocale ? "창 배치 미리보기" : "Window placement preview"
        Accessible.description: assist.labelFor(assist.snapState.target)

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            width: 48
            height: 4
            radius: 2
            color: assist.theme.colorFocus
        }

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: 12
            anchors.topMargin: 12
            width: Math.min(222, previewLabel.implicitWidth + 24)
            height: 34
            radius: assist.theme.radiusSmall
            color: assist.theme.colorSurfaceOverlay
            border.width: 1
            border.color: assist.theme.colorFocusBorder

            Text {
                id: previewLabel
                anchors.centerIn: parent
                text: assist.labelFor(assist.snapState.target)
                    + (assist.showingChooser
                        ? ""
                        : (assist.koreanLocale ? "  ·  Esc 취소" : "  ·  Esc to cancel"))
                color: assist.theme.colorText
                font.family: "Pretendard"
                font.pixelSize: 12
                font.bold: true
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

    Rectangle {
        id: chooserPanel
        visible: assist.showingChooser
        width: 356
        height: 314
        x: Math.round((assist.width - width) / 2)
        y: 58
        radius: assist.theme.radiusPanel
        color: assist.theme.colorSurfaceOverlay
        border.width: 1
        border.color: assist.theme.colorFocusBorder

        Accessible.role: Accessible.Dialog
        Accessible.name: assist.koreanLocale ? "스냅 레이아웃" : "Snap layouts"

        Item {
            id: keyboardInput
            anchors.fill: parent
            focus: assist.showingChooser
            Keys.onPressed: event => assist.handleKey(event)

            Column {
                anchors.fill: parent
                anchors.margins: 18
                spacing: 12

                Row {
                    width: parent.width
                    height: 28

                    Text {
                        width: parent.width - 34
                        text: assist.koreanLocale ? "스냅 레이아웃" : "Snap layouts"
                        color: assist.theme.colorText
                        font.family: "Pretendard"
                        font.pixelSize: 15
                        font.bold: true
                    }

                    Text {
                        width: 34
                        horizontalAlignment: Text.AlignRight
                        text: "Esc"
                        color: assist.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 11
                    }
                }

                Grid {
                    columns: 2
                    columnSpacing: 10
                    rowSpacing: 10

                    Repeater {
                        model: assist.layouts

                        delegate: Rectangle {
                            id: layoutCard
                            required property var modelData
                            width: 155
                            height: 68
                            radius: assist.theme.radiusSmall
                            color: assist.theme.colorSurfaceSubtle
                            border.width: 1
                            border.color: assist.theme.colorQuietBorder

                            Repeater {
                                model: layoutCard.modelData.cells || []

                                delegate: Rectangle {
                                    id: cell
                                    required property var modelData
                                    readonly property int flatIndex: assist.cells.findIndex(
                                        item => String(item.cellId || "")
                                            === String(modelData.cellId || ""))
                                    x: 6 + Number(modelData.x || 0) * 143
                                    y: 6 + Number(modelData.y || 0) * 56
                                    width: Math.max(40, Number(modelData.width || 1) * 143 - 3)
                                    height: Math.max(25, Number(modelData.height || 1) * 56 - 3)
                                    radius: 5
                                    color: cell.flatIndex === assist.selectedIndex
                                        ? assist.theme.colorFocusSelected
                                        : (cellMouse.containsMouse
                                            ? assist.theme.colorFocusHover
                                            : assist.theme.colorRaisedSoft)
                                    border.width: cell.flatIndex === assist.selectedIndex ? 2 : 1
                                    border.color: cell.flatIndex === assist.selectedIndex
                                        ? assist.theme.colorFocus
                                        : assist.theme.colorInfoBorder

                                    Accessible.role: Accessible.Button
                                    Accessible.name: assist.labelFor(cell.modelData.target)
                                    Accessible.focused: cell.flatIndex === assist.selectedIndex

                                    MouseArea {
                                        id: cellMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onEntered: {
                                            assist.selectedIndex = cell.flatIndex;
                                            assist.selectedCellId = String(cell.modelData.cellId || "");
                                            assist.choose(assist.selectedCellId, false);
                                        }
                                        onClicked: assist.choose(String(cell.modelData.cellId || ""), true)
                                    }
                                }
                            }
                        }
                    }
                }

                Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: assist.koreanLocale
                        ? "방향키로 이동 · Enter로 적용"
                        : "Arrow keys to move · Enter to apply"
                    color: assist.theme.colorTextMuted
                    font.family: "Pretendard"
                    font.pixelSize: 11
                }
            }
        }

        opacity: assist.showingChooser ? 1 : 0
        scale: assist.showingChooser ? 1 : 0.98

        Behavior on opacity {
            enabled: !assist.reducedMotion
            NumberAnimation { duration: assist.theme.durationEnter }
        }
        Behavior on scale {
            enabled: !assist.reducedMotion
            NumberAnimation { duration: assist.theme.durationEnter; easing.type: Easing.OutCubic }
        }
    }
}
