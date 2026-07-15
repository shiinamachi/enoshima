import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets

// Quickshell's generated qmltypes marks this runtime-provided window interface
// as uncreatable even though the plugin registers it for normal shell use.
// qmllint disable uncreatable-type
PanelWindow {
    // qmllint enable uncreatable-type
    id: launcher

    required property var targetScreen
    required property bool launcherOpen
    required property string activeScreenName
    required property var theme
    required property bool reducedMotion
    required property var pinIds

    signal closeRequested()
    signal pinsChanged()

    property int selectedIndex: 0
    readonly property bool queryEmpty: searchField.text.trim().length === 0
    property var selectedEntry: filteredApps.values.length > 0
        ? filteredApps.values[Math.min(selectedIndex, filteredApps.values.length - 1)]
        : null

    screen: targetScreen
    visible: launcherOpen && targetScreen.name === activeScreenName
    color: "transparent"
    aboveWindows: true
    focusable: true
    exclusionMode: ExclusionMode.Ignore

    anchors {
        left: true
        right: true
        top: true
        bottom: true
    }

    WlrLayershell.namespace: "cyberlauncher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: visible
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    function normalized(value) {
        return String(value || "").toLocaleLowerCase();
    }

    function desktopId(entry) {
        if (!entry)
            return "";
        const id = String(entry.id || "");
        return /\.desktop$/i.test(id) ? id : id + ".desktop";
    }

    function pinPosition(entry) {
        const id = normalized(desktopId(entry));
        for (let index = 0; index < pinIds.length; ++index) {
            if (normalized(pinIds[index]) === id)
                return index;
        }
        return -1;
    }

    function togglePin(entry) {
        const id = desktopId(entry);
        if (id === "")
            return;
        Quickshell.execDetached([
            "cyberdock-pins",
            pinPosition(entry) >= 0 ? "remove" : "add",
            id
        ]);
        pinsChanged();
    }

    function favoriteRank(entry) {
        const index = pinPosition(entry);
        return index >= 0 ? index : 999;
    }

    function searchableText(entry) {
        return normalized([
            entry.name,
            entry.genericName,
            entry.comment,
            ...(entry.keywords || []),
            ...(entry.categories || [])
        ].join(" "));
    }

    function filteredApplications() {
        const query = normalized(searchField.text.trim());
        const applications = [...DesktopEntries.applications.values]
            .filter(entry => entry && entry.name);

        applications.sort((left, right) => {
            if (query === "") {
                const favoriteDifference = favoriteRank(left) - favoriteRank(right);
                if (favoriteDifference !== 0)
                    return favoriteDifference;
            } else {
                const leftName = normalized(left.name);
                const rightName = normalized(right.name);
                const leftScore = leftName === query ? 0 : (leftName.startsWith(query) ? 1 : 2);
                const rightScore = rightName === query ? 0 : (rightName.startsWith(query) ? 1 : 2);
                if (leftScore !== rightScore)
                    return leftScore - rightScore;
            }
            return String(left.name).localeCompare(String(right.name));
        });

        if (query === "")
            return applications.slice(0, 4);
        return applications.filter(entry => searchableText(entry).includes(query)).slice(0, 7);
    }

    function favoriteApplications() {
        return [...DesktopEntries.applications.values]
            .filter(entry => favoriteRank(entry) < 999)
            .sort((left, right) => favoriteRank(left) - favoriteRank(right));
    }

    function moveSelection(delta) {
        const count = filteredApps.values.length;
        if (count === 0)
            return;
        selectedIndex = Math.max(0, Math.min(count - 1, selectedIndex + delta));
        results.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    function launchQuick(index) {
        if (!queryEmpty || index < 0 || index >= quickApps.values.length)
            return;
        launch(quickApps.values[index]);
    }

    function launch(entry) {
        if (!entry)
            return;

        let command = [...entry.command];
        if (entry.runInTerminal)
            command = ["ghostty", "-e"].concat(command);

        Quickshell.execDetached({
            command: ["uwsm", "app", "--"].concat(command),
            workingDirectory: entry.workingDirectory || Quickshell.env("HOME")
        });
        closeRequested();
    }

    onVisibleChanged: {
        if (visible) {
            searchField.text = "";
            selectedIndex = 0;
            Qt.callLater(() => searchField.forceActiveFocus());
        }
    }

    ScriptModel {
        id: filteredApps
        values: launcher.filteredApplications()
    }

    ScriptModel {
        id: quickApps
        values: launcher.favoriteApplications().slice(0, 4)
    }

    Rectangle {
        anchors.fill: parent
        color: launcher.theme.colorScrim
    }

    MouseArea {
        anchors.fill: parent
        onClicked: launcher.closeRequested()
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 1560,
            Math.max(960, Math.round(parent.width * 0.62)))
        height: Math.min(parent.height - 120, 900,
            Math.max(660, Math.round(parent.height * 0.64)))
        radius: launcher.theme.radiusPanel
        color: launcher.theme.colorLauncherSurface
        border.width: 1
        border.color: launcher.theme.colorSelectionBorder
        clip: true

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => mouse.accepted = true
            onDoubleClicked: mouse => mouse.accepted = true
        }

        Rectangle {
            id: searchSurface
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 24
            height: 64
            radius: launcher.theme.radiusControl
            color: launcher.theme.colorCanvas
            border.width: 2
            border.color: searchField.activeFocus
                ? launcher.theme.colorFocus
                : launcher.theme.colorInfoBorder

            IconImage {
                anchors.left: parent.left
                anchors.leftMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 24
                implicitHeight: 24
                source: Quickshell.iconPath("edit-find", "system-search")
                Accessible.ignored: true
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 58
                anchors.verticalCenter: parent.verticalCenter
                text: "앱과 작업 검색"
                visible: searchField.text.length === 0
                color: launcher.theme.colorTextSubtle
                font.family: "Pretendard"
                font.pixelSize: 16
            }

            TextInput {
                id: searchField
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 58
                anchors.rightMargin: 18
                color: launcher.theme.colorText
                selectionColor: launcher.theme.colorSelectionStrong
                selectedTextColor: launcher.theme.colorOnSelection
                font.family: "Pretendard"
                font.pixelSize: 16
                clip: true

                Accessible.role: Accessible.EditableText
                Accessible.name: "앱과 작업 검색"
                Accessible.description: "방향키로 결과를 선택하고 Enter로 실행합니다"
                Accessible.editable: true
                Accessible.focusable: true
                Accessible.focused: activeFocus
                Accessible.searchEdit: true

                onTextChanged: {
                    launcher.selectedIndex = 0;
                    results.positionViewAtBeginning();
                }

                Keys.onPressed: event => {
                    if (searchField.inputMethodComposing)
                        return;

                    if (event.key === Qt.Key_Escape) {
                        launcher.closeRequested();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        launcher.moveSelection(1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Up) {
                        launcher.moveSelection(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        launcher.launch(launcher.selectedEntry);
                        event.accepted = true;
                    } else if ((event.modifiers & Qt.ControlModifier)
                            && event.key === Qt.Key_P) {
                        launcher.togglePin(launcher.selectedEntry);
                        event.accepted = true;
                    } else if ((event.modifiers & Qt.ControlModifier)
                            && event.key >= Qt.Key_1 && event.key <= Qt.Key_4
                            && launcher.queryEmpty) {
                        launcher.launchQuick(event.key - Qt.Key_1);
                        event.accepted = true;
                    }
                }
            }
        }

        Text {
            id: resultHeading
            anchors.left: parent.left
            anchors.top: searchSurface.bottom
            anchors.leftMargin: 28
            anchors.topMargin: 20
            text: searchField.text.length === 0 ? "빠른 실행" : "검색 결과"
            color: launcher.theme.colorAccent
            font.family: "Pretendard"
            font.pixelSize: 13
            font.bold: true
        }

        Item {
            id: body
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: resultHeading.bottom
            anchors.bottom: footer.top
            anchors.leftMargin: 24
            anchors.rightMargin: 24
            anchors.topMargin: 10
            anchors.bottomMargin: 12

            Item {
                id: resultColumn
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Math.floor(parent.width * 0.54)

                ListView {
                    id: results
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: quickAppsSection.visible
                        ? quickAppsSection.top
                        : parent.bottom
                    anchors.bottomMargin: quickAppsSection.visible ? 12 : 0
                    spacing: 5
                    clip: true
                    model: filteredApps
                    interactive: contentHeight > height

                    delegate: Rectangle {
                        id: resultRow
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: 58
                        radius: launcher.theme.radiusControl
                        color: index === launcher.selectedIndex
                            ? launcher.theme.colorSelectionSoft
                            : (resultMouse.containsMouse
                                ? launcher.theme.colorSurfaceSubtle
                                : "transparent")
                        border.width: index === launcher.selectedIndex ? 1 : 0
                        border.color: launcher.theme.colorFocus
                        scale: resultMouse.pressed ? 0.985 : 1

                        Accessible.role: Accessible.ListItem
                        Accessible.name: modelData.name
                        Accessible.description:
                            modelData.genericName || modelData.comment || "애플리케이션"
                        Accessible.selectable: true
                        Accessible.selected: index === launcher.selectedIndex
                        Accessible.pressed: resultMouse.pressed
                        Accessible.onPressAction: launcher.selectedIndex = index

                        Behavior on scale {
                            enabled: !launcher.reducedMotion
                            NumberAnimation { duration: launcher.theme.durationFast }
                        }

                        IconImage {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: 34
                            implicitHeight: 34
                            source: Quickshell.iconPath(modelData.icon, "application-x-executable")
                            Accessible.ignored: true
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.right: enterHint.left
                            anchors.top: parent.top
                            anchors.leftMargin: 58
                            anchors.rightMargin: 12
                            anchors.topMargin: 9
                            text: modelData.name
                            color: launcher.theme.colorText
                            font.family: "Pretendard"
                            font.pixelSize: 15
                            elide: Text.ElideRight
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.right: enterHint.left
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: 58
                            anchors.rightMargin: 12
                            anchors.bottomMargin: 8
                            text: modelData.genericName || modelData.comment || "애플리케이션"
                            color: launcher.theme.colorTextMuted
                            font.family: "Pretendard"
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }

                        Text {
                            id: enterHint
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            visible: index === launcher.selectedIndex
                            text: "↵"
                            color: launcher.theme.colorFocus
                            font.pixelSize: 18
                            Accessible.ignored: true
                        }

                        MouseArea {
                            id: resultMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onEntered: launcher.selectedIndex = index
                            onClicked: mouse => {
                                launcher.selectedIndex = index;
                                if (mouse.button === Qt.RightButton)
                                    launcher.togglePin(modelData);
                            }
                            onDoubleClicked: launcher.launch(modelData)
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: filteredApps.values.length === 0
                        text: "일치하는 앱이 없습니다"
                        color: launcher.theme.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 15
                    }
                }

                Item {
                    id: quickAppsSection
                    visible: launcher.queryEmpty && quickApps.values.length > 0
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: visible ? 108 : 0

                    Text {
                        id: quickAppsHeading
                        anchors.left: parent.left
                        anchors.top: parent.top
                        text: "빠른 앱"
                        color: launcher.theme.colorAccent
                        font.family: "Pretendard"
                        font.pixelSize: 13
                        font.bold: true
                    }

                    Row {
                        id: quickAppsRow
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: quickAppsHeading.bottom
                        anchors.topMargin: 10
                        height: 80
                        spacing: 8

                        Repeater {
                            model: quickApps

                            delegate: Rectangle {
                                id: quickAppButton
                                required property var modelData
                                required property int index
                                width: Math.floor((quickAppsRow.width
                                    - quickAppsRow.spacing * 3) / 4)
                                height: 78
                                radius: launcher.theme.radiusControl
                                color: quickAppMouse.pressed
                                    ? launcher.theme.colorFocusSelected
                                    : (quickAppMouse.containsMouse
                                        ? launcher.theme.colorFocusHover
                                        : launcher.theme.colorRaisedSoft)
                                border.width: 1
                                border.color: launcher.theme.colorQuietBorder
                                scale: quickAppMouse.pressed ? 0.98 : 1

                                Accessible.role: Accessible.Button
                                Accessible.name: modelData.name
                                Accessible.description: "Ctrl+" + (index + 1) + "로 실행"
                                Accessible.pressed: quickAppMouse.pressed
                                Accessible.onPressAction: launcher.launch(modelData)

                                Behavior on scale {
                                    enabled: !launcher.reducedMotion
                                    NumberAnimation { duration: launcher.theme.durationFast }
                                }

                                IconImage {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    anchors.top: parent.top
                                    anchors.topMargin: 9
                                    implicitWidth: 31
                                    implicitHeight: 31
                                    source: Quickshell.iconPath(modelData.icon,
                                        "application-x-executable")
                                    Accessible.ignored: true
                                }

                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.rightMargin: 6
                                    anchors.topMargin: 6
                                    width: 42
                                    height: 18
                                    radius: height / 2
                                    color: launcher.theme.colorSurfaceSubtle
                                    border.width: 1
                                    border.color: launcher.theme.colorQuietBorder

                                    Text {
                                        anchors.centerIn: parent
                                        text: "Ctrl+" + (index + 1)
                                        color: launcher.theme.colorFocus
                                        font.family: "Jetendard"
                                        font.pixelSize: 10
                                    }
                                }

                                Text {
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    anchors.bottomMargin: 7
                                    horizontalAlignment: Text.AlignHCenter
                                    text: modelData.name
                                    color: launcher.theme.colorText
                                    font.family: "Pretendard"
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                }

                                MouseArea {
                                    id: quickAppMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: launcher.launch(modelData)
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                anchors.left: resultColumn.right
                anchors.leftMargin: 18
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: launcher.theme.colorDivider
            }

            Item {
                id: detailColumn
                anchors.left: resultColumn.right
                anchors.leftMargin: 36
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                visible: launcher.selectedEntry !== null

                IconImage {
                    id: detailIcon
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.topMargin: 10
                    implicitWidth: 68
                    implicitHeight: 68
                    source: launcher.selectedEntry
                        ? Quickshell.iconPath(launcher.selectedEntry.icon, "application-x-executable")
                        : ""
                    Accessible.ignored: true
                }

                Text {
                    anchors.left: detailIcon.right
                    anchors.right: parent.right
                    anchors.top: detailIcon.top
                    anchors.leftMargin: 16
                    text: launcher.selectedEntry ? launcher.selectedEntry.name : ""
                    color: launcher.theme.colorText
                    font.family: "Pretendard"
                    font.pixelSize: 22
                    font.bold: true
                    elide: Text.ElideRight
                }

                Text {
                    anchors.left: detailIcon.right
                    anchors.right: parent.right
                    anchors.bottom: detailIcon.bottom
                    anchors.leftMargin: 16
                    text: launcher.selectedEntry
                        ? (launcher.selectedEntry.genericName || "애플리케이션")
                        : ""
                    color: launcher.theme.colorTextMuted
                    font.family: "Pretendard"
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }

                Text {
                    id: detailDescription
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: detailIcon.bottom
                    anchors.topMargin: 24
                    text: launcher.selectedEntry
                        ? (launcher.selectedEntry.comment || "선택한 애플리케이션을 실행합니다.")
                        : ""
                    color: launcher.theme.colorTextMuted
                    font.family: "Pretendard"
                    font.pixelSize: 14
                    wrapMode: Text.WordWrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                }

                Rectangle {
                    id: openButton
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: detailDescription.bottom
                    anchors.topMargin: 22
                    height: 48
                    radius: launcher.theme.radiusControl
                    color: openMouse.pressed
                        ? launcher.theme.colorFocusSelected
                        : (openMouse.containsMouse
                            ? launcher.theme.colorSelectionHover
                            : launcher.theme.colorSurfaceSubtle)
                    border.width: 1
                    border.color: openMouse.containsMouse
                        ? launcher.theme.colorFocus
                        : launcher.theme.colorSelectionBorder
                    scale: openMouse.pressed ? 0.985 : 1

                    Accessible.role: Accessible.Button
                    Accessible.name: launcher.selectedEntry
                        ? launcher.selectedEntry.name + " 열기"
                        : "애플리케이션 열기"
                    Accessible.description: "Enter로 실행"
                    Accessible.defaultButton: true
                    Accessible.pressed: openMouse.pressed
                    Accessible.onPressAction: launcher.launch(launcher.selectedEntry)

                    Behavior on scale {
                        enabled: !launcher.reducedMotion
                        NumberAnimation { duration: launcher.theme.durationFast }
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: "열기"
                        color: launcher.theme.colorText
                        font.family: "Pretendard"
                        font.pixelSize: 15
                        font.bold: true
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Enter"
                        color: launcher.theme.colorFocus
                        font.family: "Jetendard"
                        font.pixelSize: 12
                        Accessible.ignored: true
                    }

                    MouseArea {
                        id: openMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: launcher.launch(launcher.selectedEntry)
                    }
                }

                Rectangle {
                    id: pinButton
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: openButton.bottom
                    anchors.topMargin: 10
                    height: 44
                    radius: launcher.theme.radiusControl
                    color: pinMouse.pressed
                        ? launcher.theme.colorFocusSelected
                        : (pinMouse.containsMouse
                            ? launcher.theme.colorFocusHover
                            : "transparent")
                    border.width: 1
                    border.color: launcher.theme.colorQuietBorder
                    scale: pinMouse.pressed ? 0.985 : 1

                    Accessible.role: Accessible.Button
                    Accessible.name: launcher.pinPosition(launcher.selectedEntry) >= 0
                        ? "Dock에서 고정 해제"
                        : "Dock에 고정"
                    Accessible.description: "Ctrl+P로 전환"
                    Accessible.pressed: pinMouse.pressed
                    Accessible.onPressAction: launcher.togglePin(launcher.selectedEntry)

                    Behavior on scale {
                        enabled: !launcher.reducedMotion
                        NumberAnimation { duration: launcher.theme.durationFast }
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: launcher.pinPosition(launcher.selectedEntry) >= 0
                            ? "Dock에서 고정 해제"
                            : "Dock에 고정"
                        color: launcher.theme.colorText
                        font.family: "Pretendard"
                        font.pixelSize: 14
                        font.bold: true
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Ctrl+P"
                        color: launcher.theme.colorFocus
                        font.family: "Jetendard"
                        font.pixelSize: 12
                        Accessible.ignored: true
                    }

                    MouseArea {
                        id: pinMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: launcher.togglePin(launcher.selectedEntry)
                    }
                }
            }
        }

        Rectangle {
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 52
            color: launcher.theme.colorFooter

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: launcher.theme.colorDivider
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "↑↓  이동     Enter  실행"
                color: launcher.theme.colorTextMuted
                font.family: "Jetendard"
                font.pixelSize: 12
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "Esc  닫기"
                color: launcher.theme.colorTextMuted
                font.family: "Jetendard"
                font.pixelSize: 12
            }
        }
    }
}
