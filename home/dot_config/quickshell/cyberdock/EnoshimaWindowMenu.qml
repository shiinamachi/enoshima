pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: menu

    required property var targetScreen
    required property bool menuOpen
    required property string activeScreenName
    required property string targetAddress
    required property var targetWindow
    required property int anchorX
    required property int anchorY
    required property string invocationSource
    required property var strings
    required property var theme
    required property bool reducedMotion
    required property string reviewState

    signal closeRequested()

    property int selectedIndex: 0
    property string adjustmentMode: ""
    property string adjustmentTransaction: ""
    property string adjustmentProcessPhase: ""
    property string pendingAdjustmentMode: ""
    property bool actionRunning: false
    property string lastAttemptedAction: ""
    property string failedActionId: ""
    property string actionErrorKey: ""
    readonly property bool koreanLocale:
        String(Quickshell.env("LANG") || "").toLowerCase().startsWith("ko")
    readonly property bool showing: menuOpen
        && targetScreen.name === activeScreenName
        && /^0x[0-9A-Fa-f]+$/.test(targetAddress)
        && Object.keys(targetWindow || {}).length > 0
    readonly property var entries: [
        {"id": "restore", "labelKey": "windowMenu.restore", "icon": "window-restore-symbolic", "key": "R"},
        {"id": "move", "labelKey": "windowMenu.move", "icon": "transform-move-symbolic", "key": "M"},
        {"id": "resize", "labelKey": "windowMenu.resize", "icon": "transform-scale-symbolic", "key": "S"},
        {"id": "minimize", "labelKey": "windowMenu.minimize", "icon": "window-minimize-symbolic", "key": "N"},
        {"id": "maximize", "labelKey": "windowMenu.maximize", "icon": "window-maximize-symbolic", "key": "X"},
        {"id": "close", "labelKey": "windowMenu.close", "icon": "window-close-symbolic", "key": "Alt+F4"}
    ]

    screen: targetScreen
    visible: showing
    color: "transparent"
    aboveWindows: true
    focusable: showing
    exclusiveZone: 0

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    WlrLayershell.namespace: "enoshima-window-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: showing
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    mask: Region { item: menu.showing ? scrimInput : null }

    onShowingChanged: {
        if (showing) {
            selectedIndex = 0;
            adjustmentMode = "";
            adjustmentTransaction = "";
            actionRunning = false;
            actionErrorKey = "";
            failedActionId = "";
            selectedIndex = firstEnabledIndex();
            applyReviewState();
            Qt.callLater(() => scrimInput.forceActiveFocus());
        }
    }

    onReviewStateChanged: Qt.callLater(() => applyReviewState())

    function applyReviewState() {
        if (!showing || reviewState === "")
            return;
        actionRunning = reviewState === "action-running";
        lastAttemptedAction = actionRunning ? "maximize" : "";
        failedActionId = reviewState === "action-error" ? "maximize" : "";
        actionErrorKey = reviewState === "action-error"
            ? "windowMenu.actionFailed" : "";
        if (actionErrorKey !== "")
            errorDismissTimer.stop();
    }

    onTargetWindowChanged: {
        if (menuOpen && Object.keys(targetWindow || {}).length === 0) {
            if (actionRunning && lastAttemptedAction === "close")
                return;
            if (actionRunning || adjustmentMode !== "" || adjustmentProcess.running)
                showActionError("windowMenu.windowClosed", lastAttemptedAction);
            else
                closeRequested();
        }
    }

    function textFor(key, fallback) {
        return String(strings && strings[key] || fallback || key);
    }

    function labelFor(entry) {
        return textFor(entry.labelKey, entry.id);
    }

    function isFullscreen() {
        return Number(targetWindow.fullscreen || targetWindow.fullscreenClient || 0) > 0;
    }

    function entryEnabled(entry) {
        if (actionRunning || actionErrorKey !== "")
            return false;
        if (entry.id === "restore")
            return isFullscreen();
        if (entry.id === "maximize")
            return !isFullscreen();
        if (entry.id === "move" || entry.id === "resize") {
            const grouped = targetWindow.grouped || [];
            return !isFullscreen() && grouped.length === 0;
        }
        return true;
    }

    function firstEnabledIndex() {
        return Math.max(0, entries.findIndex(entry => entryEnabled(entry)));
    }

    function moveSelection(delta) {
        let candidate = selectedIndex;
        for (let step = 0; step < entries.length; ++step) {
            candidate = (candidate + delta + entries.length) % entries.length;
            if (entryEnabled(entries[candidate])) {
                selectedIndex = candidate;
                return;
            }
        }
    }

    function processResult(text) {
        const lines = String(text || "").trim().split("\n").filter(line => line !== "");
        for (let index = lines.length - 1; index >= 0; --index) {
            try {
                const result = JSON.parse(lines[index]);
                if (result.schema === 1)
                    return result;
            } catch (error) {
                // A backend may have written diagnostics before the result.
            }
        }
        return {};
    }

    function showActionError(messageKey, actionId) {
        if (adjustmentTransaction !== "")
            Quickshell.execDetached(["desktop-window-action", "commit-adjust",
                "--transaction", adjustmentTransaction, "--json"]);
        adjustmentTransaction = "";
        adjustmentMode = "";
        pendingAdjustmentMode = "";
        actionRunning = false;
        failedActionId = String(actionId || lastAttemptedAction || "close");
        actionErrorKey = String(messageKey || "windowMenu.actionFailed");
        errorDismissTimer.restart();
        Qt.callLater(() => scrimInput.forceActiveFocus());
    }

    function finishAdjustment(commit) {
        if (adjustmentTransaction === "" || adjustmentProcess.running)
            return;
        adjustmentProcessPhase = "finish";
        actionRunning = true;
        adjustmentProcess.command = [
            "desktop-window-action", commit ? "commit-adjust" : "cancel-adjust",
            "--transaction", adjustmentTransaction, "--json"
        ];
        adjustmentProcess.running = true;
    }

    function dismiss() {
        if (actionErrorKey !== "") {
            closeRequested();
            return;
        }
        if (adjustmentMode !== "")
            finishAdjustment(false);
        else
            closeRequested();
    }

    function runWindowAction(action, displayAction) {
        if (actionProcess.running)
            return;
        lastAttemptedAction = String(displayAction || action);
        failedActionId = lastAttemptedAction;
        actionRunning = true;
        actionProcess.command = [
            "desktop-window-action", action,
            "--address", targetAddress,
            "--origin", "titlebar", "--json"
        ];
        actionProcess.running = true;
    }

    function beginAdjustment(mode) {
        if (adjustmentProcess.running)
            return;
        const transaction = String(targetAddress).replace(/^0x/, "")
            + "-" + String(Date.now());
        lastAttemptedAction = mode;
        failedActionId = mode;
        pendingAdjustmentMode = mode;
        adjustmentTransaction = transaction;
        adjustmentProcessPhase = "begin";
        actionRunning = true;
        adjustmentProcess.command = [
            "desktop-window-action", "begin-adjust",
            "--address", targetAddress,
            "--transaction", transaction,
            "--mode", mode,
            "--json"
        ];
        adjustmentProcess.running = true;
    }

    function trigger(entry) {
        if (!entry || !entryEnabled(entry))
            return;
        switch (entry.id) {
        case "restore":
            if (Number(targetWindow.fullscreen || targetWindow.fullscreenClient || 0) > 0)
                runWindowAction("maximize", "restore");
            break;
        case "move":
        case "resize":
            beginAdjustment(entry.id);
            break;
        case "minimize":
        case "maximize":
        case "close":
            runWindowAction(entry.id);
            break;
        }
    }

    function adjust(key) {
        const step = 20;
        let x = 0;
        let y = 0;
        if (key === Qt.Key_Left)
            x = -step;
        else if (key === Qt.Key_Right)
            x = step;
        else if (key === Qt.Key_Up)
            y = -step;
        else if (key === Qt.Key_Down)
            y = step;
        else
            return false;
        if (adjustmentProcess.running)
            return false;
        adjustmentProcessPhase = "step";
        adjustmentProcess.command = [
            "desktop-window-action",
            "adjust-step",
            "--transaction", adjustmentTransaction,
            "--x", String(x), "--y", String(y),
            "--json"
        ];
        adjustmentProcess.running = true;
        return true;
    }

    function handleKey(event) {
        if (actionErrorKey !== "") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return
                    || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                closeRequested();
                event.accepted = true;
            }
            return;
        }
        if (actionRunning) {
            if (event.key === Qt.Key_Escape && adjustmentMode === "") {
                closeRequested();
                event.accepted = true;
            }
            return;
        }
        if (event.key === Qt.Key_Escape) {
            if (adjustmentMode !== "")
                finishAdjustment(false);
            else
                closeRequested();
            event.accepted = true;
            return;
        }
        if (adjustmentMode !== "") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                finishAdjustment(true);
                event.accepted = true;
            } else if (adjust(event.key)) {
                event.accepted = true;
            }
            return;
        }
        if (event.key === Qt.Key_F4
                && (event.modifiers & Qt.AltModifier)) {
            const closeIndex = entries.findIndex(entry => entry.id === "close");
            if (closeIndex >= 0) {
                selectedIndex = closeIndex;
                trigger(entries[closeIndex]);
                event.accepted = true;
            }
            return;
        }
        if (event.key === Qt.Key_Up) {
            moveSelection(-1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Down) {
            moveSelection(1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            trigger(entries[selectedIndex]);
            event.accepted = true;
        } else {
            const pressed = String(event.text || "").toUpperCase();
            const index = entries.findIndex(entry => entry.key === pressed);
            if (index >= 0 && entryEnabled(entries[index])) {
                selectedIndex = index;
                trigger(entries[index]);
                event.accepted = true;
            }
        }
    }

    Timer {
        id: errorDismissTimer
        interval: 1500
        repeat: false
        onTriggered: menu.closeRequested()
    }

    // Quickshell's qmltypes omit the private QProcess exit-status enum while
    // the runtime signal remains available.
    // qmllint disable signal-handler-parameters
    Process {
        id: actionProcess
        stdout: StdioCollector {
            id: actionOutput
            waitForEnd: true
        }
        onExited: exitCode => {
            const result = menu.processResult(actionOutput.text);
            menu.actionRunning = false;
            if (exitCode === 0 && result.ok !== false)
                menu.closeRequested();
            else
                menu.showActionError(result.messageKey || "windowMenu.actionFailed",
                    menu.lastAttemptedAction);
        }
    }

    Process {
        id: adjustmentProcess
        stdout: StdioCollector {
            id: adjustmentOutput
            waitForEnd: true
        }
        onExited: exitCode => {
            const result = menu.processResult(adjustmentOutput.text);
            if (exitCode !== 0 || result.ok === false) {
                menu.showActionError(result.messageKey || "windowMenu.adjustmentFailed",
                    menu.lastAttemptedAction);
                return;
            }
            if (menu.adjustmentProcessPhase === "begin") {
                menu.adjustmentMode = menu.pendingAdjustmentMode;
                menu.pendingAdjustmentMode = "";
                menu.actionRunning = false;
            } else if (menu.adjustmentProcessPhase === "finish") {
                menu.actionRunning = false;
                menu.adjustmentMode = "";
                menu.adjustmentTransaction = "";
                menu.closeRequested();
            }
            menu.adjustmentProcessPhase = "";
        }
    }
    // qmllint enable signal-handler-parameters

    Rectangle {
        id: scrimInput
        anchors.fill: parent
        color: menu.theme.colorScrim
        focus: true

        Keys.onPressed: event => menu.handleKey(event)

        MouseArea {
            anchors.fill: parent
            onClicked: menu.dismiss()
        }

        Rectangle {
            id: menuCard
            x: Math.max(14, Math.min(menu.anchorX,
                parent.width - width - 14))
            y: Math.max(14, Math.min(menu.anchorY,
                parent.height - height - 14))
            width: 300
            height: menu.adjustmentMode === ""
                ? 354 + (menu.actionErrorKey !== "" ? 12 : 0)
                : 164
            radius: menu.theme.radiusPanel
            color: menu.theme.colorSurfaceOverlay
            border.width: 1
            border.color: menu.theme.colorFocusBorder

            Accessible.role: Accessible.List
            Accessible.name: menu.textFor("windowMenu.systemMenu", "System window menu")

            MouseArea {
                anchors.fill: parent
                onClicked: mouse => mouse.accepted = true
            }

            Column {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 4

                Text {
                    width: parent.width
                    height: 34
                    text: menu.adjustmentMode === ""
                        ? String(menu.targetWindow.title
                            || menu.textFor("windowMenu.application", "Application"))
                        : (menu.adjustmentMode === "move"
                            ? menu.textFor("windowMenu.moveTitle", "Move window")
                            : menu.textFor("windowMenu.resizeTitle", "Resize window"))
                    elide: Text.ElideRight
                    color: menu.theme.colorText
                    font.family: "Pretendard"
                    font.pixelSize: 13
                    font.bold: true
                    verticalAlignment: Text.AlignVCenter
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    color: menu.theme.colorDivider
                }

                Repeater {
                    model: menu.adjustmentMode === "" ? menu.entries : []

                    Rectangle {
                        id: menuEntry
                        required property var modelData
                        required property int index
                        readonly property bool errorRow:
                            menu.actionErrorKey !== ""
                            && modelData.id === menu.failedActionId
                        readonly property bool available:
                            menu.entryEnabled(modelData)
                        width: parent.width
                        height: errorRow ? 56 : 44
                        radius: menu.theme.radiusSmall
                        color: errorRow
                            ? menu.theme.colorSurfaceSubtle
                            : (!available
                            ? "transparent"
                            : (index === menu.selectedIndex
                            ? menu.theme.colorFocusSelected
                            : (entryMouse.containsMouse
                                ? menu.theme.colorFocusHover
                                : "transparent")))
                        border.width: errorRow || (index === menu.selectedIndex && available) ? 1 : 0
                        border.color: errorRow
                            ? menu.theme.colorCritical : menu.theme.colorFocus
                        opacity: available || errorRow ? 1 : 0.5

                        Accessible.role: Accessible.ListItem
                        Accessible.name: menuEntry.errorRow
                            ? menu.textFor(menu.actionErrorKey, "The window action could not be completed")
                            : menu.labelFor(menuEntry.modelData)
                        Accessible.description: menuEntry.errorRow
                            ? menu.textFor("windowMenu.dismiss", "Dismiss")
                            : (menuEntry.available
                            ? menuEntry.modelData.key
                            : menu.textFor("windowMenu.unavailable", "Unavailable"))
                        Accessible.onPressAction: menuEntry.errorRow
                            ? menu.closeRequested() : menu.trigger(menuEntry.modelData)

                        IconImage {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: 18
                            implicitHeight: 18
                            source: Quickshell.iconPath(menuEntry.errorRow
                                ? "dialog-error-symbolic" : menuEntry.modelData.icon,
                                "application-x-executable")
                            opacity: menuEntry.available ? 1 : 0.56
                            Accessible.ignored: true
                        }

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 42
                            anchors.right: parent.right
                            anchors.rightMargin: 48
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1

                            Text {
                                width: parent.width
                                text: menuEntry.errorRow
                                    ? menu.textFor(menu.actionErrorKey,
                                        "The window action could not be completed")
                                    : menu.labelFor(menuEntry.modelData)
                                elide: Text.ElideRight
                                color: menuEntry.errorRow
                                        || (menuEntry.modelData.id === "close"
                                            && (menuEntry.index === menu.selectedIndex
                                                || entryMouse.containsMouse))
                                    ? menu.theme.colorCritical : menu.theme.colorText
                                font.family: "Pretendard"
                                font.pixelSize: 13
                                font.bold: true
                            }

                            Text {
                                visible: menuEntry.errorRow && menu.koreanLocale
                                    && menu.actionErrorKey === "windowMenu.windowClosed"
                                width: parent.width
                                text: menu.textFor("windowMenu.windowClosedSecondary",
                                    "The window has already closed")
                                elide: Text.ElideRight
                                color: menu.theme.colorTextMuted
                                font.family: "Pretendard"
                                font.pixelSize: 10
                            }
                        }

                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: menuEntry.errorRow ? "×" : menuEntry.modelData.key
                            color: menu.theme.colorTextMuted
                            font.family: "Pretendard"
                            font.pixelSize: 10
                        }

                        MouseArea {
                            id: entryMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: menuEntry.available || menuEntry.errorRow
                            onEntered: {
                                if (menuEntry.available)
                                    menu.selectedIndex = menuEntry.index;
                            }
                            onClicked: menuEntry.errorRow
                                ? menu.closeRequested() : menu.trigger(menuEntry.modelData)
                        }
                    }
                }

                Column {
                    visible: menu.adjustmentMode !== ""
                    width: parent.width
                    spacing: 10

                    Text {
                        width: parent.width
                        text: menu.textFor("windowMenu.adjustInstruction",
                            "Use arrow keys to adjust by 20 px.")
                        color: menu.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 12
                        horizontalAlignment: Text.AlignHCenter
                    }

                    Text {
                        width: parent.width
                        text: menu.textFor("windowMenu.finishHint",
                            "Enter to finish · Esc to cancel")
                        color: menu.theme.colorInfo
                        font.family: "Pretendard"
                        font.pixelSize: 11
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            Behavior on height {
                enabled: !menu.reducedMotion
                NumberAnimation { duration: menu.theme.durationDirect; easing.type: Easing.OutCubic }
            }
        }
    }
}
