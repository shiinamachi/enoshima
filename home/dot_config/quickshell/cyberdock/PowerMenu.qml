pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.impl as ControlsImpl
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: menu

    required property var targetScreen
    required property bool menuOpen
    required property string activeScreenName
    required property var theme
    required property bool reducedMotion
    property string reviewState: ""

    signal closeRequested()

    property int selectedIndex: 0
    property string selectedAction: ""
    property string pendingConfirmationAction: ""
    property string lastAttemptedAction: ""
    property string currentRequestId: ""
    property bool applying: false
    property string actionPhase: "browsing"
    property string actionError: ""
    property string stderrDetail: ""
    property int phaseRemaining: 0
    property int phaseTotal: 0
    readonly property bool showingActionDetail:
        pendingConfirmationAction !== "" || applying || actionPhase === "error"
    readonly property bool canCancelTransition:
        applying && actionPhase === "closing-apps" && currentRequestId !== ""
    property var powerStatus: ({
        "availability": {
            "lock": "yes", "logout": "yes", "suspend": "unknown",
            "reboot": "unknown", "poweroff": "unknown"
        }
    })
    readonly property bool koreanLocale:
        String(Quickshell.env("LANG") || "").toLowerCase().startsWith("ko")
    readonly property var actions: [
        {"id": "lock", "group": "session", "ko": "잠금", "en": "Lock", "icon": "system-lock-screen-symbolic", "koDescription": "세션 유지", "enDescription": "Keep this session"},
        {"id": "logout", "group": "session", "ko": "로그아웃", "en": "Log Out", "icon": "system-log-out-symbolic", "koDescription": "앱 정리 후 종료", "enDescription": "Close apps and end session"},
        {"id": "suspend", "group": "power", "ko": "절전", "en": "Sleep", "icon": "weather-clear-night-symbolic", "koDescription": "빠르게 다시 시작", "enDescription": "Resume quickly"},
        {"id": "reboot", "group": "system", "ko": "다시 시작", "en": "Restart", "icon": "system-reboot-symbolic", "koDescription": "시스템 재시작", "enDescription": "Restart the system"},
        {"id": "poweroff", "group": "system", "ko": "시스템 종료", "en": "Shut Down", "icon": "system-shutdown-symbolic", "koDescription": "컴퓨터 전원 끄기", "enDescription": "Turn off the computer"}
    ]

    screen: targetScreen
    visible: menuOpen && targetScreen.name === activeScreenName
    color: "transparent"
    aboveWindows: true
    focusable: true
    exclusionMode: ExclusionMode.Ignore

    anchors { left: true; right: true; top: true; bottom: true }

    WlrLayershell.namespace: "cyberpower"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible
        ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    function label(entry) {
        return koreanLocale ? entry.ko : entry.en;
    }

    function description(entry) {
        return koreanLocale ? entry.koDescription : entry.enDescription;
    }

    function groupLabel(group) {
        const labels = {
            "session": ["세션", "SESSION"],
            "power": ["전원", "POWER"],
            "system": ["시스템", "SYSTEM"]
        };
        return koreanLocale ? labels[group][0] : labels[group][1];
    }

    function startsGroup(index) {
        return index === 0 || actions[index - 1].group !== actions[index].group;
    }

    function actionAvailable(index) {
        const state = String(powerStatus.availability?.[actions[index].id] || "unknown");
        return state !== "no" && state !== "na";
    }

    function requestAction(index) {
        if (!actionAvailable(index) || applying)
            return;
        const action = actions[index].id;
        selectedAction = action;
        if (action === "reboot" || action === "poweroff") {
            pendingConfirmationAction = action;
            actionPhase = "confirming";
            actionError = "";
            return;
        }
        runAction(action);
    }

    function runAction(action) {
        if (applying)
            return;
        actionError = "";
        stderrDetail = "";
        phaseRemaining = 0;
        phaseTotal = 0;
        selectedAction = action;
        lastAttemptedAction = action;
        currentRequestId = "";
        pendingConfirmationAction = "";
        actionPhase = "requested";
        applying = true;
        actionProcess.exec(["desktop-power", action]);
    }

    function confirmAction() {
        if (pendingConfirmationAction !== "")
            runAction(pendingConfirmationAction);
    }

    function retryAction() {
        if (lastAttemptedAction !== "")
            runAction(lastAttemptedAction);
    }

    function resetActionDetail() {
        selectedAction = "";
        pendingConfirmationAction = "";
        currentRequestId = "";
        actionPhase = "browsing";
        actionError = "";
        stderrDetail = "";
    }

    function cancelAction() {
        if (canCancelTransition) {
            cancelProcess.exec(["desktop-power", "cancel", "--request-id", currentRequestId]);
            return;
        }
        if (!applying)
            resetActionDetail();
    }

    function actionFailureMessage(detail) {
        const normalized = String(detail || "").toLowerCase();
        if (normalized.includes("not available"))
            return koreanLocale ? "현재 이 전원 동작을 사용할 수 없습니다." : "This power action is unavailable.";
        if (normalized.includes("application close"))
            return koreanLocale ? "저장 확인 창을 처리한 뒤 다시 시도하세요." : "Resolve open save prompts, then retry.";
        if (normalized.includes("inhibitor") || normalized.includes("access denied"))
            return koreanLocale ? "다른 작업이 전원 전환을 막고 있습니다." : "Another task is blocking this power transition.";
        return koreanLocale ? "전원 요청을 완료하지 못했습니다." : "The power request could not be completed.";
    }

    function handleEvent(line) {
        try {
            const event = JSON.parse(String(line || ""));
            if (event.schema !== 1)
                return;
            if (event.requestId)
                currentRequestId = String(event.requestId);
            actionPhase = String(event.phase || actionPhase);
            phaseRemaining = Number(event.remaining ?? phaseRemaining);
            phaseTotal = Number(event.total ?? phaseTotal);
            if (actionPhase === "error")
                actionError = actionFailureMessage(event.message);
            if (actionPhase === "cancelled")
                resetActionDetail();
        } catch (error) {
            console.warn("cyberpower: invalid transition event:", line);
        }
    }

    function phaseText() {
        if (actionPhase === "closing-apps") {
            if (phaseTotal > 0)
                return koreanLocale
                    ? `열린 앱 정리 중 · ${phaseRemaining}/${phaseTotal} 남음`
                    : `Closing apps · ${phaseRemaining}/${phaseTotal} remaining`;
            return koreanLocale ? "열린 앱 정리 중" : "Closing open apps";
        }
        if (actionPhase === "dispatching")
            return koreanLocale ? "시스템에 전원 요청 전달 중" : "Dispatching the system request";
        if (actionPhase === "requested")
            return koreanLocale ? "전원 요청 준비 중" : "Preparing the request";
        return koreanLocale ? "안전하게 작업을 마치는 중" : "Finishing safely";
    }

    function moveSelection(delta) {
        let candidate = selectedIndex;
        for (let step = 0; step < actions.length; ++step) {
            candidate = (candidate + delta + actions.length) % actions.length;
            if (actionAvailable(candidate)) {
                selectedIndex = candidate;
                return;
            }
        }
    }

    function applyReviewState() {
        if (!visible || reviewState === "")
            return;
        selectedAction = "reboot";
        lastAttemptedAction = "reboot";
        pendingConfirmationAction = reviewState === "confirmation" ? "reboot" : "";
        currentRequestId = reviewState === "closing-apps" ? "ui-review" : "";
        applying = ["closing-apps", "dispatching"].includes(reviewState);
        actionPhase = reviewState === "retry" ? "error" : reviewState;
        actionError = ["error", "retry"].includes(reviewState)
            ? actionFailureMessage("inhibitor") : "";
        stderrDetail = ["error", "retry"].includes(reviewState)
            ? "fixture: inhibitor refused the transition" : "";
        phaseTotal = reviewState === "closing-apps" ? 7 : 0;
        phaseRemaining = reviewState === "closing-apps" ? 3 : 0;
        if (reviewState === "default") {
            selectedAction = "";
            lastAttemptedAction = "";
            actionPhase = "browsing";
        }
    }

    // Quickshell's generated qmltypes references QProcess::ExitStatus without
    // importing QtCore's private enum metadata; the runtime signal is valid.
    // qmllint disable signal-handler-parameters
    Process {
        id: statusProcess
        command: ["desktop-power", "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const next = JSON.parse(text);
                    if (next.schema === 1)
                        menu.powerStatus = next;
                } catch (error) {
                    console.warn("cyberpower: invalid status:", error);
                }
            }
        }
    }
    Process {
        id: actionProcess
        stdout: SplitParser { onRead: data => menu.handleEvent(data) }
        stderr: StdioCollector {
            id: errorCollector
            waitForEnd: false
        }
        onExited: exitCode => {
            menu.applying = false;
            menu.stderrDetail = errorCollector.text;
            if (menu.actionPhase === "cancelled" || exitCode === 130) {
                menu.resetActionDetail();
                return;
            }
            if (exitCode === 0) {
                menu.actionError = "";
                menu.actionPhase = "completed";
                menu.closeRequested();
            } else {
                menu.actionPhase = "error";
                menu.actionError = menu.actionFailureMessage(menu.stderrDetail);
                statusProcess.running = true;
            }
        }
    }
    Process {
        id: cancelProcess
        stderr: StdioCollector {
            id: cancelErrorCollector
            waitForEnd: false
        }
        onExited: exitCode => {
            if (exitCode !== 0) {
                menu.actionPhase = "error";
                menu.actionError = menu.actionFailureMessage(cancelErrorCollector.text);
            }
        }
    }
    // qmllint enable signal-handler-parameters

    onVisibleChanged: {
        if (visible) {
            selectedIndex = 0;
            selectedAction = "";
            pendingConfirmationAction = "";
            lastAttemptedAction = "";
            currentRequestId = "";
            applying = false;
            actionPhase = "browsing";
            actionError = "";
            statusProcess.running = true;
            Qt.callLater(() => {
                menu.applyReviewState();
                keyHandler.forceActiveFocus();
            });
        }
    }

    onReviewStateChanged: Qt.callLater(() => applyReviewState())

    Rectangle { anchors.fill: parent; color: menu.theme.colorScrim }

    MouseArea {
        anchors.fill: parent
        enabled: !menu.applying
        onClicked: menu.closeRequested()
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 380)
        height: 448
        radius: menu.theme.radiusPanel
        color: menu.theme.colorLauncherSurface
        border.width: 1
        border.color: menu.actionPhase === "error"
            ? menu.theme.colorCritical : menu.theme.colorSelectionBorder
        scale: menu.visible ? 1 : 0.98

        Behavior on scale {
            enabled: !menu.reducedMotion
            NumberAnimation { duration: menu.theme.durationEnter; easing.type: Easing.OutCubic }
        }

        MouseArea { anchors.fill: parent; acceptedButtons: Qt.LeftButton | Qt.RightButton }

        Item {
            id: keyHandler
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    if (menu.canCancelTransition) {
                        menu.cancelAction();
                    } else if (!menu.applying && menu.showingActionDetail) {
                        menu.resetActionDetail();
                    } else if (!menu.applying) {
                        menu.closeRequested();
                    }
                    event.accepted = true;
                } else if (event.key === Qt.Key_Up) {
                    menu.moveSelection(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                    menu.moveSelection(event.modifiers & Qt.ShiftModifier ? -1 : 1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                    if (menu.actionPhase === "error")
                        menu.retryAction();
                    else if (menu.pendingConfirmationAction !== "")
                        menu.confirmAction();
                    else
                        menu.requestAction(menu.selectedIndex);
                    event.accepted = true;
                }
            }
        }

        Column {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12

            Text {
                width: parent.width
                text: !menu.showingActionDetail
                    ? (menu.koreanLocale ? "전원 및 세션" : "Power & Session")
                    : (menu.selectedAction === "reboot"
                        ? (menu.koreanLocale ? "시스템을 다시 시작할까요?" : "Restart the system?")
                        : (menu.selectedAction === "poweroff"
                            ? (menu.koreanLocale ? "시스템을 종료할까요?" : "Shut down the system?")
                            : menu.label(menu.actions.find(entry => entry.id === menu.selectedAction) || menu.actions[0])))
                color: menu.theme.colorText
                font.family: "Pretendard"
                font.pixelSize: 20
                font.bold: true
            }

            Text {
                width: parent.width
                height: 34
                text: !menu.showingActionDetail
                    ? (menu.koreanLocale ? "원하는 작업을 선택하세요." : "Choose what the computer should do.")
                    : (menu.applying ? menu.phaseText()
                        : (menu.koreanLocale ? "열린 앱을 정리한 뒤 진행합니다." : "Open apps will close before continuing."))
                color: menu.applying ? menu.theme.colorInfo : menu.theme.colorTextMuted
                wrapMode: Text.WordWrap
                font.family: "Pretendard"
                font.pixelSize: 12
            }

            Column {
                id: actionList
                visible: !menu.showingActionDetail
                width: parent.width
                spacing: 5

                Repeater {
                    model: menu.actions

                    delegate: Column {
                        id: actionDelegate
                        required property var modelData
                        required property int index
                        readonly property bool available: menu.actionAvailable(index)
                        width: actionList.width
                        spacing: 4

                        Text {
                            visible: menu.startsGroup(actionDelegate.index)
                            height: visible ? 16 : 0
                            text: menu.groupLabel(actionDelegate.modelData.group)
                            color: menu.theme.colorTextMuted
                            font.family: "Pretendard"
                            font.pixelSize: 10
                            font.letterSpacing: 1.2
                            font.bold: true
                        }

                        Rectangle {
                            width: parent.width
                            height: 46
                            radius: menu.theme.radiusControl
                            color: !actionDelegate.available
                                ? menu.theme.colorSurfaceSubtle
                                : (actionMouse.pressed ? menu.theme.colorFocusSelected
                                    : (actionDelegate.index === menu.selectedIndex
                                        ? menu.theme.colorSelectionSoft
                                        : (actionMouse.containsMouse ? menu.theme.colorFocusHover : "transparent")))
                            border.width: actionDelegate.index === menu.selectedIndex && actionDelegate.available ? 2 : 1
                            border.color: actionDelegate.index === menu.selectedIndex && actionDelegate.available
                                ? menu.theme.colorFocus : menu.theme.colorQuietBorder
                            opacity: actionDelegate.available ? 1 : 0.5

                            Accessible.role: Accessible.Button
                            Accessible.name: menu.label(actionDelegate.modelData)
                            Accessible.description: menu.description(actionDelegate.modelData)
                            Accessible.selected: actionDelegate.index === menu.selectedIndex
                            Accessible.onPressAction: menu.requestAction(actionDelegate.index)

                            ControlsImpl.ColorImage {
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                width: 20
                                height: 20
                                source: Quickshell.iconPath(actionDelegate.modelData.icon, "system-run-symbolic")
                                color: actionDelegate.available
                                    ? menu.theme.colorText : menu.theme.colorTextMuted
                                sourceSize.width: width
                                sourceSize.height: height
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 44
                                anchors.verticalCenter: parent.verticalCenter
                                text: menu.label(actionDelegate.modelData)
                                color: menu.theme.colorText
                                font.family: "Pretendard"
                                font.pixelSize: 14
                                font.bold: true
                            }

                            Text {
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                text: actionDelegate.available
                                    ? menu.description(actionDelegate.modelData)
                                    : (menu.koreanLocale ? "사용 불가" : "Unavailable")
                                color: menu.theme.colorTextMuted
                                font.family: "Pretendard"
                                font.pixelSize: 11
                            }

                            MouseArea {
                                id: actionMouse
                                anchors.fill: parent
                                enabled: actionDelegate.available
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: menu.selectedIndex = actionDelegate.index
                                onClicked: menu.requestAction(actionDelegate.index)
                            }
                        }
                    }
                }
            }

            Column {
                visible: menu.showingActionDetail
                width: parent.width
                spacing: 14

                Rectangle {
                    width: parent.width
                    height: 104
                    radius: menu.theme.radiusControl
                    color: menu.theme.colorSurfaceSubtle
                    border.width: 1
                    border.color: menu.actionPhase === "error"
                        ? menu.theme.colorCritical : menu.theme.colorQuietBorder

                    ControlsImpl.ColorImage {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.top: parent.top
                        anchors.topMargin: 14
                        width: 28
                        height: 28
                        source: Quickshell.iconPath(
                            menu.actionPhase === "error" ? "dialog-error-symbolic"
                                : ((menu.actions.find(entry => entry.id === menu.selectedAction) || menu.actions[0]).icon),
                            "system-run-symbolic")
                        color: menu.actionPhase === "error"
                            ? menu.theme.colorCritical : menu.theme.colorText
                        sourceSize.width: width
                        sourceSize.height: height
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 14
                        horizontalAlignment: Text.AlignHCenter
                        text: menu.actionPhase === "error"
                            ? menu.actionError
                            : (menu.applying ? menu.phaseText()
                                : (menu.koreanLocale ? "저장하지 않은 작업을 확인하세요." : "Check for unsaved work before continuing."))
                        color: menu.actionPhase === "error" ? menu.theme.colorCritical : menu.theme.colorText
                        wrapMode: Text.WordWrap
                        font.family: "Pretendard"
                        font.pixelSize: 12
                        Accessible.role: menu.actionPhase === "error"
                            ? Accessible.AlertMessage : Accessible.StaticText
                    }
                }

                Rectangle {
                    visible: menu.applying
                    width: parent.width
                    height: 6
                    radius: 3
                    color: menu.theme.colorTrack

                    Rectangle {
                        width: menu.phaseTotal > 0
                            ? parent.width * Math.max(0, Math.min(1,
                                (menu.phaseTotal - menu.phaseRemaining) / menu.phaseTotal))
                            : parent.width * 0.35
                        height: parent.height
                        radius: 3
                        color: menu.theme.colorFocus

                        SequentialAnimation on x {
                            running: menu.applying && menu.phaseTotal <= 0
                                && !menu.reducedMotion && menu.reviewState === ""
                            loops: Animation.Infinite
                            NumberAnimation { from: 0; to: 190; duration: 700; easing.type: Easing.InOutCubic }
                            NumberAnimation { from: 190; to: 0; duration: 700; easing.type: Easing.InOutCubic }
                        }
                    }
                }

                Row {
                    width: parent.width
                    height: 48
                    spacing: 10

                    Rectangle {
                        width: Math.floor((parent.width - parent.spacing) / 2)
                        height: 48
                        radius: menu.theme.radiusControl
                        opacity: menu.applying && !menu.canCancelTransition ? 0.45 : 1
                        color: cancelMouse.containsMouse && (!menu.applying || menu.canCancelTransition)
                            ? menu.theme.colorFocusHover : "transparent"
                        border.width: 1
                        border.color: menu.theme.colorQuietBorder
                        Accessible.role: Accessible.Button
                        Accessible.name: menu.koreanLocale ? "취소" : "Cancel"

                        Text {
                            anchors.centerIn: parent
                            text: menu.koreanLocale ? "취소" : "Cancel"
                            color: menu.theme.colorText
                            font.family: "Pretendard"
                            font.pixelSize: 13
                            font.bold: true
                        }
                        MouseArea {
                            id: cancelMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !menu.applying || menu.canCancelTransition
                            onClicked: menu.cancelAction()
                        }
                    }

                    Rectangle {
                        width: Math.floor((parent.width - parent.spacing) / 2)
                        height: 48
                        radius: menu.theme.radiusControl
                        opacity: menu.applying ? 0.55 : 1
                        color: confirmMouse.pressed && !menu.applying
                            ? menu.theme.colorFocusSelected
                            : (menu.actionPhase === "error"
                                ? menu.theme.colorSelectionStrong : menu.theme.colorRaisedSoft)
                        border.width: 1
                        border.color: menu.actionPhase === "error"
                            ? menu.theme.colorCritical : menu.theme.colorWarning
                        Accessible.role: Accessible.Button
                        Accessible.name: menu.actionPhase === "error"
                            ? (menu.koreanLocale ? "다시 시도" : "Retry")
                            : (menu.selectedAction === "reboot"
                                ? (menu.koreanLocale ? "다시 시작 확인" : "Confirm restart")
                                : (menu.selectedAction === "poweroff"
                                    ? (menu.koreanLocale ? "종료 확인" : "Confirm shutdown")
                                    : menu.label(menu.actions.find(entry => entry.id === menu.selectedAction) || menu.actions[0])))

                        Text {
                            anchors.centerIn: parent
                            text: menu.applying
                                ? (menu.koreanLocale ? "처리 중…" : "Working…")
                                : (menu.actionPhase === "error"
                                    ? (menu.koreanLocale ? "다시 시도" : "Retry")
                                    : (menu.selectedAction === "reboot"
                                        ? (menu.koreanLocale ? "다시 시작" : "Restart")
                                        : (menu.selectedAction === "poweroff"
                                            ? (menu.koreanLocale ? "시스템 종료" : "Shut Down")
                                            : menu.label(menu.actions.find(entry => entry.id === menu.selectedAction) || menu.actions[0]))))
                            color: menu.theme.colorText
                            font.family: "Pretendard"
                            font.pixelSize: 13
                            font.bold: true
                        }
                        MouseArea {
                            id: confirmMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !menu.applying
                            onClicked: menu.actionPhase === "error"
                                ? menu.retryAction() : menu.confirmAction()
                        }
                    }
                }
            }
        }
    }
}
