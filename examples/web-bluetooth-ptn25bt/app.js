"use strict";

const SERVICE_UUID = "a76eb9e0-f3ac-4990-84cf-3a94d2426b2b";
const PAIR_WRITE_UUID = "a76eb9e2-f3ac-4990-84cf-3a94d2426b2b";
const DATA_ACK_UUID = "a76eb9e3-f3ac-4990-84cf-3a94d2426b2b";
const STATUS_NOTIFY_UUID = "a76eb9e4-f3ac-4990-84cf-3a94d2426b2b";

const DPI = 180;
const MM_PER_INCH = 25.4;
const HEAD_DOTS = 128;
const PRINTABLE_DOTS = 64;
const DEFAULT_PAGE_MODE = 2;
const PREVIEW_SCALE = 4;

const PIXEL_FONT_5X7 = {
  " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
  "-": ["00000", "00000", "00000", "11110", "00000", "00000", "00000"],
  ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
  "/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
  ":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
  "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
  "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
  "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
  "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
  "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
  "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
  "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
  "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
  "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
  "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
  "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
  "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
  "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
  "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
  "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
  "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
  "G": ["01111", "10000", "10000", "10011", "10001", "10001", "01111"],
  "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
  "I": ["01110", "00100", "00100", "00100", "00100", "00100", "01110"],
  "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
  "K": ["10001", "10010", "10100", "11000", "10100", "10010", "10001"],
  "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
  "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
  "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
  "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
  "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
  "Q": ["01110", "10001", "10001", "10001", "10101", "10010", "01101"],
  "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
  "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
  "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
  "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
  "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
  "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
  "X": ["10001", "10001", "01010", "00100", "01010", "10001", "10001"],
  "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
  "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
};

const state = {
  device: null,
  server: null,
  pairChar: null,
  dataChar: null,
  statusChar: null,
  pendingAck: null,
  lastPrn: null,
  lastPreview: null,
  statusBytes: [],
  downloadUrl: null,
};

const elements = {};

document.addEventListener("DOMContentLoaded", () => {
  for (const id of [
    "connectButton",
    "statusButton",
    "printButton",
    "previewButton",
    "clearLogButton",
    "connectionState",
    "labelText",
    "lengthPx",
    "trailingPadMm",
    "chunkSize",
    "writeDelayMs",
    "previewCanvas",
    "downloadLink",
    "log",
  ]) {
    elements[id] = document.getElementById(id);
  }

  elements.connectButton.addEventListener("click", handleError(connectPrinter));
  elements.statusButton.addEventListener("click", handleError(readStatus));
  elements.previewButton.addEventListener("click", handleError(generatePreviewAndPrn));
  elements.printButton.addEventListener("click", handleError(printLabel));
  elements.clearLogButton.addEventListener("click", () => {
    elements.log.textContent = "";
  });
  elements.labelText.addEventListener("input", () => generatePreviewAndPrn());
  elements.lengthPx.addEventListener("change", () => generatePreviewAndPrn());
  elements.trailingPadMm.addEventListener("change", () => generatePreviewAndPrn());

  if (!navigator.bluetooth) {
    setConnectionState("Web Bluetooth is not available in this browser.");
    elements.connectButton.disabled = true;
    elements.statusButton.disabled = true;
    elements.printButton.disabled = true;
    log("Use Chrome or Edge on macOS/Windows/ChromeOS/Android. Safari and Firefox do not expose Web Bluetooth.");
  }

  generatePreviewAndPrn();
});

function handleError(fn) {
  return async (...args) => {
    try {
      await fn(...args);
    } catch (error) {
      log(`ERROR: ${error.message || error}`);
      throw error;
    }
  };
}

async function connectPrinter() {
  if (state.server?.connected && state.dataChar) {
    log("Already connected.");
    return;
  }

  log("Opening browser Bluetooth chooser...");
  const device = await navigator.bluetooth.requestDevice({
    filters: [{ namePrefix: "PT-N25BT" }],
    optionalServices: [SERVICE_UUID],
  });

  state.device = device;
  device.addEventListener("gattserverdisconnected", () => {
    setConnectionState("Disconnected");
    elements.statusButton.disabled = true;
    log("Disconnected from printer.");
  });

  setConnectionState(`Connecting to ${device.name || "PT-N25BT"}...`);
  const server = await device.gatt.connect();
  const service = await server.getPrimaryService(SERVICE_UUID);

  state.server = server;
  state.pairChar = await service.getCharacteristic(PAIR_WRITE_UUID);
  state.dataChar = await service.getCharacteristic(DATA_ACK_UUID);
  state.statusChar = await service.getCharacteristic(STATUS_NOTIFY_UUID);

  state.dataChar.addEventListener("characteristicvaluechanged", onAckNotification);
  state.statusChar.addEventListener("characteristicvaluechanged", onStatusNotification);
  await state.dataChar.startNotifications();
  await state.statusChar.startNotifications();
  log("Notifications enabled on ACK and status characteristics.");

  await writeWithResponse(state.pairChar, new Uint8Array([0x00]));
  log("Pairing probe accepted.");

  elements.statusButton.disabled = false;
  setConnectionState(`Connected to ${device.name || "PT-N25BT"}`);
}

