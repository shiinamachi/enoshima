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

    signal closeRequested()

    readonly property color colorCanvas: "#050623"
    readonly property color colorSurface: "#0a0c3e"
    readonly property color colorRaised: "#161151"
    readonly property color colorFocus: "#62d8ff"
    readonly property color colorSelection: "#9a5cff"
    readonly property color colorAccent: "#e56bff"
    readonly property color colorText: "#f2ecff"
    readonly property color colorTextMuted: "#c9bfe8"
    readonly property color colorSuccess: "#77e0c6"

    property int selectedIndex: 0
    property var selectedEntry: filteredApps.values.length > 0
        ? filteredApps.values[Math.min(selectedIndex, filteredApps.values.length - 1)]
        : null

    readonly property var favoriteOrder: [
        "com.mitchellh.ghostty",
        "thunar",
        "dev.zed.zed",
        "google-chrome",
        "nm-connection-editor",
        "org.pulseaudio.pavucontrol",
        "blueman-manager"
    ]

    screen: targetScreen
    visible: launcherOpen && targetScreen.name === activeScreenName
    color: "transparent"
    aboveWindows: true
    focusable: true
    exclusiveZone: 0

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

    function favoriteRank(entry) {
        const id = normalized(entry.id).replace(/\.desktop$/, "");
        for (let index = 0; index < favoriteOrder.length; ++index) {
            if (id === favoriteOrder[index])
                return index;
        }
        return 999;
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
            return applications.slice(0, 7);
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

    Rectangle {
        anchors.fill: parent
        color: "#99050623"
    }

    MouseArea {
        anchors.fill: parent
        onClicked: launcher.closeRequested()
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - 80, 1040)
        height: Math.min(parent.height - 120, 680)
        radius: 22
        color: "#f70a0c3e"
        border.width: 1
        border.color: "#cc9a5cff"
        clip: true

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
        }

        Rectangle {
            id: searchSurface
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 24
            height: 64
            radius: 14
            color: launcher.colorCanvas
            border.width: 2
            border.color: searchField.activeFocus
                ? launcher.colorFocus
                : "#996d8cff"

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                text: "⌕"
                color: launcher.colorFocus
                font.family: "Jetendard"
                font.pixelSize: 30
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 58
                anchors.verticalCenter: parent.verticalCenter
                text: "앱과 작업 검색"
                visible: searchField.text.length === 0
                color: "#8fc9bfe8"
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
                color: launcher.colorText
                selectionColor: launcher.colorSelection
                selectedTextColor: launcher.colorText
                font.family: "Pretendard"
                font.pixelSize: 16
                clip: true

                onTextChanged: {
                    launcher.selectedIndex = 0;
                    results.positionViewAtBeginning();
                }

                Keys.onPressed: event => {
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
            color: launcher.colorAccent
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
                    anchors.fill: parent
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
                        radius: 12
                        color: index === launcher.selectedIndex
                            ? "#669a5cff"
                            : (resultMouse.containsMouse ? "#33161151" : "transparent")
                        border.width: index === launcher.selectedIndex ? 1 : 0
                        border.color: launcher.colorFocus

                        IconImage {
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: 34
                            implicitHeight: 34
                            source: Quickshell.iconPath(modelData.icon, "application-x-executable")
                        }

                        Text {
                            anchors.left: parent.left
                            anchors.right: enterHint.left
                            anchors.top: parent.top
                            anchors.leftMargin: 58
                            anchors.rightMargin: 12
                            anchors.topMargin: 9
                            text: modelData.name
                            color: launcher.colorText
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
                            color: "#b3c9bfe8"
                            font.family: "Pretendard"
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }

                        Text {
                            id: enterHint
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            visible: index === launcher.selectedIndex
                            text: "↵"
                            color: launcher.colorFocus
                            font.pixelSize: 18
                        }

                        MouseArea {
                            id: resultMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: launcher.selectedIndex = index
                            onClicked: launcher.selectedIndex = index
                            onDoubleClicked: launcher.launch(modelData)
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: filteredApps.values.length === 0
                        text: "일치하는 앱이 없습니다"
                        color: launcher.colorTextMuted
                        font.family: "Pretendard"
                        font.pixelSize: 15
                    }
                }
            }

            Rectangle {
                anchors.left: resultColumn.right
                anchors.leftMargin: 18
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 1
                color: "#556d8cff"
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
                }

                Text {
                    anchors.left: detailIcon.right
                    anchors.right: parent.right
                    anchors.top: detailIcon.top
                    anchors.leftMargin: 16
                    text: launcher.selectedEntry ? launcher.selectedEntry.name : ""
                    color: launcher.colorText
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
                    color: launcher.colorTextMuted
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
                    color: launcher.colorTextMuted
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
                    radius: 12
                    color: openMouse.containsMouse ? launcher.colorSelection : "#33161151"
                    border.width: 1
                    border.color: openMouse.containsMouse
                        ? launcher.colorFocus
                        : "#999a5cff"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: "열기"
                        color: launcher.colorText
                        font.family: "Pretendard"
                        font.pixelSize: 15
                        font.bold: true
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Enter"
                        color: launcher.colorFocus
                        font.family: "Jetendard"
                        font.pixelSize: 12
                    }

                    MouseArea {
                        id: openMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: launcher.launch(launcher.selectedEntry)
                    }
                }

                Text {
                    id: favoriteHeading
                    anchors.left: parent.left
                    anchors.top: openButton.bottom
                    anchors.topMargin: 28
                    text: "즐겨찾기"
                    color: launcher.colorAccent
                    font.family: "Pretendard"
                    font.pixelSize: 13
                    font.bold: true
                }

                Row {
                    anchors.left: parent.left
                    anchors.top: favoriteHeading.bottom
                    anchors.topMargin: 12
                    spacing: 12

                    Repeater {
                        model: launcher.favoriteApplications().slice(0, 4)

                        delegate: Rectangle {
                            required property var modelData
                            width: 54
                            height: 54
                            radius: 13
                            color: favoriteMouse.containsMouse ? "#4462d8ff" : "#88161151"
                            border.width: 1
                            border.color: "#666d8cff"

                            IconImage {
                                anchors.centerIn: parent
                                implicitWidth: 34
                                implicitHeight: 34
                                source: Quickshell.iconPath(modelData.icon, "application-x-executable")
                            }

                            MouseArea {
                                id: favoriteMouse
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
            id: footer
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 52
            color: "#66050623"

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#556d8cff"
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "↑↓  이동     Enter  실행"
                color: launcher.colorTextMuted
                font.family: "Jetendard"
                font.pixelSize: 12
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "Esc  닫기"
                color: launcher.colorTextMuted
                font.family: "Jetendard"
                font.pixelSize: 12
            }
        }
    }
}
