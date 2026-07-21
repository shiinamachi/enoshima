"use strict";

const { app, BrowserWindow, ipcMain } = require("electron");
const fs = require("fs");
const path = require("path");

const controlPath = process.env.ENOSHIMA_ELECTRON_CONTROL;
const ackPath = process.env.ENOSHIMA_ELECTRON_ACK;
const token = process.env.ENOSHIMA_ELECTRON_TOKEN || "fixture";
const decoration = process.env.ENOSHIMA_ELECTRON_DECORATION || "custom";
const className = decoration === "custom"
    ? "EnoshimaElectronFixtureCustom"
    : "EnoshimaElectronFixtureSystem";
if (!controlPath || !ackPath)
    throw new Error("Electron qualification control paths are required");

app.setName(className);
app.commandLine.appendSwitch("class", className);
if (process.env.ENOSHIMA_ELECTRON_SOFTWARE_RENDERING === "1")
    // The QEMU XWayland qualification lane validates real X11 window
    // semantics, not physical-GPU behavior.  Electron's documented API must
    // run before app readiness and avoids Chromium repeatedly probing the
    // unavailable QEMU render node during close/reopen stress.
    app.disableHardwareAcceleration();

let window = null;
let latestSequence = 0;
let recreateAfterClose = false;
let windowGeneration = 0;

function writeAck(document) {
    const temporary = `${ackPath}.new`;
    fs.writeFileSync(temporary, `${JSON.stringify(document)}\n`, { mode: 0o600 });
    fs.renameSync(temporary, ackPath);
}

function windowState(action, sequence) {
    return {
        schema: 1,
        sequence,
        action,
        pid: process.pid,
        generation: windowGeneration,
        windowAlive: window !== null && !window.isDestroyed(),
        minimized: window !== null && !window.isDestroyed() && window.isMinimized(),
        maximized: window !== null && !window.isDestroyed() && window.isMaximized(),
        fullScreen: window !== null && !window.isDestroyed() && window.isFullScreen(),
    };
}

function createWindow() {
    const custom = decoration === "custom";
    windowGeneration += 1;
    const title = `Enoshima Electron Fixture ${token} generation-${windowGeneration}`;
    window = new BrowserWindow({
        width: 920,
        height: 600,
        frame: !custom,
        title,
        show: true,
        webPreferences: {
            contextIsolation: true,
            preload: path.join(__dirname, "preload.js"),
            sandbox: true,
        },
    });
    window.on("page-title-updated", event => event.preventDefault());
    window.loadFile(path.join(__dirname, "index.html"), {
        query: { decoration },
    });
    window.on("closed", () => {
        window = null;
        if (recreateAfterClose) {
            recreateAfterClose = false;
            setTimeout(createWindow, 80);
        }
    });
}

async function perform(action, sequence) {
    if (action === "shutdown") {
        recreateAfterClose = false;
        writeAck(windowState(action, sequence));
        fs.unwatchFile(controlPath);
        setImmediate(() => app.quit());
        return;
    }
    if (window === null || window.isDestroyed())
        throw new Error("fixture window is unavailable");
    switch (action) {
    case "arm-external-close":
        recreateAfterClose = true;
        break;
    case "native-minimize":
        window.minimize();
        break;
    case "native-maximize":
        window.maximize();
        break;
    case "native-unmaximize":
        window.unmaximize();
        break;
    case "native-close-reopen":
        recreateAfterClose = true;
        window.close();
        break;
    default:
        throw new Error(`unsupported fixture action: ${action}`);
    }
    await new Promise(resolve => setTimeout(resolve, 120));
    writeAck(windowState(action, sequence));
}

function readControl() {
    let document;
    try {
        document = JSON.parse(fs.readFileSync(controlPath, "utf8"));
    } catch (error) {
        return;
    }
    const sequence = Number(document.sequence || 0);
    if (!Number.isSafeInteger(sequence) || sequence <= latestSequence)
        return;
    latestSequence = sequence;
    perform(String(document.action || ""), sequence).catch(error => {
        writeAck({
            schema: 1,
            sequence,
            action: String(document.action || ""),
            pid: process.pid,
            ok: false,
            error: String(error && error.message || error),
        });
    });
}

ipcMain.handle("fixture-action", (_event, action) => {
    latestSequence += 1;
    return perform(String(action), latestSequence);
});

app.whenReady().then(() => {
    createWindow();
    fs.watchFile(controlPath, { interval: 40, persistent: true }, readControl);
    writeAck({ schema: 1, sequence: 0, action: "ready", pid: process.pid });
});

app.on("window-all-closed", () => {
    // The qualification process deliberately survives client-close requests so
    // close/reopen can be exercised repeatedly without conflating it with kill.
});

app.on("before-quit", () => fs.unwatchFile(controlPath));
