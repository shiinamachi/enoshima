"use strict";

const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("enoshimaFixture", {
    invoke: action => ipcRenderer.invoke("fixture-action", action),
});