async function readStatus() {
  await ensureConnected();
  state.statusBytes = [];
  log("Sending status request...");
  await sendFramed(statusRequestBytes());
  log("Status request sent. Waiting for status notification...");
}

async function printLabel() {
  const { prn } = generatePreviewAndPrn();
  await ensureConnected();
  log(`Sending ${prn.length} PRN bytes...`);
  await sendFramed(prn);
  log("File sent.");
}

async function ensureConnected() {
  if (!state.server?.connected || !state.dataChar) {
    await connectPrinter();
  }
}

function generatePreviewAndPrn() {
  const label = drawLabelBitmap({
    text: elements.labelText.value || "WEB BLUETOOTH",
    width: clamp(parseInt(elements.lengthPx.value, 10) || 360, 160, 720),
    height: PRINTABLE_DOTS,
  });
  const trailingPadDots = mmToDots(parseFloat(elements.trailingPadMm.value) || 0);
  const prn = buildPrn(label, { trailingPadDots });

  state.lastPreview = label;
  state.lastPrn = prn;
  renderPreview(label);
  updateDownload(prn);
  log(`Generated ${label.width}x${label.height} 1bpp preview, PRN ${prn.length} bytes, trailingPadDots=${trailingPadDots}.`);
  return { label, prn };
}

function drawLabelBitmap({ text, width, height }) {
  const bitmap = makeBitmap(width, height);
  drawRect(bitmap, 0, 0, width - 1, height - 1, 1);

  const safeText = normalizeText(text);
  const maxWidth = width - 28;
  const maxHeight = height - 18;
  let scale = 6;
  let tracking = 2;
  while (scale > 1) {
    const size = pixelTextSize(safeText, scale, tracking);
    if (size.width <= maxWidth && size.height <= maxHeight) break;
    scale -= 1;
  }
  if (scale <= 2) tracking = 1;

  const size = pixelTextSize(safeText, scale, tracking);
  const x = Math.floor((width - size.width) / 2);
  const y = Math.floor((height - size.height) / 2);
  drawPixelText(bitmap, x, y, safeText, scale, tracking, 1);

  return bitmap;
}

function buildPrn(label, { trailingPadDots }) {
  const totalColumns = label.width + trailingPadDots;
  const rasterLines = totalColumns;
  const bytes = [];

  pushRepeated(bytes, 0x00, 64);
  pushBytes(bytes, 0x1b, 0x40);
  pushBytes(bytes, 0x1b, 0x69, 0x61, 0x01);

  const activeFields = (1 << 2) | (1 << 6) | (1 << 7);
  pushBytes(bytes, 0x1b, 0x69, 0x7a, activeFields, 0x03, 12, 0);
  pushU32LE(bytes, rasterLines);
  pushBytes(bytes, DEFAULT_PAGE_MODE, 0);
  pushBytes(bytes, 0x1b, 0x69, 0x4b, 0x08);
  pushBytes(bytes, 0x1b, 0x69, 0x4d, 0x00);
  pushBytes(bytes, 0x1b, 0x69, 0x64);
  pushU16LE(bytes, 0);
  pushBytes(bytes, 0x4d, 0x00);

  for (let x = 0; x < totalColumns; x += 1) {
    const line = rasterLineForColumn(label, x);
    if (isAllZero(line)) {
      bytes.push(0x5a);
    } else {
      bytes.push(0x47);
      pushU16LE(bytes, line.length);
      pushArray(bytes, line);
    }
  }

  bytes.push(0x1a);
  return new Uint8Array(bytes);
}

function rasterLineForColumn(label, x) {
  const line = new Uint8Array(HEAD_DOTS / 8);
  if (x >= label.width) return line;

  for (let y = 0; y < label.height; y += 1) {
    if (!getPixel(label, x, y)) continue;
    line[Math.floor(y / 8)] |= 1 << (7 - (y % 8));
  }
  return line;
}

