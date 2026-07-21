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
    readonly property var cells: uniqueTargetCells(flattenCells(layouts))

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

    function uniqueTargetCells(sourceCells) {
        const result = [];
        const seen = {};
        for (const cell of sourceCells) {
            const target = String(cell.target || "");
            if (target === "" || seen[target])
                continue;
            seen[target] = true;
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
            const selectedTarget = String(chooserState.selectedTarget
                || snapState.target || "");
            selectedIndex = Math.max(0, cells.findIndex(
                cell => String(cell.target || "") === selectedTarget));
            selectedCellId = cells.length > 0
                ? String(cells[selectedIndex].cellId || "") : "";
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
        readonly property int targetCount: Math.max(1, assist.cells.length)
        width: Math.min(assist.width - 32,
            28 + targetCount * 44 + (targetCount - 1) * 4)
        height: 110
        x: Math.round((assist.width - width) / 2)
        y: 16
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
                anchors.margins: 14
                spacing: 8

                Row {
                    width: parent.width
                    height: 22

                    Text {
                        width: 134
                        text: assist.koreanLocale ? "스냅 레이아웃" : "Snap layouts"
                        color: assist.theme.colorText
                        font.family: "Pretendard"
                        font.pixelSize: 14
                        font.bold: true
                    }

                    Text {
                        width: parent.width - 134
                        horizontalAlignment: Text.AlignRight
                        text: assist.koreanLocale
                            ? "방향키 · Enter · Esc"
                            : "Arrows · Enter · Esc"
                        color: assist.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 10
                    }
                }

                Grid {
                    columns: chooserPanel.targetCount
                    columnSpacing: 4
                    rowSpacing: 0

                    Repeater {
                        model: assist.cells

                        delegate: Rectangle {
                            id: targetCard
                            required property var modelData
                            required property int index
                            readonly property bool selected:
                                index === assist.selectedIndex
                            width: 44
                            height: 52
                            radius: assist.theme.radiusSmall
                            color: selected
                                ? assist.theme.colorFocusSelected
                                : (targetMouse.containsMouse
                                    ? assist.theme.colorFocusHover
                                    : assist.theme.colorSurfaceSubtle)
                            border.width: selected ? 2 : 1
                            border.color: selected
                                ? assist.theme.colorFocus
                                : assist.theme.colorQuietBorder

                            Rectangle {
                                x: 5 + Number(targetCard.modelData.x || 0) * 34
                                y: 5 + Number(targetCard.modelData.y || 0) * 42
                                width: Math.max(7,
                                    Number(targetCard.modelData.width || 1) * 34 - 1)
                                height: Math.max(7,
                                    Number(targetCard.modelData.height || 1) * 42 - 1)
                                radius: 3
                                color: targetCard.selected
                                    ? assist.theme.colorSelectionStrong
                                    : assist.theme.colorRaisedSoft
                                border.width: 1
                                border.color: targetCard.selected
                                    ? assist.theme.colorFocus
                                    : assist.theme.colorInfoBorder
                            }

                            Accessible.role: Accessible.Button
                            Accessible.name: assist.labelFor(modelData.target)
                            Accessible.focused: selected
                            Accessible.onPressAction: assist.choose(
                                String(modelData.cellId || ""), true)

                            MouseArea {
                                id: targetMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: {
                                    assist.selectedIndex = targetCard.index;
                                    assist.selectedCellId = String(
                                        targetCard.modelData.cellId || "");
                                    assist.choose(assist.selectedCellId, false);
                                }
                                onClicked: assist.choose(String(
                                    targetCard.modelData.cellId || ""), true)
                            }
                        }
                    }
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
