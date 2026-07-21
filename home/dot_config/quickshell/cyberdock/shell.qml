//@ pragma IconTheme Papirus-Dark

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

ShellRoot {
    id: root

    property var snapshot: ({
        "activeAddress": "",
        "monitors": [],
        "windows": []
    })
    property bool launcherOpen: false
    property string launcherScreenName: ""
    property bool displayOverlayOpen: false
    property string displayOverlayScreenName: ""
    property bool powerMenuOpen: false
    property string powerMenuScreenName: ""
    property bool windowMenuOpen: false
    property string windowMenuScreenName: ""
    property string windowMenuAddress: ""
    property int windowMenuAnchorX: 14
    property int windowMenuAnchorY: 48
    property string windowMenuSource: "keyboard"
    property bool dockKeyboardOpen: false
    property string dockKeyboardScreenName: ""
    property int dockKeyboardIndex: 0
    property bool kakaoFocusPulseActive: false
    property string kakaoFocusScreenName: ""
    property string kakaoFocusTargetAddress: ""
    property bool osdVisible: false
    property string osdScreenName: ""
    property string osdKind: "volume"
    property int osdValue: 0
    property bool osdMuted: false
    property var pinIds: []
    property bool pinsLoaded: false

    readonly property alias theme: themeTokens
    readonly property string appearanceStateHome: {
        const configured = Quickshell.env("XDG_STATE_HOME");
        return configured !== ""
            ? configured
            : Quickshell.env("HOME") + "/.local/state";
    }
    readonly property string configHome: {
        const configured = Quickshell.env("XDG_CONFIG_HOME");
        return configured !== ""
            ? configured
            : Quickshell.env("HOME") + "/.config";
    }
    readonly property string runtimeHome: Quickshell.env("XDG_RUNTIME_DIR")
    readonly property bool uiFixtureEnabled:
        Quickshell.env("ENOSHIMA_VM_UI_TEST") === "1"
    readonly property string uiFixtureDir:
        Quickshell.env("ENOSHIMA_UI_FIXTURE_DIR")
    property var uiFixtureState: ({
        "schema": 1,
        "surface": "",
        "state": "",
        "output": ""
    })
    property int uiFixtureAppliedSequence: 0
    readonly property bool koreanLocale:
        String(Quickshell.env("LANG") || "").toLowerCase().startsWith("ko")
    property var translations: ({})
    property int snapClock: 0
    readonly property var productionSnapState:
        parseSnapState(snapStateFile.text(), snapClock)
    readonly property var snapState:
        uiFixtureEnabled && uiFixtureState.surface === "snap-assist"
            ? fixtureSnapState(uiFixtureState.state, uiFixtureState.output)
            : productionSnapState
    readonly property var productionDisplayStatus:
        parseDisplayStatus(displayStatusFile.text())
    readonly property var displayStatus:
        uiFixtureEnabled && uiFixtureState.surface === "display-mode"
            ? fixtureDisplayStatus(uiFixtureState.state)
            : productionDisplayStatus
    readonly property string pinsPath:
        configHome + "/enoshima/user/cyberdock-pins.json"
    readonly property string appearanceMode: {
        const candidate = appearanceModeFile.text().trim();
        if (["default", "reduced-motion", "reduced-transparency", "accessible"]
                .includes(candidate))
            return candidate;
        return "default";
    }
    readonly property bool reducedMotion: appearanceMode === "reduced-motion"
        || appearanceMode === "accessible"
    readonly property bool reducedTransparency: appearanceMode === "reduced-transparency"
        || appearanceMode === "accessible"

    // Semantic colors mirror the shared GTK palette while keeping QML free
    // from a runtime palette parser. Launcher and OSD receive this same object
    // so color, geometry, and motion roles cannot drift between shell surfaces.
    QtObject {
        id: themeTokens

        readonly property color colorCanvas: "#050623"
        readonly property color colorSurface: "#0a0c3e"
        readonly property color colorRaised: "#161151"
        readonly property color colorCanvasOverlay: root.reducedTransparency
            ? "#ff050623" : "#f2050623"
        readonly property color colorSurfaceOverlay: root.reducedTransparency
            ? "#ff0a0c3e" : "#f20a0c3e"
        readonly property color colorRaisedOverlay: root.reducedTransparency
            ? "#ff161151" : "#f2161151"
        readonly property color colorLauncherSurface: root.reducedTransparency
            ? "#ff0a0c3e" : "#f70a0c3e"
        readonly property color colorScrim: root.reducedTransparency
            ? "#b3050623" : "#99050623"
        readonly property color colorFooter: root.reducedTransparency
            ? "#cc050623" : "#66050623"
        readonly property color colorSurfaceSubtle: root.reducedTransparency
            ? "#66161151" : "#33161151"
        readonly property color colorRaisedSoft: root.reducedTransparency
            ? "#dd161151" : "#88161151"
        readonly property color colorDivider: "#556d8cff"
        readonly property color colorQuietBorder: "#886d8cff"
        readonly property color colorInfoBorder: "#996d8cff"
        readonly property color colorFocus: "#62d8ff"
        readonly property color colorFocusBorder: "#cc62d8ff"
        readonly property color colorFocusHover: "#4462d8ff"
        readonly property color colorFocusSelected: "#3362d8ff"
        readonly property color colorSelection: "#9a5cff"
        readonly property color colorSelectionSoft: "#669a5cff"
        readonly property color colorSelectionHover: "#cc6541b8"
        readonly property color colorSelectionBorder: "#cc9a5cff"
        readonly property color colorSelectionStrong: "#6541b8"
        readonly property color colorAccent: "#e56bff"
        readonly property color colorText: "#f2ecff"
        readonly property color colorTextMuted: "#c9bfe8"
        readonly property color colorTextSubtle: "#b3c9bfe8"
        readonly property color colorOnSelection: "#f2ecff"
        readonly property color colorInfo: "#6d8cff"
        readonly property color colorCritical: "#ff5d8f"
        readonly property color colorSuccess: "#77e0c6"
        readonly property color colorWarning: "#ffb86b"
        readonly property color colorTrack: "#446d8cff"

        readonly property int radiusPanel: 14
        readonly property int radiusControl: 12
        readonly property int radiusSmall: 10

        readonly property int durationInstant: 90
        readonly property int durationFast: 110
        readonly property int durationDirect: 120
        readonly property int durationExit: 145
        readonly property int durationStandard: 150
        readonly property int durationEnter: 190
        readonly property int durationOsdVisible: 1400
    }

    FileView {
        id: appearanceModeFile
        path: root.appearanceStateHome + "/desktop-appearance/mode"
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
    }

    FileView {
        id: i18nFile
        path: root.configHome + "/enoshima/i18n/"
            + (root.koreanLocale ? "ko-KR.json" : "en-US.json")
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.loadTranslations()
        onInternalTextChanged: root.loadTranslations()
    }

    FileView {
        id: uiFixtureStateFile
        path: root.uiFixtureEnabled && root.uiFixtureDir !== ""
            ? root.uiFixtureDir + "/state.json" : "/dev/null"
        preload: true
        printErrors: false
        watchChanges: root.uiFixtureEnabled
        onFileChanged: reload()
        // The VM writes the first requested state before starting the shell.
        // FileView preloads that file asynchronously, so there may be no
        // file-change notification to drive the readonly uiFixtureState
        // binding. Apply both the initial load and subsequent internal text
        // updates explicitly; the sequence check makes repeated delivery safe.
        onLoaded: root.loadUiFixtureState()
        onInternalTextChanged:
            root.loadUiFixtureState()
    }

    FileView {
        id: uiFixtureReadyFile
        path: root.uiFixtureEnabled && root.uiFixtureDir !== ""
            ? root.uiFixtureDir + "/ready.json" : "/dev/null"
        atomicWrites: true
        blockWrites: true
        printErrors: root.uiFixtureEnabled
    }

    Timer {
        id: uiFixtureReadyTimer
        interval: 120
        repeat: false
        onTriggered: {
            if (!root.uiFixtureEnabled || root.uiFixtureAppliedSequence <= 0)
                return;
            // FileView preloads asynchronously. Never publish a ready ACK for
            // a frame that still contains catalog keys; wait until the
            // production catalog has populated the same model the user sees.
            if (root.countMissingTranslations() > 0) {
                i18nFile.reload();
                restart();
                return;
            }
            uiFixtureReadyFile.setText(JSON.stringify({
                "schema": 1,
                "sequence": root.uiFixtureAppliedSequence,
                "surface": String(root.uiFixtureState.surface || ""),
                "state": String(root.uiFixtureState.state || ""),
                "output": String(root.uiFixtureState.output || ""),
                "text_overflow_count": root.countVisibleTextOverflow(root),
                "missing_translation_count": root.countMissingTranslations()
            }) + "\n");
        }
    }

    function countMissingTranslations() {
        const required = ["dock.running", "display.heading",
            "launcher.search", "windowMenu.systemMenu"];
        let count = 0;
        for (const key of required) {
            const value = translations?.[key];
            if (value === undefined || String(value) === "")
                count += 1;
        }
        return count;
    }

    function countVisibleTextOverflow(object, depth) {
        if (!object || Number(depth || 0) > 32)
            return 0;
        try {
            if (object.visible === false || Number(object.opacity) <= 0)
                return 0;
        } catch (error) {
            // Non-visual QObject children do not expose visibility or opacity.
        }

        let count = 0;
        try {
            const hasTextMetrics = typeof object.text === "string"
                && typeof object.paintedWidth === "number"
                && typeof object.paintedHeight === "number";
            if (hasTextMetrics) {
                const clippedHorizontally = Number(object.width) > 0
                    && object.paintedWidth > Number(object.width) + 0.5;
                const clippedVertically = Number(object.height) > 0
                    && object.paintedHeight > Number(object.height) + 0.5;
                if (Boolean(object.truncated) || clippedHorizontally
                        || clippedVertically)
                    count += 1;
            }
        } catch (error) {
            // A destroyed delegate can disappear while the fixture settles.
        }

        try {
            const children = object.children;
            if (children) {
                for (let index = 0; index < children.length; index++)
                    count += countVisibleTextOverflow(children[index],
                        Number(depth || 0) + 1);
            }
        } catch (error) {
            // ShellRoot also owns non-visual objects without a children list.
        }
        return count;
    }

    function parseTranslations(text) {
        try {
            return JSON.parse(text || "{}");
        } catch (error) {
            console.warn("enoshima: invalid translation catalog:", error);
            return {};
        }
    }

    function parseUiFixtureState(text) {
        if (!uiFixtureEnabled)
            return {"schema": 1, "surface": "", "state": "", "output": ""};
        try {
            const document = JSON.parse(text || "{}");
            if (document.schema === 1)
                return document;
        } catch (error) {
            console.warn("enoshima: invalid VM UI fixture state:", error);
        }
        return {"schema": 1, "surface": "", "state": "", "output": ""};
    }

    function fixtureDisplayStatus(state) {
        return {
            "schema": 2,
            "mode": state === "selected" || state === "applying"
                ? "extend" : "internal",
            "pending": state === "confirmation",
            "deadline": state === "confirmation" ? Date.now() / 1000 + 12 : 0,
            "seconds_remaining": state === "confirmation" ? 12 : 0,
            "external_count": state === "unavailable" ? 0 : 1
        };
    }

    function fixtureSnapState(state, output) {
        const targets = {
            "left-half": ["left-half", 10, 10, 620, 780],
            "right-half": ["right-half", 650, 10, 620, 780],
            "maximize": ["maximize", 10, 10, 1260, 780],
            "corners": ["upper-left", 10, 10, 620, 380],
            "cross-monitor": ["right-half", 650, 10, 620, 780]
        };
        const target = targets[state] || targets["left-half"];
        const layouts = [
            {"layoutId": "halves", "label": "1/2 + 1/2", "cells": [
                {"cellId": "halves:0", "target": "left-half", "x": 0,
                    "y": 0, "width": 0.5, "height": 1},
                {"cellId": "halves:1", "target": "right-half", "x": 0.5,
                    "y": 0, "width": 0.5, "height": 1}
            ]},
            {"layoutId": "third-two-thirds", "label": "1/3 + 2/3", "cells": [
                {"cellId": "third-two-thirds:0", "target": "left-third",
                    "x": 0, "y": 0, "width": 0.333, "height": 1},
                {"cellId": "third-two-thirds:1", "target": "right-two-thirds",
                    "x": 0.333, "y": 0, "width": 0.667, "height": 1}
            ]},
            {"layoutId": "quarters", "label": "2 × 2", "cells": [
                {"cellId": "quarters:0", "target": "upper-left", "x": 0,
                    "y": 0, "width": 0.5, "height": 0.5},
                {"cellId": "quarters:1", "target": "upper-right", "x": 0.5,
                    "y": 0, "width": 0.5, "height": 0.5},
                {"cellId": "quarters:2", "target": "lower-left", "x": 0,
                    "y": 0.5, "width": 0.5, "height": 0.5},
                {"cellId": "quarters:3", "target": "lower-right", "x": 0.5,
                    "y": 0.5, "width": 0.5, "height": 0.5}
            ]},
            {"layoutId": "maximize", "label": "MAX", "cells": [
                {"cellId": "maximize:0", "target": "maximize", "x": 0,
                    "y": 0, "width": 1, "height": 1}
            ]}
        ];
        return {
            "schema": 2,
            "active": state !== "cancelled",
            "session": "0123456789abcdef0123456789abcdef",
            "sequence": 1,
            "address": "0x100",
            "monitor": String(output || ""),
            "target": target[0],
            "geometry": {"localX": target[1], "localY": target[2],
                "width": target[3], "height": target[4]},
            "chooser": {"visible": state === "layout-chooser",
                "selectedCellId": "halves:0", "layouts": layouts},
            "updatedAt": Date.now()
        };
    }

    function fixtureWindow(address, options) {
        const minimized = Boolean(options.minimized);
        return {
            "address": address,
            "class": "com.mitchellh.ghostty",
            "initialClass": "com.mitchellh.ghostty",
            "title": options.title || "Enoshima UI Review",
            "monitor": 0,
            "workspace": {
                "id": minimized ? -99 : 1,
                "name": minimized ? "special:minimized" : "1"
            },
            "focusHistoryID": options.focusHistoryID || 0,
            "fullscreen": 0,
            "fullscreenClient": 0,
            "floating": false,
            "minimized": minimized,
            "state": options.state || (minimized ? "minimized" : "visible"),
            "urgent": Boolean(options.urgent)
        };
    }

    function fixtureSnapshot(surface, state, output, address) {
        const windows = [];
        let activeAddress = "";
        if (surface === "cyberdock-window-state") {
            if (!["pinned", "unavailable"].includes(state)) {
                windows.push(fixtureWindow("0x100", {
                    "minimized": state === "minimized",
                    "state": state,
                    "urgent": state === "urgent",
                    "focusHistoryID": 0
                }));
                if (state === "multi-window")
                    windows.push(fixtureWindow("0x101", {"focusHistoryID": 1}));
                if (state === "focused")
                    activeAddress = "0x100";
            }
        } else if (surface === "system-titlebar") {
            const fixtureAddress = /^0x[0-9A-Fa-f]+$/.test(String(address || ""))
                ? String(address) : "0x100";
            windows.push(fixtureWindow(fixtureAddress, {
                "title": "Enoshima Titlebar Fixture",
                "state": state,
                "focusHistoryID": state === "inactive" ? 1 : 0
            }));
            if (state !== "inactive")
                activeAddress = fixtureAddress;
        } else if (["active-window", "inactive-window"].includes(state)) {
            windows.push(fixtureWindow("0x100", {}));
            if (state === "active-window")
                activeAddress = "0x100";
        }
        return {
            "version": 2,
            "activeAddress": activeAddress,
            "monitors": [{
                "id": 0,
                "name": output,
                "focused": true,
                "activeWorkspace": {"id": 1, "name": "1"},
                "specialWorkspace": {"id": 0, "name": ""}
            }],
            "windows": windows
        };
    }

    function applyUiFixtureState() {
        if (!uiFixtureEnabled)
            return;
        const surface = String(uiFixtureState.surface || "");
        const state = String(uiFixtureState.state || "");
        const output = String(uiFixtureState.output || "");
        if (output === "")
            return;
        const sequence = Number(uiFixtureState.sequence || 0);
        if (sequence <= 0 || sequence === uiFixtureAppliedSequence)
            return;
        launcherOpen = surface === "launcher";
        displayOverlayOpen = surface === "display-mode";
        powerMenuOpen = surface === "power-menu";
        windowMenuOpen = false;
        osdVisible = surface === "osd";
        launcherScreenName = output;
        displayOverlayScreenName = output;
        powerMenuScreenName = output;
        osdScreenName = output;
        dockKeyboardOpen = surface === "cyberdock-window-state"
            && state === "focused";
        dockKeyboardScreenName = output;
        dockKeyboardIndex = 0;
        if (surface === "system-titlebar") {
            windowMenuAddress = String(uiFixtureState.address || "0x100");
            windowMenuScreenName = output;
            windowMenuAnchorX = 950;
            windowMenuAnchorY = 72;
            windowMenuSource = "keyboard";
            windowMenuOpen = ["keyboard-focus", "system-menu",
                "action-running", "action-error"].includes(state);
        }
        snapshot = fixtureSnapshot(surface, state, output,
            String(uiFixtureState.address || ""));
        if (surface === "cyberdock-window-state") {
            pinIds = state === "unavailable"
                ? ["enoshima-unavailable.desktop"]
                : (state === "pinned"
                    ? ["com.mitchellh.ghostty.desktop"] : []);
            pinsLoaded = true;
        }
        if (surface === "osd") {
            const osdStates = {
                "volume": ["volume", 68, false],
                "muted": ["volume", 0, true],
                "microphone-muted": ["microphone", 0, true],
                "brightness": ["brightness", 42, false],
                "keyboard-backlight": ["keyboard-backlight", 66, false],
                "airplane-mode": ["airplane-mode", 100, true],
                "airplane-mode-error": ["airplane-mode-error", 0, false]
            };
            const value = osdStates[state] || osdStates.volume;
            osdKind = value[0];
            osdValue = value[1];
            osdMuted = value[2];
        }
        uiFixtureAppliedSequence = sequence;
        uiFixtureReadyTimer.restart();
    }

    function loadUiFixtureState() {
        if (!uiFixtureEnabled)
            return;
        uiFixtureState = parseUiFixtureState(uiFixtureStateFile.text());
        Qt.callLater(() => applyUiFixtureState());
    }

    onUiFixtureStateChanged: Qt.callLater(() => applyUiFixtureState())
    Component.onCompleted: {
        loadTranslations();
        if (uiFixtureEnabled)
            loadUiFixtureState();
    }

    function loadTranslations() {
        translations = parseTranslations(i18nFile.text());
    }

    function tr(key) {
        const value = translations?.[key];
        return value !== undefined && String(value) !== "" ? String(value) : key;
    }

    function parseSnapState(text, clock) {
        void clock;
        try {
            const document = JSON.parse(text || "{}");
            if (document.schema === 2)
                return document;
        } catch (error) {
            // A writer uses atomic rename, but an absent first-run state is
            // still expected before the first title-bar drag.
        }
        return {"schema": 2, "active": false, "updatedAt": 0};
    }

    function parseDisplayStatus(text) {
        try {
            const document = JSON.parse(text || "{}");
            if (document.schema === 2)
                return document;
        } catch (error) {
            // The persistent display listener publishes this file atomically.
        }
        return {"schema": 2, "mode": "none", "pending": false,
            "deadline": 0, "external_count": 0};
    }

    FileView {
        id: snapStateFile
        path: root.runtimeHome + "/enoshima/snap.json"
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
    }

    FileView {
        id: displayStatusFile
        path: root.runtimeHome + "/enoshima/display/status.json"
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
    }

    Timer {
        interval: 100
        repeat: true
        running: Boolean(root.snapState.active)
        onTriggered: root.snapClock += 1
    }

    // The mode file is created only after the user first selects a profile.
    // Retry only while it is absent; once loaded, FileView handles updates.
    Timer {
        interval: 2000
        repeat: true
        running: !appearanceModeFile.loaded
        onTriggered: appearanceModeFile.reload()
    }

    readonly property var systemLauncherApp: ({
        "id": "launcher",
        "desktopId": "",
        "name": "Applications",
        "icon": "view-app-grid-symbolic",
        "command": [Quickshell.env("HOME") + "/.local/bin/cyberlauncher-toggle"],
        "pinned": false,
        "systemControl": true,
        "unavailable": false,
        "windows": []
    })

    FileView {
        id: pinsFile
        path: root.pinsPath
        preload: true
        printErrors: false
        watchChanges: true
        onFileChanged: {
            reload();
            root.schedulePinsRefresh();
        }
    }

    Process {
        id: pinsProcess
        command: ["cyberdock-pins", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const document = JSON.parse(text);
                    if (!root.uiFixtureEnabled && document.schema === 1
                            && Array.isArray(document.entries)) {
                        root.pinIds = document.entries.map(entry => String(entry));
                        root.pinsLoaded = true;
                    }
                } catch (error) {
                    console.warn("cyberdock: invalid pin state:", error);
                }
            }
        }
    }

    Timer {
        id: refreshPinsSoon
        interval: 180
        repeat: false
        onTriggered: {
            if (!pinsProcess.running)
                pinsProcess.running = true;
        }
    }

    Timer {
        interval: 5000
        repeat: true
        running: !root.uiFixtureEnabled && !root.pinsLoaded
        triggeredOnStart: true
        onTriggered: refreshPinsSoon.restart()
    }

    function runPinAction(arguments_) {
        Quickshell.execDetached(["cyberdock-pins"].concat(arguments_));
        refreshPinsSoon.restart();
    }

    function schedulePinsRefresh() {
        refreshPinsSoon.restart();
    }

    function normalizeDesktopId(value) {
        const id = String(value || "").toLocaleLowerCase();
        if (id === "")
            return "";
        return /\.desktop$/.test(id) ? id : id + ".desktop";
    }

    function canonicalDesktopId(value) {
        const id = String(value || "");
        if (id === "")
            return "";
        return /\.desktop$/i.test(id) ? id : id + ".desktop";
    }

    function desktopEntryById(id) {
        const target = normalizeDesktopId(id);
        for (const entry of DesktopEntries.applications.values) {
            if (entry && normalizeDesktopId(entry.id) === target)
                return entry;
        }
        return null;
    }

    function pinPosition(id) {
        const target = normalizeDesktopId(id);
        for (let index = 0; index < pinIds.length; ++index) {
            if (normalizeDesktopId(pinIds[index]) === target)
                return index;
        }
        return -1;
    }

    function reorderPinnedFromDrag(id, offsetX, slotWidth) {
        const currentIndex = pinPosition(id);
        if (currentIndex < 0 || pinIds.length < 2)
            return;

        const normalizedSlot = Math.max(1, Number(slotWidth || 1));
        const rawDelta = Number(offsetX || 0) / normalizedSlot;
        const delta = rawDelta >= 0
            ? Math.floor(rawDelta + 0.5)
            : Math.ceil(rawDelta - 0.5);
        const targetIndex = Math.max(0,
            Math.min(pinIds.length - 1, currentIndex + delta));
        if (targetIndex === currentIndex)
            return;

        runPinAction([
            "move", id,
            targetIndex < currentIndex ? "--before" : "--after",
            pinIds[targetIndex]
        ]);
    }

    function pinnedMetadata(id) {
        const entry = desktopEntryById(id);
        const fallbackName = String(id).replace(/\.desktop$/i, "");
        return {
            "id": "pinned-" + normalizeDesktopId(id),
            "desktopId": String(id),
            "name": entry ? entry.name : fallbackName,
            "icon": entry && entry.icon ? entry.icon : "application-x-executable",
            "command": entry ? [...entry.command] : [],
            "pinned": true,
            "systemControl": false,
            "unavailable": entry === null,
            "windows": []
        };
    }

    function focusedScreenName() {
        const monitors = snapshot.monitors || [];
        for (const monitor of monitors) {
            if (monitor.focused)
                return String(monitor.name || "");
        }
        return monitors.length > 0 ? String(monitors[0].name || "") : "";
    }

    function toggleLauncher() {
        if (launcherOpen) {
            launcherOpen = false;
            return;
        }
        launcherScreenName = focusedScreenName();
        launcherOpen = true;
    }

    function toggleDisplayOverlay() {
        if (displayOverlayOpen) {
            displayOverlayOpen = false;
            return;
        }
        launcherOpen = false;
        displayOverlayScreenName = focusedScreenName();
        displayOverlayOpen = true;
    }

    function togglePowerMenu() {
        if (powerMenuOpen) {
            powerMenuOpen = false;
            return;
        }
        launcherOpen = false;
        displayOverlayOpen = false;
        powerMenuScreenName = focusedScreenName();
        powerMenuOpen = true;
    }

    function windowByAddress(address) {
        return (snapshot.windows || []).find(window =>
            String(window.address || "") === String(address || "")) || ({});
    }

    function screenForWindow(address) {
        const window = windowByAddress(address);
        const monitor = (snapshot.monitors || []).find(candidate =>
            Number(candidate.id) === Number(window.monitor));
        return monitor ? String(monitor.name || "") : focusedScreenName();
    }

    function showOsd(kind, value, muted) {
        osdScreenName = focusedScreenName();
        osdKind = kind;
        osdValue = Math.max(0, Math.min(100, value));
        osdMuted = muted;
        osdVisible = true;
        osdHideTimer.restart();
    }

    IpcHandler {
        target: "launcher"

        function toggle(): void { root.toggleLauncher(); }
        function open(): void {
            root.launcherScreenName = root.focusedScreenName();
            root.launcherOpen = true;
        }
        function close(): void { root.launcherOpen = false; }
    }

    IpcHandler {
        target: "display"

        function toggle(): void { root.toggleDisplayOverlay(); }
        function open(): void {
            root.launcherOpen = false;
            root.displayOverlayScreenName = root.focusedScreenName();
            root.displayOverlayOpen = true;
        }
        function close(): void { root.displayOverlayOpen = false; }
    }

    IpcHandler {
        target: "power"

        function toggle(): void { root.togglePowerMenu(); }
        function open(): void {
            root.launcherOpen = false;
            root.displayOverlayOpen = false;
            root.powerMenuScreenName = root.focusedScreenName();
            root.powerMenuOpen = true;
        }
        function close(): void { root.powerMenuOpen = false; }
    }

    IpcHandler {
        target: "windowmenu"

        function open(address: string, anchorX: int, anchorY: int,
                source: string): void {
            if (!/^0x[0-9A-Fa-f]+$/.test(address)
                    || Object.keys(root.windowByAddress(address)).length === 0)
                return;
            root.launcherOpen = false;
            root.displayOverlayOpen = false;
            root.powerMenuOpen = false;
            root.windowMenuAddress = address;
            root.windowMenuScreenName = root.screenForWindow(address);
            root.windowMenuAnchorX = anchorX;
            root.windowMenuAnchorY = anchorY;
            root.windowMenuSource = source;
            root.windowMenuOpen = true;
        }
        function close(): void { root.windowMenuOpen = false; }
    }

    IpcHandler {
        target: "kakaofocus"

        function pulse(address: string): void {
            if (!/^0x[0-9A-Fa-f]+$/.test(address))
                return;
            root.kakaoFocusPulseActive = false;
            root.kakaoFocusScreenName = root.focusedScreenName();
            root.kakaoFocusTargetAddress = address;
            Qt.callLater(() => root.kakaoFocusPulseActive = true);
        }
    }

    IpcHandler {
        target: "osd"

        function show(kind: string, value: int, muted: bool): void {
            root.showOsd(kind, value, muted);
        }
    }

    IpcHandler {
        target: "dock"

        function keyboard(): void {
            root.dockKeyboardScreenName = root.focusedScreenName();
            root.dockKeyboardIndex = 0;
            root.dockKeyboardOpen = true;
        }
        function close(): void { root.dockKeyboardOpen = false; }
        function refresh(): void {
            if (!snapshotProcess.running)
                snapshotProcess.running = true;
        }
    }

    Timer {
        id: osdHideTimer
        interval: root.theme.durationOsdVisible
        repeat: false
        onTriggered: root.osdVisible = false
    }

    function windowClass(window) {
        return String(window.initialClass || window.class || "");
    }

    function pinnedIndex(window) {
        const candidate = windowClass(window);
        const entry = DesktopEntries.heuristicLookup(candidate);
        const desktopId = entry ? normalizeDesktopId(entry.id) : "";
        for (let index = 0; index < pinIds.length; ++index) {
            if (desktopId !== "" && desktopId === normalizeDesktopId(pinIds[index]))
                return index;
        }
        return -1;
    }

    function recentWindows(windows) {
        return windows.slice().sort((left, right) =>
            Number(left.focusHistoryID === undefined ? 999999 : left.focusHistoryID)
            - Number(right.focusHistoryID === undefined ? 999999 : right.focusHistoryID));
    }

    function dynamicMetadata(window) {
        const candidate = windowClass(window);
        const entry = DesktopEntries.heuristicLookup(candidate);
        return {
            "name": entry ? entry.name : candidate,
            "icon": entry && entry.icon ? entry.icon : "application-x-executable",
            "desktopId": entry ? canonicalDesktopId(entry.id) : ""
        };
    }

    function buildDockApps() {
        const groups = pinIds.map(id => pinnedMetadata(id));
        const dynamic = {};
        const windows = snapshot.windows || [];

        for (const window of windows) {
            const index = pinnedIndex(window);
            if (index >= 0) {
                groups[index].windows.push(window);
                continue;
            }

            const key = windowClass(window).toLowerCase();
            if (!key)
                continue;
            if (!dynamic[key]) {
                const metadata = dynamicMetadata(window);
                dynamic[key] = {
                    "id": "running-" + key,
                    "desktopId": metadata.desktopId,
                    "name": metadata.name,
                    "icon": metadata.icon,
                    "command": [],
                    "pinned": false,
                    "systemControl": false,
                    "unavailable": false,
                    "windows": []
                };
            }
            dynamic[key].windows.push(window);
        }

        for (const group of groups)
            group.windows = recentWindows(group.windows);
        const runningOnly = Object.values(dynamic);
        for (const group of runningOnly)
            group.windows = recentWindows(group.windows);
        runningOnly.sort((left, right) => left.name.localeCompare(right.name));
        return groups.concat(runningOnly).concat([systemLauncherApp]);
    }

    function launchApp(app) {
        if (!app.command || app.command.length === 0)
            return;
        Quickshell.execDetached(["uwsm", "app", "--"].concat(app.command));
        refreshSoon.restart();
    }

    function activateWindow(address) {
        Quickshell.execDetached(["cyberdock-activate", address]);
        refreshSoon.restart();
    }

    function minimizeWindow(address) {
        Quickshell.execDetached(["cyberdock-minimize", address]);
        refreshSoon.restart();
    }

    function closeWindow(address) {
        Quickshell.execDetached(["cyberdock-close", address]);
        refreshSoon.restart();
    }

    function windowTitle(window) {
        const title = String(window.title || "").trim();
        return title || windowClass(window) || tr("dock.window");
    }

    Process {
        id: snapshotProcess
        command: ["cyberdock-state", "snapshot"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const next = JSON.parse(text);
                    if (!root.uiFixtureEnabled && next.version === 2) {
                        root.snapshot = next;
                        if (root.displayOverlayOpen
                                && !next.monitors.some(monitor =>
                                    String(monitor.name || "")
                                        === root.displayOverlayScreenName)) {
                            root.displayOverlayScreenName = root.focusedScreenName();
                        }
                        if (root.powerMenuOpen
                                && !next.monitors.some(monitor =>
                                    String(monitor.name || "")
                                        === root.powerMenuScreenName)) {
                            root.powerMenuScreenName = root.focusedScreenName();
                        }
                    }
                } catch (error) {
                    console.warn("cyberdock: invalid snapshot:", error);
                }
            }
        }
    }

    Timer {
        id: snapshotTimer
        // Hyprland's event bridge drives normal refreshes. This timer only
        // reconciles health after a missed event.
        interval: 5000
        repeat: true
        running: !root.uiFixtureEnabled
        triggeredOnStart: true
        onTriggered: {
            if (!snapshotProcess.running)
                snapshotProcess.running = true;
        }
    }

    Timer {
        id: refreshSoon
        interval: 140
        repeat: false
        onTriggered: {
            if (!snapshotProcess.running)
                snapshotProcess.running = true;
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: Component {
            // Quickshell's generated qmltypes marks this runtime-provided
            // window interface as uncreatable even though the plugin creates it.
            // qmllint disable uncreatable-type
            PanelWindow {
                // qmllint enable uncreatable-type
                id: dockWindow

                required property var modelData
                property bool manualReveal: false
                property var chooserWindows: []
                property string chooserTitle: ""
                property var dockApps: root.buildDockApps()
                property string tooltipAppId: ""
                property string tooltipText: ""
                property real tooltipCenterX: width / 2
                property var menuApp: null
                property real menuCenterX: width / 2
                property bool pinDragActive: false
                readonly property bool keyboardMode: root.dockKeyboardOpen
                    && String(root.dockKeyboardScreenName) === String(modelData.name || "")
                readonly property int dockBottomMargin: 7
                readonly property var monitorState: (root.snapshot.monitors || []).find(monitor =>
                    String(monitor.name || "") === String(modelData.name || "")) || null
                readonly property bool fullscreenActive: {
                    if (!monitorState)
                        return false;
                    const activeWorkspace = monitorState.activeWorkspace || {};
                    const specialWorkspace = monitorState.specialWorkspace || {};
                    return (root.snapshot.windows || []).some(window => {
                        const workspaceName = String((window.workspace || {}).name || "");
                        const onVisibleWorkspace = workspaceName === String(activeWorkspace.name || "")
                            || (String(specialWorkspace.name || "") !== ""
                                && workspaceName === String(specialWorkspace.name));
                        return Number(window.monitor) === Number(monitorState.id)
                            && onVisibleWorkspace
                            && Number(window.fullscreen || window.fullscreenClient || 0) >= 2;
                    });
                }
                readonly property bool revealed:
                    !root.launcherOpen && (!fullscreenActive || manualReveal || keyboardMode)
                readonly property bool pointerInInteractiveArea:
                    hotspotHover.hovered || dockAreaHover.hovered
                    || contextMenuHover.hovered || chooserHover.hovered

                screen: modelData
                color: "transparent"
                aboveWindows: true
                focusable: keyboardMode
                exclusiveZone: fullscreenActive ? 0 : 74
                implicitHeight: 380

                WlrLayershell.namespace: "cyberdock"
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.keyboardFocus: keyboardMode
                    ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

                anchors {
                    left: true
                    right: true
                    bottom: true
                }

                mask: Region {
                    Region { item: hotspot }
                    Region {
                        item: dockWindow.revealed ? dockHitArea : null
                        radius: root.theme.radiusPanel
                    }
                    Region {
                        item: contextMenu.visible ? contextMenu : null
                        radius: root.theme.radiusPanel
                    }
                    Region {
                        item: chooser.visible ? chooser : null
                        radius: root.theme.radiusPanel
                    }
                }

                onPointerInInteractiveAreaChanged: {
                    if (pointerInInteractiveArea)
                        reveal();
                    else
                        scheduleHide();
                }

                onKeyboardModeChanged: {
                    if (keyboardMode) {
                        manualReveal = true;
                        Qt.callLater(() => dockKeyboardInput.forceActiveFocus());
                    }
                }

                function moveKeyboardSelection(delta) {
                    if (dockApps.length === 0)
                        return;
                    root.dockKeyboardIndex = (root.dockKeyboardIndex + delta + dockApps.length) % dockApps.length;
                }

                function reveal() {
                    hideTimer.stop();
                    manualReveal = true;
                }

                function scheduleHide() {
                    hideTimer.restart();
                }

                function showChooser(app) {
                    clearContextMenu();
                    clearTooltip();
                    chooserTitle = app.name;
                    chooserWindows = root.recentWindows(app.windows);
                    reveal();
                }

                function clearChooser() {
                    chooserWindows = [];
                    chooserTitle = "";
                }

                function showTooltip(app, item) {
                    const point = item.mapToItem(null, item.width / 2, 0);
                    tooltipAppId = app.id;
                    tooltipText = app.unavailable
                        ? app.name + " · Unavailable"
                        : app.name;
                    tooltipCenterX = point.x;
                }

                function clearTooltip(appId) {
                    if (!appId || tooltipAppId === appId) {
                        tooltipAppId = "";
                        tooltipText = "";
                    }
                }

                function showContextMenu(app, item) {
                    const point = item.mapToItem(null, item.width / 2, 0);
                    clearChooser();
                    clearTooltip();
                    menuApp = app;
                    menuCenterX = point.x;
                    reveal();
                }

                function clearContextMenu() {
                    menuApp = null;
                }

                function contextActions() {
                    const app = menuApp;
                    if (!app)
                        return [];

                    if (app.systemControl)
                        return [{"id": "launch", "label": root.tr("dock.openApplications")}];

                    const actions = [];
                    if (app.command && app.command.length > 0) {
                        actions.push({
                            "id": "launch",
                            "label": app.windows && app.windows.length > 0
                                ? root.tr("dock.newWindow")
                                : root.tr("dock.open")
                        });
                    }
                    if (app.windows && app.windows.length > 0) {
                        actions.push({
                            "id": "show",
                            "label": app.windows.length > 1 ? root.tr("dock.showWindows") : root.tr("dock.showWindow")
                        });
                        if (app.windows.some(window =>
                                /^(kakaotalk(\.exe)?|kakao.*)$/i.test(
                                    root.windowClass(window)))) {
                            actions.push({
                                "id": "repair-kakao-focus",
                                "label": root.tr("dock.repairInputFocus")
                            });
                        }
                        if (app.windows.some(window => !window.minimized)) {
                            actions.push({
                                "id": "minimize",
                                "label": app.windows.length > 1 ? root.tr("dock.minimizeAll") : root.tr("dock.minimize")
                            });
                        }
                        actions.push({
                            "id": "close",
                            "label": app.windows.length > 1 ? root.tr("dock.closeAllWindows") : root.tr("dock.closeWindow"),
                            "destructive": true
                        });
                    }

                    const pinIndex = root.pinPosition(app.desktopId);
                    if (pinIndex >= 0) {
                        actions.push({"id": "unpin", "label": root.tr("dock.unpin")});
                        if (pinIndex > 0)
                            actions.push({"id": "move-left", "label": root.tr("dock.moveLeft")});
                        if (pinIndex < root.pinIds.length - 1)
                            actions.push({"id": "move-right", "label": root.tr("dock.moveRight")});
                    } else if (app.desktopId) {
                        actions.push({"id": "pin", "label": root.tr("dock.pin")});
                    }
                    return actions;
                }

                function performContextAction(actionId) {
                    const app = menuApp;
                    clearContextMenu();
                    if (!app)
                        return;

                    if (actionId === "launch") {
                        root.launchApp(app);
                    } else if (actionId === "show") {
                        if (app.windows.length > 1)
                            showChooser(app);
                        else
                            root.activateWindow(app.windows[0].address);
                    } else if (actionId === "minimize") {
                        for (const window of app.windows) {
                            if (!window.minimized)
                                root.minimizeWindow(window.address);
                        }
                    } else if (actionId === "close") {
                        for (const window of app.windows)
                            root.closeWindow(window.address);
                    } else if (actionId === "repair-kakao-focus") {
                        Quickshell.execDetached(["kakaotalk-focus-repair"]);
                    } else if (actionId === "pin") {
                        root.runPinAction(["add", app.desktopId]);
                    } else if (actionId === "unpin") {
                        root.runPinAction(["remove", app.desktopId]);
                    } else if (actionId === "move-left") {
                        const index = root.pinPosition(app.desktopId);
                        if (index > 0) {
                            root.runPinAction([
                                "move", app.desktopId, "--before", root.pinIds[index - 1]
                            ]);
                        }
                    } else if (actionId === "move-right") {
                        const index = root.pinPosition(app.desktopId);
                        if (index >= 0 && index < root.pinIds.length - 1) {
                            root.runPinAction([
                                "move", app.desktopId, "--after", root.pinIds[index + 1]
                            ]);
                        }
                    }
                    refreshSoon.restart();
                }

                function performPrimaryAction(app) {
                    clearContextMenu();
                    const windows = app.windows || [];
                    if (windows.length === 0) {
                        root.launchApp(app);
                    } else if (windows.length > 1) {
                        showChooser(app);
                    } else if (windows[0].minimized) {
                        root.activateWindow(windows[0].address);
                    } else if (windows[0].address === root.snapshot.activeAddress) {
                        root.minimizeWindow(windows[0].address);
                    } else if (windows[0].address !== root.snapshot.activeAddress) {
                        root.activateWindow(windows[0].address);
                    }
                }

                Timer {
                    id: hideTimer
                    interval: 420
                    repeat: false
                    onTriggered: {
                        if (!dockWindow.pointerInInteractiveArea) {
                            dockWindow.clearChooser();
                            dockWindow.clearContextMenu();
                            dockWindow.clearTooltip();
                            dockWindow.manualReveal = false;
                        }
                    }
                }

                Rectangle {
                    id: hotspot
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: dockSurface.width
                    height: 6
                    color: "transparent"

                    HoverHandler {
                        id: hotspotHover
                        blocking: false
                    }
                }

                Rectangle {
                    id: revealIndicator
                    visible: !root.launcherOpen
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: 42
                    height: 3
                    radius: 1.5
                    color: root.theme.colorSelection
                    opacity: dockWindow.revealed ? 0 : 0.72

                    Behavior on opacity {
                        enabled: !root.reducedMotion
                        NumberAnimation { duration: root.theme.durationDirect }
                    }
                }

                Item {
                    id: dockHitArea
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    width: dockSurface.width
                    height: dockSurface.height + dockWindow.dockBottomMargin

                    HoverHandler {
                        id: dockAreaHover
                        blocking: false
                    }
                }

                Rectangle {
                    id: dockSurface
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: dockWindow.dockBottomMargin
                    width: Math.min(parent.width - 28, Math.max(72, dockRow.implicitWidth + 24))
                    height: 58
                    radius: root.theme.radiusPanel
                    color: root.theme.colorSurfaceOverlay
                    border.width: 1
                    border.color: root.theme.colorQuietBorder
                    opacity: dockWindow.revealed ? 1 : 0
                    scale: dockWindow.revealed ? 1 : 0.985

                    transform: Translate {
                        y: dockWindow.revealed ? 0 : 13
                        Behavior on y {
                            enabled: !root.reducedMotion
                            NumberAnimation {
                                duration: dockWindow.revealed
                                    ? root.theme.durationEnter
                                    : root.theme.durationExit
                                easing.type: dockWindow.revealed ? Easing.OutCubic : Easing.InCubic
                            }
                        }
                    }

                    Behavior on opacity {
                        enabled: !root.reducedMotion
                        NumberAnimation {
                            duration: dockWindow.revealed
                                ? root.theme.durationStandard
                                : root.theme.durationFast
                        }
                    }
                    Behavior on scale {
                        enabled: !root.reducedMotion
                        NumberAnimation {
                            duration: dockWindow.revealed
                                ? root.theme.durationEnter
                                : root.theme.durationExit
                            easing.type: dockWindow.revealed ? Easing.OutCubic : Easing.InCubic
                        }
                    }

                    Item {
                        id: dockKeyboardInput
                        anchors.fill: parent
                        focus: dockWindow.keyboardMode
                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape) {
                                root.dockKeyboardOpen = false;
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab
                                    || (event.key === Qt.Key_Tab && event.modifiers & Qt.ShiftModifier)) {
                                dockWindow.moveKeyboardSelection(-1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
                                dockWindow.moveKeyboardSelection(1);
                                event.accepted = true;
                            } else if (event.key === Qt.Key_Home) {
                                root.dockKeyboardIndex = 0;
                                event.accepted = true;
                            } else if (event.key === Qt.Key_End) {
                                root.dockKeyboardIndex = Math.max(0, dockWindow.dockApps.length - 1);
                                event.accepted = true;
                            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                                    || event.key === Qt.Key_Space) && dockWindow.dockApps.length > 0) {
                                dockWindow.performPrimaryAction(dockWindow.dockApps[root.dockKeyboardIndex]);
                                event.accepted = true;
                            }
                        }
                    }

                    Flickable {
                        anchors.fill: parent
                        anchors.margins: 6
                        contentWidth: dockRow.implicitWidth
                        contentHeight: height
                        boundsBehavior: Flickable.StopAtBounds
                        flickableDirection: Flickable.HorizontalFlick
                        interactive: !dockWindow.pinDragActive
                        clip: true

                        Row {
                            id: dockRow
                            height: parent.height
                            spacing: 8

                            Repeater {
                                model: dockWindow.dockApps

                                delegate: Item {
                                    id: appItem
                                    required property var modelData
                                    required property int index
                                    readonly property var app: modelData
                                    readonly property bool running: app.windows.length > 0
                                    readonly property int minimizedCount: app.windows.filter(window => window.minimized).length
                                    readonly property int visibleCount: app.windows.length - minimizedCount
                                    readonly property bool allMinimized: running && minimizedCount === app.windows.length
                                    readonly property bool someMinimized: minimizedCount > 0 && !allMinimized
                                    readonly property bool transitioning: app.windows.some(window =>
                                        ["minimizing", "restoring", "closing"]
                                            .includes(String(window.state || "")))
                                    readonly property bool active: app.windows.some(window =>
                                        window.address === root.snapshot.activeAddress)
                                    readonly property bool urgent: app.windows.some(window =>
                                        Boolean(window.urgent))
                                    readonly property bool keyboardFocused:
                                        dockWindow.keyboardMode && index === root.dockKeyboardIndex
                                    property real dragOffsetX: 0
                                    property bool dragWasActive: false

                                    width: 56
                                    height: 46
                                    scale: pinDrag.active ? 1.04 : (appMouse.pressed ? 0.97 : 1)
                                    z: pinDrag.active ? 2 : 0

                                    transform: Translate { x: appItem.dragOffsetX }

                                    Accessible.role: Accessible.Button
                                    Accessible.name: app.name
                                    Accessible.description: appItem.allMinimized
                                        ? root.tr("dock.allMinimized")
                                        : (appItem.someMinimized
                                            ? root.tr("dock.someMinimized").replace("%1", appItem.minimizedCount)
                                            : (appItem.active
                                        ? root.tr("dock.active")
                                        : (appItem.app.unavailable
                                            ? root.tr("dock.unavailable")
                                            : (appItem.running
                                                ? root.tr("dock.running")
                                                : root.tr("dock.openApplication")))))
                                    Accessible.pressed: appMouse.pressed
                                    Accessible.onPressAction:
                                        dockWindow.performPrimaryAction(appItem.app)

                                    Behavior on scale {
                                        enabled: !root.reducedMotion
                                        NumberAnimation { duration: root.theme.durationFast }
                                    }

                                    Rectangle {
                                        visible: appItem.app.id === "launcher"
                                        anchors.right: parent.right
                                        anchors.rightMargin: 1
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 1
                                        height: 28
                                        color: root.theme.colorSelectionBorder
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: root.theme.radiusControl
                                        color: pinDrag.active
                                            ? root.theme.colorSelectionSoft
                                            : (appMouse.containsMouse
                                            ? root.theme.colorFocusHover
                                            : (appItem.active
                                                ? root.theme.colorFocusSelected
                                                : "transparent"))
                                        border.width: pinDrag.active || appItem.active
                                            || appItem.keyboardFocused || appItem.urgent ? 2 : 0
                                        border.color: appItem.urgent
                                            ? root.theme.colorCritical
                                            : (appItem.keyboardFocused
                                            ? root.theme.colorFocus
                                            : (pinDrag.active
                                            ? root.theme.colorFocus
                                            : root.theme.colorSelectionBorder))
                                    }

                                    IconImage {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.top: parent.top
                                        anchors.topMargin: 4
                                        implicitWidth: 29
                                        implicitHeight: 29
                                        source: Quickshell.iconPath(appItem.app.icon,
                                            "application-x-executable")
                                        opacity: appItem.app.unavailable
                                            ? 0.38
                                            : (appItem.allMinimized ? 0.62
                                                : (appItem.someMinimized ? 0.84 : 1))
                                        scale: appMouse.containsMouse ? 1.09 : 1
                                        Behavior on scale {
                                            enabled: !root.reducedMotion
                                            NumberAnimation { duration: root.theme.durationFast }
                                        }
                                    }

                                    Item {
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.bottom: parent.bottom
                                        anchors.leftMargin: 7
                                        anchors.rightMargin: 7
                                        anchors.bottomMargin: 1
                                        height: 3
                                        visible: appItem.running

                                        Rectangle {
                                            anchors.left: parent.left
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: appItem.active ? parent.width
                                                : (appItem.app.windows.length > 1 ? 22 : 14)
                                            height: appItem.active ? 2 : 1
                                            radius: 1
                                            color: appItem.active
                                                ? root.theme.colorFocus
                                                : root.theme.colorSelection

                                            Behavior on width {
                                                enabled: !root.reducedMotion
                                                NumberAnimation { duration: root.theme.durationDirect }
                                            }
                                        }

                                        Row {
                                            visible: appItem.allMinimized
                                            anchors.centerIn: parent
                                            spacing: 2

                                            Repeater {
                                                model: 3
                                                Rectangle {
                                                    required property int index
                                                    width: index === 1 ? 7 : 4
                                                    height: 2
                                                    radius: 1
                                                    color: root.theme.colorAccent
                                                }
                                            }
                                        }

                                        Rectangle {
                                            visible: appItem.transitioning
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 3
                                            height: 3
                                            radius: 1.5
                                            color: root.theme.colorWarning
                                        }

                                        Rectangle {
                                            visible: appItem.someMinimized
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 5
                                            height: 3
                                            radius: 1
                                            color: root.theme.colorAccent
                                        }

                                        Behavior on opacity {
                                            enabled: !root.reducedMotion
                                            NumberAnimation { duration: root.theme.durationFast }
                                        }
                                    }

                                    Rectangle {
                                        visible: appItem.app.windows.length > 1
                                        anchors.right: parent.right
                                        anchors.top: parent.top
                                        width: appItem.app.windows.length > 9 ? 20 : 15
                                        height: 15
                                        radius: 7.5
                                        color: root.theme.colorSelectionStrong

                                        Text {
                                            anchors.centerIn: parent
                                            text: appItem.app.windows.length > 9
                                                ? "9+"
                                                : appItem.app.windows.length
                                            color: root.theme.colorOnSelection
                                            font.family: "Pretendard"
                                            font.pixelSize: 11
                                            font.bold: true
                                        }
                                    }

                                    Rectangle {
                                        visible: appItem.urgent
                                        anchors.left: parent.left
                                        anchors.top: parent.top
                                        anchors.leftMargin: 4
                                        anchors.topMargin: 4
                                        width: 8
                                        height: 8
                                        radius: 4
                                        color: root.theme.colorCritical
                                        border.width: 1
                                        border.color: root.theme.colorText
                                    }

                                    MouseArea {
                                        id: appMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onEntered: dockWindow.showTooltip(appItem.app, appItem)
                                        onExited: dockWindow.clearTooltip(appItem.app.id)
                                        onClicked: mouse => {
                                            if (mouse.button === Qt.RightButton) {
                                                dockWindow.showContextMenu(appItem.app, appItem);
                                            } else {
                                                dockWindow.performPrimaryAction(appItem.app);
                                            }
                                        }
                                    }

                                    DragHandler {
                                        id: pinDrag
                                        enabled: appItem.app.pinned
                                            && !appItem.app.systemControl
                                        target: null
                                        acceptedButtons: Qt.LeftButton
                                        xAxis.enabled: true
                                        yAxis.enabled: false
                                        grabPermissions: PointerHandler.CanTakeOverFromItems
                                            | PointerHandler.ApprovesTakeOverByAnything

                                        onTranslationChanged: {
                                            if (active)
                                                appItem.dragOffsetX = activeTranslation.x;
                                        }
                                        onActiveChanged: {
                                            if (active) {
                                                appItem.dragWasActive = true;
                                                dockWindow.pinDragActive = true;
                                                dockWindow.hideTimer.stop();
                                                dockWindow.clearContextMenu();
                                                dockWindow.clearTooltip();
                                            } else if (appItem.dragWasActive) {
                                                root.reorderPinnedFromDrag(
                                                    appItem.app.desktopId,
                                                    appItem.dragOffsetX,
                                                    appItem.width + dockRow.spacing);
                                                appItem.dragOffsetX = 0;
                                                appItem.dragWasActive = false;
                                                dockWindow.pinDragActive = false;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: appTooltip
                    visible: dockWindow.tooltipText !== ""
                        && !contextMenu.visible && !chooser.visible
                    x: Math.max(8, Math.min(parent.width - width - 8,
                        dockWindow.tooltipCenterX - width / 2))
                    anchors.bottom: dockSurface.top
                    anchors.bottomMargin: 8
                    width: Math.min(parent.width - 16, tooltipLabel.implicitWidth + 22)
                    height: 32
                    radius: root.theme.radiusSmall
                    color: root.theme.colorCanvasOverlay
                    border.width: 1
                    border.color: root.theme.colorFocusBorder
                    opacity: visible ? 1 : 0
                    z: 12

                    Behavior on opacity {
                        enabled: !root.reducedMotion
                        NumberAnimation { duration: root.theme.durationInstant }
                    }

                    Text {
                        id: tooltipLabel
                        anchors.fill: parent
                        anchors.leftMargin: 11
                        anchors.rightMargin: 11
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: dockWindow.tooltipText
                        color: root.theme.colorText
                        font.family: "Pretendard"
                        font.pixelSize: 12
                        font.bold: true
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    id: contextMenu
                    visible: dockWindow.menuApp !== null
                    x: Math.max(8, Math.min(parent.width - width - 8,
                        dockWindow.menuCenterX - width / 2))
                    anchors.bottom: dockSurface.top
                    anchors.bottomMargin: 10
                    width: 244
                    height: contextColumn.implicitHeight + 16
                    radius: root.theme.radiusPanel
                    color: root.theme.colorRaisedOverlay
                    border.width: 1
                    border.color: root.theme.colorSelectionBorder
                    z: 14

                    HoverHandler {
                        id: contextMenuHover
                        blocking: false
                    }

                    Column {
                        id: contextColumn
                        x: 8
                        y: 8
                        width: parent.width - 16
                        spacing: 3

                        Text {
                            width: parent.width
                            height: 34
                            verticalAlignment: Text.AlignVCenter
                            leftPadding: 8
                            rightPadding: 8
                            text: dockWindow.menuApp ? dockWindow.menuApp.name : ""
                            color: root.theme.colorFocus
                            font.family: "Pretendard"
                            font.pixelSize: 13
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: root.theme.colorSelectionBorder
                        }

                        Repeater {
                            model: dockWindow.contextActions()

                            delegate: Rectangle {
                                required property var modelData
                                width: contextColumn.width
                                height: 40
                                radius: root.theme.radiusSmall
                                color: contextActionMouse.pressed
                                    ? root.theme.colorFocusSelected
                                    : (contextActionMouse.containsMouse
                                        ? root.theme.colorFocusHover
                                        : "transparent")

                                Accessible.role: Accessible.Button
                                Accessible.name: modelData.label
                                Accessible.pressed: contextActionMouse.pressed
                                Accessible.onPressAction:
                                    dockWindow.performContextAction(modelData.id)

                                Text {
                                    anchors.fill: parent
                                    anchors.leftMargin: 9
                                    anchors.rightMargin: 9
                                    verticalAlignment: Text.AlignVCenter
                                    text: modelData.label
                                    color: modelData.destructive
                                        ? root.theme.colorCritical
                                        : root.theme.colorText
                                    font.family: "Pretendard"
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                }

                                MouseArea {
                                    id: contextActionMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: dockWindow.performContextAction(modelData.id)
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: chooser
                    visible: chooserWindows.length > 1
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.bottom: dockSurface.top
                    anchors.bottomMargin: 10
                    width: visible ? Math.min(parent.width - 32, 420) : 0
                    height: visible ? Math.min(258, chooserList.contentHeight + 48) : 0
                    radius: root.theme.radiusPanel
                    color: root.theme.colorRaisedOverlay
                    border.width: 1
                    border.color: root.theme.colorSelectionBorder
                    clip: true

                    HoverHandler {
                        id: chooserHover
                        blocking: false
                    }

                    Text {
                        id: chooserHeading
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 12
                        text: dockWindow.chooserTitle
                        color: root.theme.colorFocus
                        font.family: "Pretendard"
                        font.pixelSize: 14
                        font.bold: true
                        elide: Text.ElideRight
                    }

                    ListView {
                        id: chooserList
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: chooserHeading.bottom
                        anchors.bottom: parent.bottom
                        anchors.margins: 8
                        spacing: 4
                        clip: true
                        model: dockWindow.chooserWindows

                        delegate: Rectangle {
                            required property var modelData
                            width: ListView.view.width
                            height: 42
                            radius: root.theme.radiusControl
                            color: chooserItemMouse.pressed
                                ? root.theme.colorFocusSelected
                                : (chooserItemMouse.containsMouse
                                    ? root.theme.colorFocusHover
                                    : root.theme.colorSurfaceSubtle)

                            Accessible.role: Accessible.Button
                            Accessible.name: root.windowTitle(modelData)
                            Accessible.description: stateLabel.text
                            Accessible.pressed: chooserItemMouse.pressed
                            Accessible.onPressAction: {
                                root.activateWindow(modelData.address);
                                dockWindow.clearChooser();
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.right: stateLabel.left
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 10
                                anchors.rightMargin: 8
                                text: root.windowTitle(modelData)
                                color: root.theme.colorText
                                font.family: "Pretendard"
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }

                            Text {
                                id: stateLabel
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.rightMargin: 10
                                text: modelData.minimized
                                    ? root.tr("dock.minimizedState")
                                    : String(modelData.workspace && modelData.workspace.name || "")
                                color: modelData.minimized
                                    ? root.theme.colorAccent
                                    : root.theme.colorInfo
                                font.family: "Pretendard"
                                font.pixelSize: 10
                                font.bold: true
                            }

                            MouseArea {
                                id: chooserItemMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: {
                                    root.activateWindow(modelData.address);
                                    dockWindow.clearChooser();
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: EnoshimaWindowMenu {
            required property var modelData
            targetScreen: modelData
            menuOpen: root.windowMenuOpen
            activeScreenName: root.windowMenuScreenName
            targetAddress: root.windowMenuAddress
            targetWindow: root.windowByAddress(root.windowMenuAddress)
            anchorX: root.windowMenuAnchorX
            anchorY: root.windowMenuAnchorY
            invocationSource: root.windowMenuSource
            strings: root.translations
            theme: root.theme
            reducedMotion: root.reducedMotion
            reviewState: root.uiFixtureEnabled
                && root.uiFixtureState.surface === "system-titlebar"
                    ? String(root.uiFixtureState.state || "") : ""
            onCloseRequested: root.windowMenuOpen = false
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: EnoshimaSnapAssist {
            required property var modelData
            targetScreen: modelData
            snapState: root.snapState
            theme: root.theme
            reducedMotion: root.reducedMotion
            reducedTransparency: root.reducedTransparency
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: PowerMenu {
            required property var modelData
            targetScreen: modelData
            menuOpen: root.powerMenuOpen
            activeScreenName: root.powerMenuScreenName
            theme: root.theme
            reducedMotion: root.reducedMotion
            reviewState: root.uiFixtureEnabled
                && root.uiFixtureState.surface === "power-menu"
                    ? String(root.uiFixtureState.state || "") : ""
            onCloseRequested: root.powerMenuOpen = false
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: FocusSentinel {
            required property var modelData
            targetScreen: modelData
            pulseActive: root.kakaoFocusPulseActive
            activeScreenName: root.kakaoFocusScreenName
            targetAddress: root.kakaoFocusTargetAddress
            onPulseCompleted: root.kakaoFocusPulseActive = false
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: DisplayModeOverlay {
            required property var modelData
            targetScreen: modelData
            overlayOpen: root.displayOverlayOpen
            activeScreenName: root.displayOverlayScreenName
            displayStatus: root.displayStatus
            theme: root.theme
            reducedMotion: root.reducedMotion
            strings: root.translations
            reviewState: root.uiFixtureEnabled
                && root.uiFixtureState.surface === "display-mode"
                    ? String(root.uiFixtureState.state || "") : ""
            onCloseRequested: root.displayOverlayOpen = false
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: CyberLauncher {
            required property var modelData
            targetScreen: modelData
            launcherOpen: root.launcherOpen
            activeScreenName: root.launcherScreenName
            theme: root.theme
            strings: root.translations
            reducedMotion: root.reducedMotion
            pinIds: root.pinIds
            reviewState: root.uiFixtureEnabled
                && root.uiFixtureState.surface === "launcher"
                    ? String(root.uiFixtureState.state || "") : ""
            onCloseRequested: root.launcherOpen = false
            onPinsChanged: root.schedulePinsRefresh()
        }
    }

    Variants {
        model: Quickshell.screens

        delegate: CyberOsd {
            required property var modelData
            targetScreen: modelData
            osdVisible: root.osdVisible
            activeScreenName: root.osdScreenName
            osdKind: root.osdKind
            osdValue: root.osdValue
            osdMuted: root.osdMuted
            theme: root.theme
            reducedMotion: root.reducedMotion
        }
    }
}