async function sendFramed(data) {
  const chunkSize = clamp(parseInt(elements.chunkSize.value, 10) || 180, 20, 512);
  const segmentPayloadMax = Math.max(1, Math.min(chunkSize * 8 - 4, 4092));
  const writeDelayMs = clamp(parseInt(elements.writeDelayMs.value, 10) || 0, 0, 50);
  let offset = 0;
  let segmentIndex = 1;
  const totalSegments = Math.ceil(data.length / segmentPayloadMax);

  log(`Using chunkSize=${chunkSize}, segmentPayloadMax=${segmentPayloadMax}, segments=${totalSegments}.`);
  while (offset < data.length) {
    const end = Math.min(offset + segmentPayloadMax, data.length);
    const segment = data.slice(offset, end);
    const packetCount = Math.ceil((segment.length + 4) / chunkSize);
    const packet = new Uint8Array(segment.length + 4);
    packet.set([0x06, 0xf0, packetCount, 0x00], 0);
    packet.set(segment, 4);

    log(`Segment ${segmentIndex}/${totalSegments}: payload=${segment.length}, packetCount=${packetCount}.`);
    await sendFramedPacket(packet, chunkSize, writeDelayMs);
    offset = end;
    segmentIndex += 1;
  }
}

async function sendFramedPacket(packet, chunkSize, writeDelayMs) {
  const ackPromise = waitForAck(10000);
  for (let offset = 0; offset < packet.length; offset += chunkSize) {
    const chunk = packet.slice(offset, Math.min(offset + chunkSize, packet.length));
    await writeWithoutResponse(state.dataChar, chunk);
    if (writeDelayMs > 0) await sleep(writeDelayMs);
  }
  await ackPromise;
}

function waitForAck(timeoutMs) {
  if (state.pendingAck) {
    throw new Error("Internal error: ACK waiter already pending.");
  }
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      state.pendingAck = null;
      reject(new Error("Timed out waiting for 06f001 ACK."));
    }, timeoutMs);
    state.pendingAck = { resolve, reject, timeout };
  });
}

function onAckNotification(event) {
  const value = dataViewToBytes(event.target.value);
  log(`ackRaw=${hex(value)}`);
  if (value.length === 3 && value[0] === 0x06 && value[1] === 0xf0 && state.pendingAck) {
    const waiter = state.pendingAck;
    state.pendingAck = null;
    clearTimeout(waiter.timeout);
    if (value[2] === 0x01) {
      waiter.resolve();
    } else {
      waiter.reject(new Error(`Printer returned ACK error ${hex(value)}.`));
    }
  }
}

function onStatusNotification(event) {
  const value = dataViewToBytes(event.target.value);
  log(`printerDataRaw=${hex(value)}`);
  state.statusBytes.push(...value);
  if (state.statusBytes.length >= 32) {
    log(describeStatus(new Uint8Array(state.statusBytes.slice(0, 32))));
    state.statusBytes = [];
  }
}

function statusRequestBytes() {
  const bytes = [];
  pushRepeated(bytes, 0x00, 64);
  pushBytes(bytes, 0x1b, 0x40, 0x1b, 0x69, 0x53);
  return new Uint8Array(bytes);
}

function describeStatus(bytes) {
  if (bytes.length < 32) return `status too short: ${bytes.length} bytes`;
  if (bytes[0] !== 0x80 || bytes[1] !== 0x20 || bytes[2] !== 0x42) {
    return `unexpected status magic: ${hex(bytes.slice(0, 4))}`;
  }
  const errors = (bytes[8] << 8) | bytes[9];
  const phase = (bytes[19] << 16) | (bytes[20] << 8) | bytes[21];
  return [
    `series=0x${hexByte(bytes[3])}`,
    `model=0x${hexByte(bytes[4])}`,
    `errors=0x${errors.toString(16).padStart(4, "0")}`,
    `width=${bytes[10]}mm`,
    `media=0x${hexByte(bytes[11])}`,
    `statusType=0x${hexByte(bytes[18])}`,
    `phase=0x${phase.toString(16).padStart(6, "0")}`,
    `tapeBg=0x${hexByte(bytes[24])}`,
    `tapeFg=0x${hexByte(bytes[25])}`,
  ].join(" ");
}

async function writeWithResponse(characteristic, bytes) {
  if (typeof characteristic.writeValueWithResponse === "function") {
    await characteristic.writeValueWithResponse(bytes);
    return;
  }
  await characteristic.writeValue(bytes);
}

async function writeWithoutResponse(characteristic, bytes) {
  if (typeof characteristic.writeValueWithoutResponse === "function") {
    await characteristic.writeValueWithoutResponse(bytes);
    return;
  }
  if (typeof characteristic.writeValueWithResponse === "function") {
    await characteristic.writeValueWithResponse(bytes);
    return;
  }
  await characteristic.writeValue(bytes);
}

function makeBitmap(width, height) {
  return { width, height, pixels: new Uint8Array(width * height) };
}

function setPixel(bitmap, x, y, value) {
  if (x < 0 || y < 0 || x >= bitmap.width || y >= bitmap.height) return;
  bitmap.pixels[y * bitmap.width + x] = value ? 1 : 0;
}

function getPixel(bitmap, x, y) {
  return bitmap.pixels[y * bitmap.width + x] === 1;
}

function drawRect(bitmap, x0, y0, x1, y1, value) {
  for (let x = x0; x <= x1; x += 1) {
    setPixel(bitmap, x, y0, value);
    setPixel(bitmap, x, y1, value);
  }
  for (let y = y0; y <= y1; y += 1) {
    setPixel(bitmap, x0, y, value);
    setPixel(bitmap, x1, y, value);
  }
}

function pixelTextSize(text, scale, tracking) {
  let width = 0;
  for (const char of text) {
    const glyph = PIXEL_FONT_5X7[char] || PIXEL_FONT_5X7[" "];
    width += glyph[0].length * scale + tracking;
  }
  return { width: Math.max(0, width - tracking), height: 7 * scale };
}

function drawPixelText(bitmap, startX, startY, text, scale, tracking, value) {
  let cursorX = startX;
  for (const char of text) {
    const glyph = PIXEL_FONT_5X7[char] || PIXEL_FONT_5X7[" "];
    for (let row = 0; row < glyph.length; row += 1) {
      for (let col = 0; col < glyph[row].length; col += 1) {
        if (glyph[row][col] !== "1") continue;
        for (let dy = 0; dy < scale; dy += 1) {
          for (let dx = 0; dx < scale; dx += 1) {
            setPixel(bitmap, cursorX + col * scale + dx, startY + row * scale + dy, value);
          }
        }
      }
    }
    cursorX += glyph[0].length * scale + tracking;
  }
}

function renderPreview(bitmap) {
  const canvas = elements.previewCanvas;
  const ctx = canvas.getContext("2d");
  canvas.width = bitmap.width * PREVIEW_SCALE;
  canvas.height = bitmap.height * PREVIEW_SCALE;
  ctx.imageSmoothingEnabled = false;
  ctx.fillStyle = "#fff";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.fillStyle = "#000";
  for (let y = 0; y < bitmap.height; y += 1) {
    for (let x = 0; x < bitmap.width; x += 1) {
      if (getPixel(bitmap, x, y)) {
        ctx.fillRect(x * PREVIEW_SCALE, y * PREVIEW_SCALE, PREVIEW_SCALE, PREVIEW_SCALE);
      }
    }
  }
}

function updateDownload(prn) {
  if (state.downloadUrl) URL.revokeObjectURL(state.downloadUrl);
  state.downloadUrl = URL.createObjectURL(new Blob([prn], { type: "application/octet-stream" }));
  elements.downloadLink.href = state.downloadUrl;
  elements.downloadLink.hidden = false;
}

function normalizeText(text) {
  return text.toUpperCase().replace(/[^ A-Z0-9.\\/:_-]/g, " ");
}

function mmToDots(mm) {
  return Math.round((mm / MM_PER_INCH) * DPI);
}

function pushBytes(out, ...values) {
  out.push(...values.map((value) => value & 0xff));
}

function pushRepeated(out, value, count) {
  for (let i = 0; i < count; i += 1) out.push(value & 0xff);
}

function pushArray(out, array) {
  for (const value of array) out.push(value & 0xff);
}

function pushU16LE(out, value) {
  out.push(value & 0xff, (value >> 8) & 0xff);
}

function pushU32LE(out, value) {
  out.push(value & 0xff, (value >> 8) & 0xff, (value >> 16) & 0xff, (value >> 24) & 0xff);
}

function isAllZero(array) {
  return array.every((value) => value === 0);
}

function dataViewToBytes(value) {
  return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
}

function hex(bytes) {
  return Array.from(bytes, hexByte).join("");
}

function hexByte(value) {
  return value.toString(16).padStart(2, "0");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function setConnectionState(message) {
  elements.connectionState.textContent = message;
}

function log(message) {
  const timestamp = new Date().toLocaleTimeString();
  elements.log.textContent += `[${timestamp}] ${message}\n`;
  elements.log.scrollTop = elements.log.scrollHeight;
}
