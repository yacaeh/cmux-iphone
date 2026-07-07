import http from "node:http";
import net from "node:net";
import crypto from "node:crypto";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";
import { spawn as childSpawn } from "node:child_process";
import { Bonjour } from "bonjour-service";
import * as cmux from "./cmux.js";
import { createDeviceStore } from "./lib/devices.js";
import { paths as cfgPaths, getConfig, writeRuntime, clearRuntime } from "./lib/config.js";

// ---------------------------------------------------------------------------
// Logging (must be defined before use)
// ---------------------------------------------------------------------------

function log(level, msg, ...args) {
  const ts = new Date().toISOString();
  const prefix = `[${ts}] [${level.toUpperCase()}]`;
  if (args.length) {
    console.log(prefix, msg, ...args);
  } else {
    console.log(prefix, msg);
  }
}

// ---------------------------------------------------------------------------
// Binary discovery
// ---------------------------------------------------------------------------

function findBinary(name, candidates) {
  for (const c of candidates) {
    try { fs.accessSync(c, fs.constants.X_OK); return c; } catch { /* continue */ }
  }
  try {
    return execSync(`which ${name} 2>/dev/null`, { encoding: "utf-8" }).trim();
  } catch { /* fall through */ }
  return null;
}

const CLAUDE_BIN = findBinary("claude", [
  `${os.homedir()}/.local/bin/claude`,
  "/usr/local/bin/claude",
  "/opt/homebrew/bin/claude",
]);

const CODEX_BIN = findBinary("codex", [
  `${os.homedir()}/.local/bin/codex`,
  "/usr/local/bin/codex",
  "/opt/homebrew/bin/codex",
]);

if (!CLAUDE_BIN) {
  log("warn", "Could not find 'claude' binary — Claude sessions will not be available.");
}
if (CODEX_BIN) {
  log("info", `Codex binary found: ${CODEX_BIN}`);
} else {
  log("info", "Codex not found — Codex sessions will not be available.");
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// Single source of truth: ports, bind interface, and pairing TTL all come from
// lib/config.js (config.json merged over defaults), not hardcoded here. Env still
// overrides at runtime (PORT, HOST, CMUX_IPHONE_HOOK_PORT, CMUX_IPHONE_PAIR_CODE).
const CONFIG = getConfig();
const PORT_RANGE_START = CONFIG.ports.apiPort;
const PORT_RANGE_END = CONFIG.ports.apiPortRangeEnd;
const BIND_ADDRESS = process.env.HOST || CONFIG.bindAddress || "0.0.0.0";
const PAIRING_CODE_TTL_MS = CONFIG.pairing?.ttlMs ?? 24 * 60 * 60 * 1000; // rotating-mode TTL
// Pairing default is FIXED (per-machine random 6-digit, persisted by
// `cmux-iphone setup`, never rotates, rate-limited 5/5min). A FIXED code is
// pinned two ways, in priority order:
//   1. CMUX_IPHONE_PAIR_CODE env var
//   2. config.json  pairing.fixedCode  — what `cmux-iphone setup` persists so
//      non-developers get one stable code they never have to hunt for again.
// ROTATING mode (fresh code per restart, PAIRING_CODE_TTL_MS TTL, cleared after a
// device pairs) applies only when neither is set — opt in via `setup --rotating`.
// NEVER ship a hardcoded default here — a baked-in code is public in the repo and
// defeats pairing auth for every install. A persisted code is per-machine, random,
// and stored 0600 (not in the repo).
const FIXED_PAIRING_CODE =
  process.env.CMUX_IPHONE_PAIR_CODE || CONFIG.pairing?.fixedCode || null;
const RATE_LIMIT_WINDOW_MS = 5 * 60 * 1000;
const RATE_LIMIT_MAX_ATTEMPTS = 5;
const SSE_HEARTBEAT_INTERVAL_MS = 10_000;
const SSE_BUFFER_SIZE = 500;
const PERMISSION_TIMEOUT_MS = 600_000; // 10 minutes
const CODEX_SESSION_SCAN_INTERVAL_MS = 1_500;
const CODEX_SESSION_BOOTSTRAP_LOOKBACK_MS = 30 * 60 * 1000;
const CODEX_SESSION_SCAN_LIMIT = 25;
const CODEX_SESSION_ROOT = path.join(os.homedir(), ".codex", "sessions");
const CODEX_LOG_FILE = path.join(os.homedir(), ".codex", "log", "codex-tui.log");
const BRIDGE_ID = crypto.randomUUID();

// Mobile web client (served at GET /) — lets an iPhone use the bridge from
// Safari with no app install.
let WEB_CLIENT_HTML = "<!doctype html><title>Cmux iPhone</title><h1>web client missing</h1>";
try {
  WEB_CLIENT_HTML = fs.readFileSync(new URL("./webclient.html", import.meta.url), "utf-8");
} catch {
  /* webclient.html optional */
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let pairingCode = null;
let pairingCodeExpiresAt = 0;

// Rate limiting — keyed PER CLIENT IP so one abusive client can't lock every
// legitimate device out of pairing. Bounded in size to cap memory.
/** @type {Map<string, {count: number, windowStart: number}>} */
const rateLimits = new Map();
const RATE_LIMIT_MAX_IPS = 1024;

// Bridge-level state: "idle" | "connected"
let bridgeState = "idle";
// Supervise mode: when ON, PreToolUse for mutating tools blocks for phone
// approval (works in ALL permission modes, even auto/bypass). Default OFF so
// normal sessions never block.
let superviseMode = false;

// Multi-session: each entry is a session slot
// { id, agent, cwd, folderName, ptyProcess, state, createdAt }
/** @type {Map<string, {id: string, agent: string, cwd: string, folderName: string, ptyProcess: import("child_process").ChildProcess | null, state: string, createdAt: number}>} */
const sessions = new Map();

// SSE
let sseEventId = 0;
/** @type {Array<{id: number, event: string, data: string}>} */
const sseBuffer = [];
/** @type {Set<http.ServerResponse>} */
const sseClients = new Set();

// Permission flow
/** @type {Map<string, {resolve: Function, timer: ReturnType<typeof setTimeout>, sessionId: string | null}>} */
const pendingPermissions = new Map();
/** @type {Map<string, Array>} */
const pendingPermissionBodies = new Map();
// (sessionId:toolName) pairs the user approved with "allow all" from the phone —
// subsequent PermissionRequest hooks for the same pair auto-allow without
// prompting. In-memory: resets on bridge restart (safe default).
const autoAllowTools = new Set();
/** Full permission-request payloads kept until resolved — re-sent to clients
 *  that (re)connect, so a backgrounded/reconnecting phone never misses one. */
const pendingPermissionPayloads = new Map();
/** @type {Map<string, {offset: number, remainder: string, sessionId: string | null, cwd?: string, createdAt?: number, initialized: boolean}>} */
const codexSessionFiles = new Map();
/** @type {Map<string, {sessionId: string, name: string, args: Record<string, any>}>} */
const codexPendingToolCalls = new Map();
/** @type {Map<string, {command: string, justification: string, workdir: string, prefixRule: string[], createdAt: number}>} */
const codexExecApprovalCandidates = new Map();
/** @type {Map<string, {sessionId: string, optionCount: number, payload: Record<string, any>}>} */
const codexSyntheticPermissions = new Map();
/** @type {Map<string, string>} */
const codexSyntheticPermissionBySession = new Map();
const codexLogState = { offset: 0, remainder: "", initialized: false };
let codexMonitorInterval = null;

// Bonjour
let bonjourInstance = null;
let bonjourService = null;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function generatePairingCode() {
  const code = FIXED_PAIRING_CODE || crypto.randomInt(0, 1_000_000).toString().padStart(6, "0");
  pairingCode = code;
  pairingCodeExpiresAt = FIXED_PAIRING_CODE ? Number.MAX_SAFE_INTEGER : Date.now() + PAIRING_CODE_TTL_MS;
  // Never log the code itself — this stream is persisted to a plaintext log file
  // under launchd. Retrieve it via the loopback-only CLI (`cmux-iphone pair`).
  log("info", `Pairing code generated (${FIXED_PAIRING_CODE ? "fixed" : "rotating"})`);
  return code;
}

// Persist the session token so it survives bridge restarts/reboots. Otherwise
// every restart regenerates the token, invalidating the phone/watch pairing —
// the app then gets stuck on "connecting" (401 on /events and /command) until
// the user re-pairs. With persistence, one pairing survives reboots.
const TOKEN_FILE = path.join(os.homedir(), "Library", "Application Support", "cmux-iphone", "session-token");

// Hooks run on a separate loopback-only listener with a shared secret, so the
// phone-facing listener never exposes hook routes (defense-in-depth). The port
// must match what setup-hooks.sh wrote into Claude/Codex hooks, so honor the
// same CMUX_IPHONE_HOOK_PORT override (and config) the install scripts use.
const HOOK_PORT =
  parseInt(process.env.CMUX_IPHONE_HOOK_PORT, 10) || CONFIG.ports.hookPort || 7861;
const SECRET_FILE = path.join(os.homedir(), "Library", "Application Support", "cmux-iphone", "hook-secret");
let hookSecret = null;

function loadOrCreateHookSecret() {
  try {
    const s = fs.readFileSync(SECRET_FILE, "utf-8").trim();
    if (s) { hookSecret = s; return s; }
  } catch { /* create below */ }
  const s = crypto.randomBytes(24).toString("hex");
  try {
    fs.mkdirSync(path.dirname(SECRET_FILE), { recursive: true });
    fs.writeFileSync(SECRET_FILE, s, { mode: 0o600 });
  } catch (err) {
    log("warn", `Could not persist hook secret: ${err.message}`);
  }
  hookSecret = s;
  return s;
}

// Per-device bearer tokens (replaces the old single global token). Each paired
// device gets its own revocable token; a legacy session-token file is migrated
// into one device on first load. Persisted to devices.json (0600).
const deviceStore = createDeviceStore(cfgPaths.devicesFile, cfgPaths.sessionTokenFile);

function loadPersistedToken() {
  deviceStore.reload();
  if (deviceStore.count() > 0) {
    log("info", `Restored ${deviceStore.count()} paired device(s) from disk — pairings survive restart.`);
  }
}

function clientIp(req) {
  return req.socket?.remoteAddress || "unknown";
}

function isRateLimited(req) {
  const now = Date.now();
  const e = rateLimits.get(clientIp(req));
  if (!e || now - e.windowStart > RATE_LIMIT_WINDOW_MS) return false;
  return e.count >= RATE_LIMIT_MAX_ATTEMPTS;
}

function recordRateLimitAttempt(req) {
  const now = Date.now();
  const ip = clientIp(req);
  let e = rateLimits.get(ip);
  if (!e || now - e.windowStart > RATE_LIMIT_WINDOW_MS) {
    e = { count: 0, windowStart: now };
    rateLimits.set(ip, e);
  }
  e.count++;
  // Bound memory: evict the oldest-tracked IP once the table gets large.
  if (rateLimits.size > RATE_LIMIT_MAX_IPS) {
    const oldest = rateLimits.keys().next().value;
    if (oldest !== undefined) rateLimits.delete(oldest);
  }
}

function requireAuth(req) {
  const auth = req.headers["authorization"];
  if (!auth || !auth.startsWith("Bearer ")) return false;
  const token = auth.slice(7);
  if (!deviceStore.isValid(token)) return false;
  deviceStore.touch(token);
  return true;
}

function jsonResponse(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

const MAX_BODY_BYTES = 4 * 1024 * 1024; // 4 MB cap — transcripts can be large

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("Request body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf-8");
        resolve(raw.length ? JSON.parse(raw) : {});
      } catch (err) {
        reject(err);
      }
    });
    req.on("error", reject);
  });
}

// Collect a raw (binary) request body up to maxBytes. Used for image uploads,
// which would otherwise hit readBody's 4 MB JSON cap and aren't JSON anyway.
function readRawBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > maxBytes) { reject(new Error("too-large")); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function availableAgentsList() {
  const agents = [];
  if (CLAUDE_BIN) agents.push("claude");
  if (CODEX_BIN) agents.push("codex");
  return agents;
}

// ---------------------------------------------------------------------------
// SSE helpers
// ---------------------------------------------------------------------------

function pushSseEvent(event, data, sessionId = null) {
  sseEventId++;

  // Inject sessionId into the data payload
  let payload;
  if (typeof data === "string") {
    try {
      payload = JSON.parse(data);
    } catch {
      payload = { raw: data };
    }
  } else {
    payload = { ...data };
  }
  if (sessionId !== null) {
    payload.sessionId = sessionId;
  }

  const entry = { id: sseEventId, event, data: JSON.stringify(payload) };

  // Ring buffer
  if (sseBuffer.length >= SSE_BUFFER_SIZE) {
    sseBuffer.shift();
  }
  sseBuffer.push(entry);

  // Broadcast to connected clients
  const formatted = formatSseMessage(entry);
  for (const client of sseClients) {
    try {
      client.write(formatted);
    } catch {
      sseClients.delete(client);
    }
  }
}

function formatSseMessage(entry) {
  let msg = `id: ${entry.id}\n`;
  msg += `event: ${entry.event}\n`;
  for (const line of entry.data.split("\n")) {
    msg += `data: ${line}\n`;
  }
  msg += "\n";
  return msg;
}

// ---------------------------------------------------------------------------
// Multi-session PTY management
// ---------------------------------------------------------------------------

function spawnInteractiveProcess(agent, cwd, args = []) {
  const bin = agent === "codex" ? CODEX_BIN : CLAUDE_BIN;
  if (!bin) {
    return null;
  }
  const cols = parseInt(process.env.COLUMNS, 10) || 120;
  const rows = parseInt(process.env.LINES, 10) || 40;

  return childSpawn("script", ["-q", "/dev/null", bin, ...args], {
    cwd,
    env: {
      ...process.env,
      TERM: "xterm-256color",
      COLUMNS: String(cols),
      LINES: String(rows),
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function bindPtyProcess(slot, proc) {
  const sessionId = slot.id;
  slot.ptyProcess = proc;

  proc.stdout.on("data", (data) => {
    pushSseEvent("pty-output", { text: data.toString() }, sessionId);
  });

  proc.stderr.on("data", (data) => {
    pushSseEvent("pty-output", { text: data.toString() }, sessionId);
  });

  proc.on("close", (exitCode, signal) => {
    log("info", `Session ${sessionId} (${slot.agent}) PTY exited: code=${exitCode} signal=${signal}`);
    slot.state = "ended";
    slot.ptyProcess = null;
    clearCodexSyntheticPermissionForSession(sessionId, "pty-closed");
    pushSseEvent("session", { state: "ended", exitCode, signal, agent: slot.agent, folderName: slot.folderName }, sessionId);
  });

  proc.on("error", (err) => {
    log("error", `Session ${sessionId} PTY spawn error: ${err.message}`);
    slot.state = "ended";
    slot.ptyProcess = null;
    clearCodexSyntheticPermissionForSession(sessionId, "pty-error");
    pushSseEvent("session", { state: "ended", error: err.message, agent: slot.agent, folderName: slot.folderName }, sessionId);
  });
}

function spawnSession(agent, cwd) {
  const sessionId = crypto.randomUUID();
  const folderName = path.basename(cwd) || cwd;

  log("info", `Spawning ${agent} session ${sessionId} in PTY (cwd: ${cwd})`);

  const proc = spawnInteractiveProcess(agent, cwd);
  if (!proc) {
    const msg = `Cannot spawn ${agent}: binary not found`;
    log("error", msg);
    pushSseEvent("error", { error: msg });
    return null;
  }

  log("info", `Using binary: ${agent === "codex" ? CODEX_BIN : CLAUDE_BIN}`);

  const slot = {
    id: sessionId,
    agent,
    cwd,
    folderName,
    ptyProcess: proc,
    state: "running",
    createdAt: Date.now(),
  };
  sessions.set(sessionId, slot);
  bindPtyProcess(slot, proc);

  pushSseEvent("session", { state: "running", agent, cwd, folderName }, sessionId);

  log("info", `${agent} session ${sessionId} started (${folderName}), pid: ${proc.pid}`);
  return sessionId;
}

function attachPtyToSession(slot) {
  if (slot.ptyProcess) return slot.ptyProcess;

  const args = slot.agent === "codex"
    ? ["resume", slot.id, "--no-alt-screen"]
    : [];

  const proc = spawnInteractiveProcess(slot.agent, slot.cwd, args);
  if (!proc) return null;

  bindPtyProcess(slot, proc);
  log("info", `Attached PTY to session ${slot.id} (${slot.agent}), pid: ${proc.pid}`);
  return proc;
}

function killSession(sessionId) {
  const slot = sessions.get(sessionId);
  if (!slot) return false;
  if (slot.ptyProcess) {
    try { slot.ptyProcess.kill(); } catch { /* ignore */ }
  }
  slot.state = "ended";
  slot.ptyProcess = null;
  pushSseEvent("session", { state: "ended", agent: slot.agent, folderName: slot.folderName, killed: true }, sessionId);
  log("info", `Session ${sessionId} killed`);
  return true;
}

function findSessionByCwd(cwd) {
  if (!cwd) return null;
  for (const [, slot] of sessions) {
    if (slot.cwd === cwd && slot.state === "running") return slot;
  }
  return null;
}

function findMostRecentActiveSession() {
  let best = null;
  for (const [, slot] of sessions) {
    if (slot.state === "running" && slot.ptyProcess) {
      if (!best || slot.createdAt > best.createdAt) {
        best = slot;
      }
    }
  }
  return best;
}

function findMostRecentRunningSession() {
  let best = null;
  for (const [, slot] of sessions) {
    if (slot.state === "running") {
      if (!best || slot.createdAt > best.createdAt) {
        best = slot;
      }
    }
  }
  return best;
}

function getSessionsSnapshot() {
  return Array.from(sessions.values()).map((s) => ({
    id: s.id,
    agent: s.agent,
    cwd: s.cwd,
    folderName: s.folderName,
    state: s.state,
    createdAt: s.createdAt,
  }));
}

function safeStat(targetPath) {
  try {
    return fs.statSync(targetPath);
  } catch {
    return null;
  }
}

function listRecentCodexSessionFiles(rootDir) {
  const results = [];
  const stack = [rootDir];

  while (stack.length > 0) {
    const current = stack.pop();
    let entries;
    try {
      entries = fs.readdirSync(current, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
      const stat = safeStat(fullPath);
      if (!stat) continue;
      results.push({ filePath: fullPath, mtimeMs: stat.mtimeMs, size: stat.size });
    }
  }

  results.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return results.slice(0, CODEX_SESSION_SCAN_LIMIT);
}

function readFileSlice(filePath, start, length) {
  const fd = fs.openSync(filePath, "r");
  try {
    const buffer = Buffer.alloc(length);
    const bytesRead = fs.readSync(fd, buffer, 0, length, start);
    return buffer.subarray(0, bytesRead).toString("utf-8");
  } finally {
    fs.closeSync(fd);
  }
}

function touchExternalSession(sessionId, cwd, createdAt) {
  const resolvedCwd = cwd || process.env.HOME || process.cwd();
  const folderName = path.basename(resolvedCwd) || resolvedCwd;
  const existing = sessions.get(sessionId);

  if (existing) {
    const wasEnded = existing.state !== "running";
    existing.agent = "codex";
    existing.cwd = resolvedCwd;
    existing.folderName = folderName;
    existing.state = "running";
    existing.createdAt = createdAt || existing.createdAt || Date.now();
    if (wasEnded) {
      pushSseEvent("session", { state: "running", agent: "codex", cwd: resolvedCwd, folderName }, sessionId);
      log("info", `Revived Codex session ${sessionId} (${folderName}) from local session data`);
    }
    return existing;
  }

  const slot = {
    id: sessionId,
    agent: "codex",
    cwd: resolvedCwd,
    folderName,
    ptyProcess: null,
    state: "running",
    createdAt: createdAt || Date.now(),
  };
  sessions.set(sessionId, slot);
  pushSseEvent("session", { state: "running", agent: "codex", cwd: resolvedCwd, folderName }, sessionId);
  log("info", `Detected Codex session ${sessionId} (${folderName}) from local session data`);
  return slot;
}

function endExternalSession(sessionId, reason = "codex-exit") {
  const slot = sessions.get(sessionId);
  if (!slot || slot.state === "ended") return;
  slot.state = "ended";
  slot.ptyProcess = null;
  clearCodexSyntheticPermissionForSession(sessionId, reason);
  pushSseEvent("session", { state: "ended", agent: slot.agent, folderName: slot.folderName, reason }, sessionId);
  log("info", `Marked external session ${sessionId} as ended (${reason})`);
}

function parseJsonLine(line) {
  try {
    return JSON.parse(line);
  } catch {
    return null;
  }
}

function parseFunctionCallArgs(rawArgs) {
  if (typeof rawArgs !== "string") return {};
  try {
    const parsed = JSON.parse(rawArgs);
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch {
    return {};
  }
}

function extractPatchPaths(rawPatch) {
  if (typeof rawPatch !== "string" || rawPatch.length === 0) return [];
  const paths = [];
  for (const line of rawPatch.split("\n")) {
    const match = line.match(/^\*\*\* (?:Update|Add|Delete) File: (.+)$/);
    if (match) paths.push(match[1]);
  }
  return [...new Set(paths)];
}

function emitCodexToolEvent(sessionId, toolName, toolInput = {}, toolOutput = null) {
  pushSseEvent("tool-output", {
    source: "codex",
    tool_name: toolName,
    tool_input: toolInput,
    tool_output: toolOutput,
  }, sessionId);
}

function emitCodexToolResult(sessionId, pendingCall, output) {
  if (!pendingCall || !sessionId) return;

  switch (pendingCall.name) {
    case "exec_command":
      emitCodexToolEvent(sessionId, "Bash", { command: pendingCall.args.cmd || "" }, output);
      break;
    case "apply_patch": {
      const patchPaths = extractPatchPaths(pendingCall.args.patch);
      if (patchPaths.length === 0) {
        emitCodexToolEvent(sessionId, "Edit", {}, output);
        break;
      }
      for (const filePath of patchPaths) {
        emitCodexToolEvent(sessionId, "Edit", { file_path: filePath }, output);
      }
      break;
    }
    default:
      emitCodexToolEvent(sessionId, pendingCall.name, pendingCall.args, output);
      break;
  }
}

function truncateText(value, maxLength = 80) {
  if (typeof value !== "string") return "";
  return value.length > maxLength ? `${value.slice(0, maxLength - 1)}…` : value;
}

function buildCodexApprovalOptions(_prefixRule = []) {
  // Short-term safety: only "allow once" and "deny". "Always allow" stays
  // disabled until structured (app-server) approvals land — blind-typing a
  // "don't ask again" into the TUI is too risky if the screen has changed.
  return [
    { label: "Yes, proceed", description: "Run this command once" },
    { label: "No", description: "Deny this command and return to Codex" },
  ];
}

function recordCodexExecApprovalCandidate(line) {
  const match = line.match(/ToolCall: exec_command (\{.*\}) thread_id=([0-9a-f-]+)/i);
  if (!match) return;

  let args;
  try {
    args = JSON.parse(match[1]);
  } catch {
    return;
  }

  if (args?.sandbox_permissions !== "require_escalated") return;

  codexExecApprovalCandidates.set(match[2], {
    command: args.cmd || "",
    justification: args.justification || "Would you like to run this command?",
    workdir: args.workdir || "",
    prefixRule: Array.isArray(args.prefix_rule) ? args.prefix_rule : [],
    createdAt: Date.now(),
  });
}

async function surfaceCodexExecApproval(sessionId) {
  const slot = sessions.get(sessionId);
  const candidate = codexExecApprovalCandidates.get(sessionId);
  if (!slot || !candidate) return;

  const existingId = codexSyntheticPermissionBySession.get(sessionId);
  if (existingId) return;

  // Pin the live terminal by matching the approval COMMAND against each
  // terminal's screen (cwd alone is ambiguous — a shell and a codex pane can
  // share a cwd). Only pin when exactly one terminal shows the command; if
  // zero/many, leave terminalId null so answering fails closed (the phone shows
  // an error rather than risking keystrokes into the wrong pane). Snapshot the
  // screen hash so the answer can be verified against the live screen.
  let terminalId = null;
  let screenHash = null;
  let ambiguousTerminal = false;
  if (cmux.cmuxAvailable()) {
    try {
      const found = await cmux.findCodexApprovalTerminal(candidate.command);
      terminalId = found.id;
      ambiguousTerminal = found.ambiguous;
      if (terminalId) screenHash = await cmux.screenHash(terminalId);
    } catch { /* leave unpinned -> fail closed on answer */ }
  }

  const permissionId = crypto.randomUUID();
  const options = buildCodexApprovalOptions(candidate.prefixRule);
  const payload = {
    permissionId,
    source: "codex",
    tool_name: "ExecApproval",
    terminalId,
    screenHash,
    tool_input: {
      command: candidate.command,
      workdir: candidate.workdir,
      questions: [
        {
          header: truncateText(`Run: ${candidate.command}`, 72),
          question: candidate.justification || "Would you like to run this command?",
          options,
        },
      ],
    },
  };
  codexSyntheticPermissions.set(permissionId, {
    sessionId, optionCount: options.length, terminalId, screenHash, ambiguousTerminal, payload,
  });
  codexSyntheticPermissionBySession.set(sessionId, permissionId);

  pushSseEvent("permission-request", payload, sessionId);

  log("info", `Surfaced Codex approval ${permissionId} for session ${sessionId}${terminalId ? ` (terminal ${terminalId.slice(0, 8)})` : ambiguousTerminal ? " (AMBIGUOUS terminal — answer will fail closed)" : " (no terminal matched)"}`);
}

function clearCodexSyntheticPermissionForSession(sessionId, reason = "cleared") {
  const permissionId = codexSyntheticPermissionBySession.get(sessionId);
  if (!permissionId) return false;

  codexSyntheticPermissionBySession.delete(sessionId);
  codexSyntheticPermissions.delete(permissionId);
  codexExecApprovalCandidates.delete(sessionId);
  pushSseEvent("permission-cleared", { permissionId, reason }, sessionId);
  return true;
}

async function resolveCodexSyntheticPermission(permissionId, selectedOption, optionIndex, opts = {}) {
  const synthetic = codexSyntheticPermissions.get(permissionId);
  if (!synthetic) return false;

  const slot = sessions.get(synthetic.sessionId);
  if (!slot) return false;

  const idx = Number.isInteger(optionIndex) ? optionIndex : -1;
  const proceed = idx === 0 || /^yes,?\s*proceed/i.test(String(selectedOption || ""));
  const dontAsk = synthetic.optionCount === 3
    && (idx === 1 || /^yes,?\s*don't ask again/i.test(String(selectedOption || "")));

  // Codex approvals inject keystrokes into a LIVE terminal, so this path is
  // FAIL-CLOSED: any uncertainty about which terminal, or whether its screen is
  // still the one being answered, keeps the card and surfaces an error. There
  // is deliberately NO PTY fallback — attaching a 2nd codex via `resume` would
  // report success while the real cmux codex keeps waiting.
  if (!cmux.cmuxAvailable()) {
    return { status: 503, reason: "cmux-unavailable" };
  }
  // 1) The terminal must have been UNAMBIGUOUSLY pinned at surface time.
  const terminalId = synthetic.terminalId;
  if (!terminalId) {
    return { status: 409, reason: synthetic.ambiguousTerminal ? "ambiguous-terminal" : "no-terminal" };
  }
  // 2) The phone MUST echo the same terminal we pinned (no implicit cwd lookup).
  if (!opts.terminalId || opts.terminalId !== terminalId) {
    return { status: 409, reason: "terminal-mismatch" };
  }
  // 3) The phone MUST supply a hash, and it must equal the LIVE screen hash —
  //    i.e. the phone is answering the screen currently on the terminal
  //    (TOCTOU-safe). On a stale hash we return currentHash so the phone can
  //    re-show the live screen and let the user re-confirm with the fresh hash.
  const currentHash = await cmux.screenHash(terminalId);
  if (!currentHash) {
    return { status: 503, reason: "screen-unreadable" };
  }
  if (!opts.expectedScreenHash || opts.expectedScreenHash !== currentHash) {
    return { status: 409, reason: "screen-changed", currentHash };
  }
  // All checks passed — inject. cmux failure is fail-closed (503), never PTY.
  try {
    if (proceed) {
      await cmux.sendInput(terminalId, "y", false);
    } else if (dontAsk) {
      await cmux.sendInput(terminalId, "2", false);
      await cmux.sendNamedKey(terminalId, "enter");
    } else {
      await cmux.sendNamedKey(terminalId, "escape"); // deny / cancel
    }
  } catch (err) {
    log("warn", `cmux codex approval send failed (${err.message}); keeping card (no PTY fallback)`);
    return { status: 503, reason: "cmux-send-failed" };
  }
  clearCodexSyntheticPermissionForSession(synthetic.sessionId, "resolved");
  log("info", `cmux codex approval ${permissionId} -> terminal ${terminalId.slice(0, 8)}`);
  return true;
}

function handleCodexJsonlLine(line, fileState, options = {}) {
  const parsed = parseJsonLine(line);
  if (!parsed) return;

  const bootstrap = options.bootstrap === true;

  if (parsed.type === "session_meta") {
    const sessionId = parsed.payload?.id;
    if (!sessionId) return;

    fileState.sessionId = sessionId;
    fileState.cwd = parsed.payload?.cwd || fileState.cwd;
    fileState.createdAt = Date.parse(parsed.payload?.timestamp || parsed.timestamp || "") || fileState.createdAt || Date.now();

    if (bootstrap && options.allowBootstrap !== true) return;

    touchExternalSession(sessionId, fileState.cwd, fileState.createdAt);
    return;
  }

  const sessionId = fileState.sessionId;
  if (!sessionId || bootstrap) return;
  if (!sessions.has(sessionId) || sessions.get(sessionId)?.state !== "running") {
    touchExternalSession(sessionId, fileState.cwd, fileState.createdAt);
  }

  if (parsed.type === "response_item" && parsed.payload?.type === "function_call") {
    const callId = parsed.payload.call_id;
    if (!callId) return;
    codexPendingToolCalls.set(callId, {
      sessionId,
      name: parsed.payload.name,
      args: parseFunctionCallArgs(parsed.payload.arguments),
    });
    return;
  }

  if (parsed.type === "response_item" && parsed.payload?.type === "function_call_output") {
    const pendingCall = codexPendingToolCalls.get(parsed.payload.call_id);
    emitCodexToolResult(sessionId, pendingCall, parsed.payload.output ?? null);
    if (parsed.payload.call_id) {
      codexPendingToolCalls.delete(parsed.payload.call_id);
    }
    return;
  }

  if (parsed.type !== "event_msg") return;

  const payloadType = parsed.payload?.type;
  if (payloadType === "task_started") {
    touchExternalSession(sessionId, fileState.cwd, fileState.createdAt);
    return;
  }
  if (payloadType === "agent_message" && parsed.payload?.message) {
    emitCodexToolEvent(sessionId, "CodexMessage", {}, parsed.payload.message);
    return;
  }
  if (payloadType === "exec_command_end") {
    const pendingCall = codexPendingToolCalls.get(parsed.payload.call_id);
    const command = pendingCall?.args?.cmd
      || (Array.isArray(parsed.payload.command) ? parsed.payload.command.join(" ") : "");
    emitCodexToolEvent(sessionId, "Bash", { command }, parsed.payload.aggregated_output ?? null);
    if (parsed.payload.call_id) {
      codexPendingToolCalls.delete(parsed.payload.call_id);
    }
    return;
  }
  if (payloadType === "task_complete") {
    pushSseEvent("task-complete", { source: "codex" }, sessionId);
  }
}

function initializeCodexSessionFile(filePath, stat, fileState) {
  const headerSize = Math.min(stat.size, 64 * 1024);
  const header = headerSize > 0 ? readFileSlice(filePath, 0, headerSize) : "";
  const allowBootstrap = Date.now() - stat.mtimeMs <= CODEX_SESSION_BOOTSTRAP_LOOKBACK_MS;

  for (const line of header.split("\n")) {
    if (!line.trim()) continue;
    handleCodexJsonlLine(line, fileState, { bootstrap: true, allowBootstrap });
    if (fileState.sessionId) break;
  }

  fileState.offset = stat.size;
  fileState.remainder = "";
  fileState.initialized = true;
}

function readCodexSessionFileDelta(filePath, stat, fileState) {
  if (stat.size < fileState.offset) {
    fileState.offset = 0;
    fileState.remainder = "";
  }
  if (stat.size === fileState.offset) return;

  const delta = readFileSlice(filePath, fileState.offset, stat.size - fileState.offset);
  fileState.offset = stat.size;

  let chunk = fileState.remainder + delta;
  const lines = chunk.split("\n");
  fileState.remainder = lines.pop() ?? "";

  for (const line of lines) {
    if (!line.trim()) continue;
    handleCodexJsonlLine(line, fileState);
  }
}

function scanCodexSessionFiles() {
  const statRoot = safeStat(CODEX_SESSION_ROOT);
  if (!statRoot || !statRoot.isDirectory()) return;

  const seen = new Set();
  for (const entry of listRecentCodexSessionFiles(CODEX_SESSION_ROOT)) {
    seen.add(entry.filePath);
    const fileState = codexSessionFiles.get(entry.filePath) || {
      offset: 0,
      remainder: "",
      sessionId: null,
      cwd: undefined,
      createdAt: undefined,
      initialized: false,
    };

    if (!fileState.initialized) {
      initializeCodexSessionFile(entry.filePath, entry, fileState);
      codexSessionFiles.set(entry.filePath, fileState);
      continue;
    }

    readCodexSessionFileDelta(entry.filePath, entry, fileState);
    codexSessionFiles.set(entry.filePath, fileState);
  }

  for (const filePath of codexSessionFiles.keys()) {
    if (!seen.has(filePath)) {
      codexSessionFiles.delete(filePath);
    }
  }
}

async function consumeCodexLogChunk(text) {
  const combined = codexLogState.remainder + text;
  const lines = combined.split("\n");
  codexLogState.remainder = lines.pop() ?? "";

  for (const line of lines) {
    recordCodexExecApprovalCandidate(line);

    const approvalMatch = line.match(/thread_id=([0-9a-f-]+).*codex\.op="exec_approval".*codex_core::codex: (new|close)/i);
    if (approvalMatch) {
      const [, sessionId, state] = approvalMatch;
      if (state === "new") {
        await surfaceCodexExecApproval(sessionId);
      } else {
        clearCodexSyntheticPermissionForSession(sessionId, "closed");
      }
    }

    if (line.includes("Shutting down Codex instance")) {
      const match = line.match(/thread_id=([0-9a-f-]+)/i);
      if (match) {
        clearCodexSyntheticPermissionForSession(match[1], "codex-shutdown");
        endExternalSession(match[1], "codex-shutdown");
      }
    }
  }
}

async function scanCodexLog() {
  const stat = safeStat(CODEX_LOG_FILE);
  if (!stat || !stat.isFile()) return;

  if (!codexLogState.initialized) {
    const lookbackSize = Math.min(stat.size, 128 * 1024);
    const startOffset = Math.max(0, stat.size - lookbackSize);
    const bootstrapText = lookbackSize > 0 ? readFileSlice(CODEX_LOG_FILE, startOffset, lookbackSize) : "";
    codexLogState.offset = stat.size;
    codexLogState.remainder = "";
    codexLogState.initialized = true;
    if (bootstrapText) {
      await consumeCodexLogChunk(bootstrapText);
    }
    return;
  }

  if (stat.size < codexLogState.offset) {
    codexLogState.offset = 0;
    codexLogState.remainder = "";
  }
  if (stat.size === codexLogState.offset) return;

  const text = readFileSlice(CODEX_LOG_FILE, codexLogState.offset, stat.size - codexLogState.offset);
  codexLogState.offset = stat.size;
  await consumeCodexLogChunk(text);
}

function startCodexMonitor() {
  if (codexMonitorInterval) return;

  scanCodexSessionFiles();
  scanCodexLog().catch((err) => log("warn", `Codex log scan failed: ${err.message}`));

  codexMonitorInterval = setInterval(() => {
    try {
      scanCodexSessionFiles();
    } catch (err) {
      log("warn", `Codex monitor scan failed: ${err.message}`);
    }
    scanCodexLog().catch((err) => log("warn", `Codex log scan failed: ${err.message}`));
  }, CODEX_SESSION_SCAN_INTERVAL_MS);
}

function stopCodexMonitor() {
  if (codexMonitorInterval) {
    clearInterval(codexMonitorInterval);
    codexMonitorInterval = null;
  }
}

// ---------------------------------------------------------------------------
// Permission flow
// ---------------------------------------------------------------------------

// Forget a permission everywhere and tell clients to drop its card.
function clearPermissionState(permissionId, reason) {
  const stored = pendingPermissionPayloads.get(permissionId);
  pendingPermissionPayloads.delete(permissionId);
  pendingPermissionBodies.delete(permissionId);
  pushSseEvent("permission-cleared", { permissionId, reason }, stored ? stored.sessionId : null);
}

function waitForPermission(permissionId) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => {
      pendingPermissions.delete(permissionId);
      clearPermissionState(permissionId, "timeout"); // notify clients + free memory
      log("warn", `Permission ${permissionId} timed out after ${PERMISSION_TIMEOUT_MS / 1000}s, auto-denying`);
      resolve({ behavior: "deny", reason: "Timed out waiting for watch response" });
    }, PERMISSION_TIMEOUT_MS);

    pendingPermissions.set(permissionId, { resolve, timer });
  });
}

function resolvePermission(permissionId, decision) {
  const pending = pendingPermissions.get(permissionId);
  if (!pending) return false;
  clearTimeout(pending.timer);
  pendingPermissions.delete(permissionId);
  pending.resolve(decision);
  clearPermissionState(permissionId, "resolved"); // clear card on other devices + free memory
  return true;
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

async function handlePair(req, res) {
  if (req.method !== "POST") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }

  if (isRateLimited(req)) {
    return jsonResponse(res, 429, { error: "Too many pairing attempts. Try again later." });
  }

  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  recordRateLimitAttempt(req);

  const { code, deviceName, deviceId } = body;
  if (!code || typeof code !== "string") {
    return jsonResponse(res, 400, { error: "Missing 'code' field" });
  }

  if (Date.now() > pairingCodeExpiresAt) {
    generatePairingCode();
    return jsonResponse(res, 401, { error: "Pairing code expired. A new code has been generated." });
  }

  if (code !== pairingCode) {
    return jsonResponse(res, 401, { error: "Invalid pairing code" });
  }

  // Success — issue a NEW per-device token (existing devices stay paired).
  const device = deviceStore.add({
    name: typeof deviceName === "string" && deviceName.trim() ? deviceName.trim().slice(0, 60) : "iPhone",
    id: typeof deviceId === "string" && deviceId.trim() ? deviceId.trim().slice(0, 100) : undefined,
  });
  if (!FIXED_PAIRING_CODE) {
    pairingCode = null;
    pairingCodeExpiresAt = 0;
  }
  bridgeState = "connected";
  pushSseEvent("session", { state: "connected" });

  log("info", `Device paired: ${device.name} (${device.id.slice(0, 8)}) — ${deviceStore.count()} device(s) total`);
  return jsonResponse(res, 200, {
    token: device.token,
    deviceId: device.id,
    bridgeId: BRIDGE_ID,
    sessionId: BRIDGE_ID, // backward compat
    machineName: os.hostname(),
    availableAgents: availableAgentsList(),
    sessions: getSessionsSnapshot(),
  });
}

async function handleCommand(req, res) {
  if (req.method !== "POST") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }
  if (!requireAuth(req)) {
    return jsonResponse(res, 401, { error: "Unauthorized" });
  }

  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const {
    command,
    permissionId,
    decision,
    allowAll,
    agent,
    sessionId,
    spawn: spawnRequest,
    kill: killRequest,
    selectedOption,
    optionIndex,
  } = body;

  // --- Direct cmux key event (mobile mirror, drives interactive TUI pickers) ---
  // e.g. codex's "/model" popup: arrows to move, enter to accept, escape to
  // back out. Sent as raw ANSI via mobile.terminal.input (see cmux.sendNamedKey).
  if (body.key !== undefined && body.terminalId) {
    if (!cmux.cmuxAvailable()) return jsonResponse(res, 503, { error: "cmux not available" });
    const key = String(body.key);
    if (!cmux.isNamedKey(key)) return jsonResponse(res, 400, { error: `unsupported key: ${key}` });
    try {
      await cmux.sendNamedKey(body.terminalId, key);
      log("info", `cmux mobile key -> terminal ${String(body.terminalId).slice(0, 8)}: ${key}`);
      return jsonResponse(res, 200, { ok: true, terminalId: body.terminalId, key, via: "cmux-mobile" });
    } catch (err) {
      return jsonResponse(res, 500, { error: `cmux key failed: ${err.message}` });
    }
  }

  // --- Direct cmux terminal input (mobile mirror) ---
  if (command !== undefined && body.terminalId) {
    if (!cmux.cmuxAvailable()) return jsonResponse(res, 503, { error: "cmux not available" });
    const promptText = String(command).replace(/\n$/, "");

    // Safety guard for approval-style responses: if the phone sends the hash of
    // the screen it rendered, refuse to type when the screen has since changed —
    // so a "yes"/"no" can't land on a different prompt. Normal prompts omit the
    // hash and are unaffected. (See the A-safely conditions for cmux approvals.)
    if (body.expectedScreenHash) {
      const currentHash = await cmux.screenHash(body.terminalId);
      if (currentHash !== body.expectedScreenHash) {
        return jsonResponse(res, 409, {
          error: "screen-changed",
          currentHash,
          currentScreen: (await cmux.readTerminalText(body.terminalId)) || "",
        });
      }
    }

    try {
      await cmux.sendInput(body.terminalId, promptText, body.submit !== false);
      log("info", `cmux mobile input -> terminal ${String(body.terminalId).slice(0, 8)} (${promptText.length} chars)`);
      // Re-read so the caller can confirm the approval prompt was consumed.
      const afterHash = body.expectedScreenHash ? await cmux.screenHash(body.terminalId) : undefined;
      return jsonResponse(res, 200, { ok: true, terminalId: body.terminalId, via: "cmux-mobile", afterHash });
    } catch (err) {
      return jsonResponse(res, 500, { error: `cmux input failed: ${err.message}` });
    }
  }

  // --- Spawn a new session ---
  if (spawnRequest) {
    const validAgents = ["claude", "codex"];
    if (!validAgents.includes(spawnRequest)) {
      return jsonResponse(res, 400, { error: `Invalid agent: ${spawnRequest}. Use: ${validAgents.join(", ")}` });
    }
    const cwd = body.cwd || process.argv[2] || process.env.HOME || process.cwd();
    const newId = spawnSession(spawnRequest, cwd);
    if (!newId) {
      return jsonResponse(res, 500, { error: `Failed to spawn ${spawnRequest}` });
    }
    return jsonResponse(res, 200, { ok: true, sessionId: newId, agent: spawnRequest });
  }

  // --- Kill a session ---
  if (killRequest && sessionId) {
    const killed = killSession(sessionId);
    if (!killed) {
      return jsonResponse(res, 404, { error: "No session with that ID" });
    }
    return jsonResponse(res, 200, { ok: true });
  }

  // --- Permission response ---
  if (permissionId && (decision || selectedOption !== undefined || Number.isInteger(optionIndex))) {
    if (decision) {
      if (allowAll && decision.behavior === "allow") {
        decision.updatedPermissions = pendingPermissionBodies.get(permissionId) || [];
        // Also remember (session, tool) bridge-side: Claude Code doesn't always
        // send permission_suggestions (MCP tools), and without them allow-all
        // degrades to a one-shot allow — the phone gets re-prompted every call.
        const stored = pendingPermissionPayloads.get(permissionId);
        if (stored && stored.tool_name) {
          autoAllowTools.add(`${stored.sessionId || ""}:${stored.tool_name}`);
          log("info", `Auto-allow armed: ${stored.tool_name} (session ${stored.sessionId || "?"})`);
        }
      }
      pendingPermissionBodies.delete(permissionId);

      // Forward the watch's selected option so the hook response can include it
      if (selectedOption !== undefined) decision.selectedOption = selectedOption;
      if (Number.isInteger(optionIndex)) decision.optionIndex = optionIndex;

      const resolved = resolvePermission(permissionId, decision);
      if (resolved) {
        log("info", `Permission ${permissionId} resolved: ${decision.behavior}${allowAll ? " (allow all)" : ""}`);
        return jsonResponse(res, 200, { ok: true });
      }
    }

    const resolvedSynthetic = await resolveCodexSyntheticPermission(
      permissionId, selectedOption, optionIndex,
      { terminalId: body.terminalId, expectedScreenHash: body.expectedScreenHash }
    );
    if (resolvedSynthetic === true) {
      return jsonResponse(res, 200, { ok: true });
    }
    if (resolvedSynthetic && typeof resolvedSynthetic === "object" && resolvedSynthetic.status) {
      // Fail-closed: 409 (screen changed / terminal can't be pinned, phone must
      // re-check) or 503 (cmux unavailable/send failed) — card stays either way.
      return jsonResponse(res, resolvedSynthetic.status, {
        error: resolvedSynthetic.reason || "codex-approval-unresolved",
        reason: resolvedSynthetic.reason,
        currentHash: resolvedSynthetic.currentHash,
      });
    }

    return jsonResponse(res, 404, { error: "No pending permission with that ID" });
  }

  // --- PTY command injection ---
  if (command !== undefined) {
    // Find the target session
    let targetSession = null;

    if (sessionId) {
      targetSession = sessions.get(sessionId);
      if (targetSession && !targetSession.ptyProcess) {
        // Session exists but has no PTY (external hook-created session).
        // Run the prompt via CLI in non-interactive mode — hooks will forward output.
        const promptText = command.replace(/\n$/, "").trim();
        if (!promptText) {
          return jsonResponse(res, 400, { error: "Empty command" });
        }

        // Preferred: type straight into the LIVE cmux terminal for this session,
        // so the prompt lands in the interactive Claude/Codex you are watching
        // (not a detached headless run). Resolve by cwd via mobile.workspace.list
        // + inject via mobile.terminal.input (the path that actually reaches a
        // mobile cmux terminal).
        if (cmux.cmuxAvailable()) {
          const terminalId = await cmux.resolveTerminalId(targetSession.cwd);
          if (terminalId) {
            try {
              await cmux.sendInput(terminalId, promptText, true);
              log("info", `cmux input -> terminal ${terminalId.slice(0, 8)} (${targetSession.cwd}) (${promptText.length} chars)`);
              pushSseEvent("pty-output", { text: `> ${promptText}` }, sessionId);
              return jsonResponse(res, 200, { ok: true, sessionId, agent: targetSession.agent, via: "cmux", terminalId });
            } catch (err) {
              log("warn", `cmux input failed (${err.message}); falling back to detached run`);
            }
          } else {
            log("warn", `No live cmux terminal for ${targetSession.cwd}; falling back to detached run`);
          }
        }

        const bin = targetSession.agent === "codex" ? CODEX_BIN : CLAUDE_BIN;
        if (!bin) {
          return jsonResponse(res, 500, { error: `No binary found for ${targetSession.agent}` });
        }

        const args = targetSession.agent === "codex"
          ? ["exec", promptText]
          : ["-p", promptText, "--continue"];

        log("info", `Running ${targetSession.agent} prompt in ${targetSession.cwd} (${promptText.length} chars)`);

        targetSession.state = "running";
        pushSseEvent("session", { state: "running", agent: targetSession.agent, cwd: targetSession.cwd, folderName: targetSession.folderName }, sessionId);

        const proc = childSpawn(bin, args, {
          cwd: targetSession.cwd,
          env: { ...process.env },
          stdio: ["ignore", "pipe", "pipe"],
        });

        proc.stdout.on("data", (data) => {
          const text = data.toString().trim();
          if (text) pushSseEvent("pty-output", { text }, sessionId);
        });
        proc.stderr.on("data", (data) => {
          const text = data.toString().trim();
          if (text && !text.includes("tcgetattr")) {
            pushSseEvent("pty-output", { text }, sessionId);
          }
        });
        proc.on("close", (exitCode) => {
          log("info", `Prompt process exited (code ${exitCode}) for session ${sessionId}`);
        });
        proc.on("error", (err) => {
          log("error", `Prompt process error for session ${sessionId}: ${err.message}`);
        });

        return jsonResponse(res, 200, { ok: true, sessionId, agent: targetSession.agent, prompt: true });
      }
      if (!targetSession) {
        return jsonResponse(res, 404, { error: "No session with that ID" });
      }
    } else {
      // Backward compat: route to the most recent active session
      targetSession = findMostRecentActiveSession() || findMostRecentRunningSession();
    }

    if (!targetSession) {
      // Auto-spawn a new session
      const requestedAgent = agent || "claude";
      const cwd = body.cwd || process.argv[2] || process.env.HOME || process.cwd();
      const newId = spawnSession(requestedAgent, cwd);
      if (!newId) {
        return jsonResponse(res, 500, { error: `Failed to spawn ${requestedAgent}` });
      }
      const slot = sessions.get(newId);
      setTimeout(() => {
        if (slot && slot.ptyProcess) {
          slot.ptyProcess.stdin.write(command);
          log("info", `Command injected into new ${requestedAgent} session ${newId} (${command.length} chars)`);
        }
      }, 500);
      return jsonResponse(res, 200, { ok: true, sessionId: newId, agent: requestedAgent, spawned: true });
    }

    try {
      targetSession.ptyProcess.stdin.write(command);
      log("info", `Command injected into session ${targetSession.id} (${command.length} chars)`);
      return jsonResponse(res, 200, { ok: true, sessionId: targetSession.id, agent: targetSession.agent });
    } catch (err) {
      return jsonResponse(res, 500, { error: err.message });
    }
  }

  return jsonResponse(res, 400, { error: "Missing 'command', 'spawn', 'kill', or 'permissionId'+'decision'" });
}

function handleEvents(req, res) {
  if (req.method !== "GET") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }
  // SSE: accept the token via header OR ?token= query (Safari EventSource can't set headers).
  const evUrl = new URL(req.url, `http://${req.headers.host}`);
  const qToken = evUrl.searchParams.get("token");
  const tokenOk = requireAuth(req) || deviceStore.isValid(qToken);
  if (qToken && deviceStore.isValid(qToken)) deviceStore.touch(qToken);
  if (!tokenOk) {
    return jsonResponse(res, 401, { error: "Unauthorized" });
  }

  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "X-Accel-Buffering": "no",
  });

  // Replay from Last-Event-ID if provided
  const lastIdHeader = req.headers["last-event-id"];
  if (lastIdHeader) {
    const lastId = parseInt(lastIdHeader, 10);
    if (!isNaN(lastId)) {
      for (const entry of sseBuffer) {
        if (entry.id > lastId) {
          res.write(formatSseMessage(entry));
        }
      }
    }
  }

  sseClients.add(res);
  bridgeState = "connected";
  log("info", `SSE client connected (total: ${sseClients.size})`);

  // Re-send still-pending approvals so a reconnecting / backgrounded client
  // never misses one (the ring buffer may have rotated past the original).
  for (const payload of pendingPermissionPayloads.values()) {
    sseEventId++;
    res.write(formatSseMessage({ id: sseEventId, event: "permission-request", data: JSON.stringify(payload) }));
  }

  // Send current sessions state so late-connecting clients see existing sessions
  for (const [sid, slot] of sessions) {
    if (slot.state === "running") {
      const syncEntry = formatSseMessage({
        id: sseEventId++,
        event: "session",
        data: JSON.stringify({
          state: "running",
          agent: slot.agent,
          cwd: slot.cwd,
          folderName: slot.folderName,
          sessionId: sid,
        }),
      });
      try { res.write(syncEntry); } catch { /* ignore */ }
    }
  }

  for (const [permissionId, synthetic] of codexSyntheticPermissions) {
    const syncEntry = formatSseMessage({
      id: sseEventId++,
      event: "permission-request",
      data: JSON.stringify({
        ...synthetic.payload,
        permissionId,
        sessionId: synthetic.sessionId,
      }),
    });
    try { res.write(syncEntry); } catch { /* ignore */ }
  }

  const heartbeat = setInterval(() => {
    try {
      res.write(":heartbeat\n\n");
    } catch {
      clearInterval(heartbeat);
      sseClients.delete(res);
    }
  }, SSE_HEARTBEAT_INTERVAL_MS);

  req.on("close", () => {
    clearInterval(heartbeat);
    sseClients.delete(res);
    if (sseClients.size === 0) bridgeState = "idle";
    log("info", `SSE client disconnected (total: ${sseClients.size})`);
  });
}

// --- Hook handlers ---
// Hooks come from Claude Code instances. We match by cwd to find the session.

function resolveHookSession(body) {
  const source = body.source || "claude";
  const agent = source === "codex" ? "codex" : "claude";
  const claudeSid = body.session_id || null; // the agent's own session id
  const cwd = body.session_cwd || body.cwd || null;

  const createSlot = (id) => {
    const resolvedCwd = cwd || process.argv[2] || process.env.HOME || process.cwd();
    const folderName = path.basename(resolvedCwd) || resolvedCwd;
    const slot = {
      id, agent, cwd: resolvedCwd, folderName,
      ptyProcess: null, // external process — no PTY owned by bridge
      state: "running", createdAt: Date.now(),
    };
    sessions.set(id, slot);
    log("info", `Session ${id} (${agent}) registered from hook (${folderName})`);
    pushSseEvent("session", { state: "running", agent, cwd: resolvedCwd, folderName }, id);
    return id;
  };

  // 1) Primary: key by the agent's real session_id — stable and unambiguous, so
  //    multiple sessions in the same cwd (Claude+Codex, multiple windows, repeat
  //    sessions of one project) never get cross-wired.
  if (claudeSid) {
    const existing = sessions.get(claudeSid);
    if (existing) {
      if (existing.state === "ended") existing.state = "running";
      return existing.id;
    }
    return createSlot(claudeSid);
  }

  // 2) No session_id (e.g. Codex hooks): match by cwd AND agent so Codex events
  //    never attach to a Claude slot in the same folder.
  for (const [, s] of sessions) {
    if (s.agent === agent && s.cwd === cwd && s.state !== "ended") return s.id;
  }
  // 3) Most-recent active session of the SAME agent.
  let best = null;
  for (const [, s] of sessions) {
    if (s.agent !== agent || s.state === "ended") continue;
    if (!best || (s.createdAt || 0) > (best.createdAt || 0)) best = s;
  }
  if (best) return best.id;

  // 4) Nothing matched — create one.
  return createSlot(crypto.randomUUID());
}

async function handleHookToolOutput(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  const source = body.source || "claude";
  log("info", `Hook: ${source === "codex" ? "Codex" : "PostToolUse"} received [${source}]${sid ? ` session=${sid}` : ""}`, body.tool_name || "");
  pushSseEvent("tool-output", { ...body, source }, sid);
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookPermission(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  // Disable Node.js default 5-minute requestTimeout for this long-lived blocking request.
  // The hook waits up to PERMISSION_TIMEOUT_MS (10 min) for a watch response.
  req.socket.setTimeout(0);

  const sid = resolveHookSession(body);

  // User already said "allow all" for this (session, tool) from the phone —
  // answer immediately instead of re-prompting on every call.
  if (body.tool_name && autoAllowTools.has(`${sid || ""}:${body.tool_name}`)) {
    log("info", `Hook: PermissionRequest auto-allowed (${body.tool_name})${sid ? ` session=${sid}` : ""}`);
    return jsonResponse(res, 200, {
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: { behavior: "allow" },
      },
    });
  }

  const permissionId = crypto.randomUUID();
  log("info", `Hook: PermissionRequest received (id: ${permissionId})${sid ? ` session=${sid}` : ""}`, body.tool_name || "");

  if (body.permission_suggestions) {
    pendingPermissionBodies.set(permissionId, body.permission_suggestions);
  }
  // Keep the full payload so it can be re-sent to clients that (re)connect.
  pendingPermissionPayloads.set(permissionId, { permissionId, ...body, sessionId: sid });

  pushSseEvent("permission-request", { permissionId, ...body }, sid);

  const decision = await waitForPermission(permissionId);

  log("info", `Hook: PermissionRequest resolved (id: ${permissionId}): ${decision.behavior}`);

  const hookResponse = {
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: decision.behavior },
    },
  };

  if (decision.updatedPermissions && decision.updatedPermissions.length > 0) {
    hookResponse.hookSpecificOutput.decision.updatedPermissions = decision.updatedPermissions;
  }

  if (decision.behavior === "deny" && decision.message) {
    hookResponse.hookSpecificOutput.decision.message = decision.message;
  }

  // For AskUserQuestion: forward the watch-selected option as the answer so Claude
  // Code doesn't fall back to waiting for terminal input.
  if (decision.selectedOption !== undefined && body.tool_name === "AskUserQuestion") {
    const questions = body.tool_input?.questions;
    if (questions && questions.length > 0 && questions[0]?.question) {
      const answers = { [questions[0].question]: decision.selectedOption };
      hookResponse.hookSpecificOutput.decision.updatedInput = { questions, answers };
      log("info", `AskUserQuestion answer forwarded`);
    }
  }

  return jsonResponse(res, 200, hookResponse);
}

// Claude Code hooks never carry the assistant's reply text — it only lives in
// the session transcript (JSONL). The Stop payload gives us transcript_path, so
// read it and pull the text of the final assistant turn (the actual answer).
function extractFinalAssistantText(transcriptPath) {
  if (!transcriptPath || typeof transcriptPath !== "string") return null;
  let raw;
  try {
    raw = fs.readFileSync(transcriptPath, "utf8");
  } catch (err) {
    log("warn", `Stop: could not read transcript ${transcriptPath}: ${err.message}`);
    return null;
  }
  const lines = raw.split("\n");
  // Walk backwards to the most recent assistant message that has text content.
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    if (entry.type !== "assistant") continue;
    const content = entry.message?.content;
    let text = "";
    if (typeof content === "string") {
      text = content;
    } else if (Array.isArray(content)) {
      text = content
        .filter((b) => b && b.type === "text" && typeof b.text === "string")
        .map((b) => b.text)
        .join("\n");
    }
    text = text.trim();
    if (text) return text;
  }
  return null;
}

async function handleHookStop(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  log("info", `Hook: Stop received${sid ? ` session=${sid}` : ""}`);

  // Attach the final answer text on a real Stop (skip Codex and Notification
  // pings, which would otherwise re-send the same text and create duplicates).
  if (body.source !== "codex" && body.hook_event_name !== "Notification" && body.transcript_path) {
    const assistantText = extractFinalAssistantText(body.transcript_path);
    if (assistantText) {
      body.assistantText = assistantText;
      log("info", `Stop: forwarded final answer (${assistantText.length} chars)`);
    }
  }

  pushSseEvent("stop", body, sid);
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookTaskComplete(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  log("info", `Hook: TaskCompleted received${sid ? ` session=${sid}` : ""}`);
  pushSseEvent("task-complete", body, sid);
  return jsonResponse(res, 200, { ok: true });
}

async function handleHookError(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const sid = resolveHookSession(body);
  log("info", `Hook: Error received${sid ? ` session=${sid}` : ""}`, body.error || "");
  pushSseEvent("error", body, sid);
  return jsonResponse(res, 200, { ok: true });
}

// SessionEnd — mark the external session ended and drop it after a grace period
// so the list doesn't accumulate dead "running" sessions forever.
async function handleHookSessionEnd(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }
  const sid = body.session_id;
  const slot = sid ? sessions.get(sid) : null;
  if (slot) {
    slot.state = "ended";
    log("info", `Hook: SessionEnd ${sid}`);
    pushSseEvent("session", { state: "ended", agent: slot.agent, folderName: slot.folderName }, sid);
    setTimeout(() => {
      if (sessions.get(sid)?.state === "ended") sessions.delete(sid);
    }, 30000);
  }
  return jsonResponse(res, 200, { ok: true });
}

// SessionStart — register the session up front so it appears before any tool use.
async function handleHookSessionStart(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }
  const sid = resolveHookSession(body); // registers the slot if new
  log("info", `Hook: SessionStart${sid ? ` session=${sid}` : ""}`);
  return jsonResponse(res, 200, { ok: true });
}

// PreToolUse — the broad, all-modes approval path. When supervise mode is OFF
// we auto-allow instantly (no blocking). When ON, we surface the tool call to
// the phone and block for an allow/deny, returning a PreToolUse permission
// decision (works even in auto/bypassPermissions where PermissionRequest never
// fires). The hook matcher (settings.json) limits this to mutating tools.
async function handleHookPreToolUse(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }

  const allowOutput = { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow" } };
  if (!superviseMode) return jsonResponse(res, 200, allowOutput); // never block when off

  req.socket.setTimeout(0); // long-lived blocking request (up to PERMISSION_TIMEOUT_MS)
  const sid = resolveHookSession(body);
  const permissionId = crypto.randomUUID();
  log("info", `Hook: PreToolUse (supervise) ${permissionId}${sid ? ` session=${sid}` : ""}`, body.tool_name || "");

  pendingPermissionPayloads.set(permissionId, { permissionId, ...body, sessionId: sid });
  pushSseEvent("permission-request", { permissionId, ...body }, sid);

  const decision = await waitForPermission(permissionId);
  const allow = decision.behavior === "allow";
  log("info", `Hook: PreToolUse ${permissionId} -> ${allow ? "allow" : "deny"}`);
  return jsonResponse(res, 200, {
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: allow ? "allow" : "deny",
      ...(decision.message ? { permissionDecisionReason: decision.message } : {}),
    },
  });
}

// Toggle supervise mode from the phone.
async function handleSupervise(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });
  let body;
  try {
    body = await readBody(req);
  } catch {
    return jsonResponse(res, 400, { error: "Invalid JSON" });
  }
  superviseMode = !!body.on;
  log("info", `Supervise mode -> ${superviseMode ? "ON" : "OFF"}`);
  return jsonResponse(res, 200, { supervise: superviseMode });
}

// Public liveness probe — NO auth, NO sensitive data (no session list/cwd).
function handleHealth(_req, res) {
  return jsonResponse(res, 200, {
    ok: true,
    state: bridgeState,
    bridgeId: BRIDGE_ID,
    cmuxAvailable: cmux.cmuxAvailable(),
  });
}

function handleStatus(req, res) {
  // /status exposes session cwds + counts — require auth (was public).
  if (!requireAuth(req)) {
    return jsonResponse(res, 401, { error: "Unauthorized" });
  }
  const mostRecentRunningSession = findMostRecentRunningSession();
  return jsonResponse(res, 200, {
    bridgeId: BRIDGE_ID,
    sessionId: BRIDGE_ID, // backward compat
    state: bridgeState,
    machineName: os.hostname(),
    availableAgents: availableAgentsList(),
    sessions: getSessionsSnapshot(),
    sseClients: sseClients.size,
    pendingPermissions: pendingPermissions.size + codexSyntheticPermissions.size,
    eventBufferSize: sseBuffer.length,
    cmuxAvailable: cmux.cmuxAvailable(),
    supervise: superviseMode,
    pairedDevices: deviceStore.count(),
    // Backward compat: expose the most recent active session's info
    hasPty: findMostRecentActiveSession() !== null,
    activeAgent: mostRecentRunningSession?.agent || null,
  });
}

// GET /devices — list paired devices (no token values). Auth required.
function handleDevices(req, res) {
  if (req.method !== "GET") return jsonResponse(res, 405, { error: "Method not allowed" });
  if (!requireAuth(req)) return jsonResponse(res, 401, { error: "Unauthorized" });
  return jsonResponse(res, 200, { devices: deviceStore.list() });
}

// POST /devices/revoke {deviceId} — revoke one device's token. Auth required.
async function handleDevicesRevoke(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  if (!requireAuth(req)) return jsonResponse(res, 401, { error: "Unauthorized" });
  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "Invalid JSON" }); }
  const id = body && typeof body.deviceId === "string" ? body.deviceId : null;
  if (!id) return jsonResponse(res, 400, { error: "Missing 'deviceId'" });
  const removed = deviceStore.revoke(id);
  if (removed) log("info", `Device revoked: ${id.slice(0, 8)} — ${deviceStore.count()} device(s) remain`);
  return jsonResponse(res, removed ? 200 : 404, removed ? { ok: true } : { error: "No device with that id" });
}

// GET /pair-code — the current pairing code. Served ONLY on the loopback,
// secret-gated control listener (the hook port), NEVER on the phone-facing API.
// This way a DNS-rebinding page (which can pass an allowed Host but has no hook
// secret) can't read it, and the local CLI reaches it on 127.0.0.1 regardless of
// the API's bindAddress (e.g. when bound to a Tailscale IP). Defense-in-depth:
// the loopback remoteAddress check below stays even though the listener is local.
function handlePairCode(req, res) {
  const remote = req.socket.remoteAddress || "";
  const isLoopback = remote === "127.0.0.1" || remote === "::1" || remote === "::ffff:127.0.0.1";
  if (!isLoopback) return jsonResponse(res, 403, { error: "Loopback only" });
  return jsonResponse(res, 200, {
    code: pairingCode,
    fixed: !!FIXED_PAIRING_CODE,
    expiresAt: pairingCodeExpiresAt === Number.MAX_SAFE_INTEGER ? null : pairingCodeExpiresAt,
  });
}

function handleWebClient(_req, res) {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache" });
  res.end(WEB_CLIENT_HTML);
}

// Accept the token via Authorization header OR ?token= query.
function authOk(req, url) {
  if (requireAuth(req)) return true;
  const q = url.searchParams.get("token");
  if (deviceStore.isValid(q)) { deviceStore.touch(q); return true; }
  return false;
}

// GET /cmux/tree — live cmux workspaces -> terminals for the mobile mirror.
async function handleCmuxTree(req, res) {
  if (req.method !== "GET") return jsonResponse(res, 405, { error: "Method not allowed" });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });
  if (!cmux.cmuxAvailable()) return jsonResponse(res, 200, { available: false, workspaces: [] });

  const data = await cmux.mobileWorkspaces();
  // RPC failed (socket/cmux down) — report unavailable so the app falls back to
  // the hook-based view instead of showing an empty cmux screen.
  if (!data || !Array.isArray(data.workspaces)) {
    return jsonResponse(res, 200, { available: false, workspaces: [] });
  }
  const workspaces = (data.workspaces || [])
    .filter((w) => w.title !== "Agent Bridge") // hide the bridge's own workspace
    .map((w) => ({
    id: w.id,
    title: w.title,
    cwd: w.current_directory,
    selected: !!w.is_selected,
    hasUnread: !!w.has_unread,
    preview: w.preview || null,
    terminals: (w.terminals || []).map((t) => ({
      id: t.id,
      title: t.title,
      cwd: t.current_directory,
      focused: !!t.is_focused,
      ready: !!t.is_ready,
    })),
  }));
  return jsonResponse(res, 200, { available: true, workspaces });
}

// GET /cmux/screen?id=<terminalId> — plain-text screen of one cmux terminal.
async function handleCmuxScreen(req, res) {
  if (req.method !== "GET") return jsonResponse(res, 405, { error: "Method not allowed" });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });
  const id = url.searchParams.get("id");
  if (!id) return jsonResponse(res, 400, { error: "Missing id" });
  const text = await cmux.readTerminalText(id);
  // Include the screen hash so the phone can echo it back as expectedScreenHash
  // when answering an approval (the bridge rejects if the screen changed since).
  // hash MUST stay derived from the plain text — it must equal cmux.screenHash(id)
  // for the approval echo-back verification to work; do not fold `styled` into it.
  const hash = text == null ? null : crypto.createHash("sha256").update(text).digest("hex").slice(0, 16);
  // styled: real per-run colors + CJK-aligned columns for the live terminal view.
  // Optional/additive — older app builds just read `text`.
  const styled = await cmux.readTerminalStyled(id);
  return jsonResponse(res, 200, { id, text: text || "", hash, styled });
}

// GET /cmux/file?id=<terminalId>&path=<rel-or-abs path> — read a file/dir for the
// phone. Relative paths resolve against the terminal's cwd; absolute paths are
// honored. Access is allowed ANYWHERE the Mac user can read EXCEPT a denylist of
// sensitive locations (SSH/cloud creds, keychains, the bridge's own tokens, etc).
// Text only, size-capped.
const CMUX_FILE_MAX = 512 * 1024; // 512 KB
const CMUX_IMAGE_MAX = 8 * 1024 * 1024; // 8 MB (base64'd inline for preview)
const CMUX_IMAGE_EXT = {
  ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp",
  ".heic": "image/heic", ".heif": "image/heif",
  ".tiff": "image/tiff", ".tif": "image/tiff", ".ico": "image/x-icon",
};
// Videos are too big to inline — streamed via /cmux/media (Range-capable).
const CMUX_VIDEO_EXT = {
  ".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime",
  ".webm": "video/webm", ".m3u8": "application/vnd.apple.mpegurl",
};
// /cmux/media also serves these so the phone can load FULL files (a WKWebView
// can't render HTML truncated at the 512KB /cmux/file cap — it goes blank).
const CMUX_MEDIA_MIME = {
  ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8",
  ".md": "text/markdown; charset=utf-8", ".markdown": "text/markdown; charset=utf-8",
  ".txt": "text/plain; charset=utf-8", ".json": "application/json; charset=utf-8",
  ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".csv": "text/csv; charset=utf-8", ".xml": "text/xml; charset=utf-8",
  ".svg": "image/svg+xml", ".pdf": "application/pdf",
};

// Sensitive directories/files the phone must never read, even though the Mac user
// can. Matched against BOTH the resolved path and its realpath (defeats symlinks).
const CMUX_DENY_DIRS = (() => {
  const home = os.homedir();
  return [
    path.join(home, ".ssh"),
    path.join(home, ".aws"),
    path.join(home, ".gnupg"),
    path.join(home, ".kube"),
    path.join(home, ".docker"),
    path.join(home, ".config", "gh"),
    path.join(home, ".config", "gcloud"),
    path.join(home, "Library", "Keychains"),
    // the bridge's own credentials/tokens — reading these would leak pairing tokens
    path.join(home, "Library", "Application Support", "cmux-iphone"),
    "/Library/Keychains",
    "/private/etc/ssh",
    "/etc/ssh",
  ];
})();
// Secret-ish filenames blocked wherever they live (private keys, credential files).
const CMUX_DENY_NAMES = new Set([
  "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa", ".netrc",
]);

function cmuxPathDenied(p) {
  if (CMUX_DENY_NAMES.has(path.basename(p))) return true;
  for (const d of CMUX_DENY_DIRS) {
    if (p === d || p.startsWith(d + path.sep)) return true;
  }
  return false;
}

async function handleCmuxFile(req, res) {
  if (req.method !== "GET") return jsonResponse(res, 405, { error: "Method not allowed" });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });
  const id = url.searchParams.get("id");
  const rel = url.searchParams.get("path");
  if (!id || !rel) return jsonResponse(res, 400, { error: "Missing id or path" });

  const cwd = await cmux.terminalCwd(id);
  if (!cwd) return jsonResponse(res, 404, { error: "terminal-cwd-unavailable" });

  // Resolve relative paths against cwd; honor absolute paths. realpath defeats
  // symlinks. The denylist is checked against both the resolved path and its
  // realpath so neither a direct path nor a symlink can reach a secret.
  let target, rp;
  try {
    const base = path.resolve(cwd);
    target = path.isAbsolute(rel) ? path.resolve(rel) : path.resolve(base, rel);
    rp = await fs.promises.realpath(target);
  } catch {
    return jsonResponse(res, 404, { error: "not-found" });
  }
  if (cmuxPathDenied(target) || cmuxPathDenied(rp)) {
    return jsonResponse(res, 403, { error: "denied" });
  }

  let st;
  try { st = await fs.promises.stat(rp); } catch { return jsonResponse(res, 404, { error: "not-found" }); }

  // Directory → return a (capped) listing so the phone can browse into it.
  if (st.isDirectory()) {
    let dirents;
    try { dirents = await fs.promises.readdir(rp, { withFileTypes: true }); }
    catch { return jsonResponse(res, 500, { error: "read-failed" }); }
    const CAP = 2000;
    const truncated = dirents.length > CAP;
    const entries = dirents.slice(0, CAP).map((d) => {
      const full = path.join(rp, d.name);
      let isDir = d.isDirectory();
      if (d.isSymbolicLink()) {
        try { isDir = fs.statSync(full).isDirectory(); } catch { isDir = false; }
      }
      return { name: d.name, dir: isDir, path: full };
    })
      .filter((e) => !cmuxPathDenied(e.path)) // hide secrets from listings
      .sort((a, b) => (a.dir === b.dir ? a.name.localeCompare(b.name) : (a.dir ? -1 : 1)));
    return jsonResponse(res, 200, {
      type: "dir",
      name: path.basename(rp) || rp,
      path: rp,
      entries,
      truncated,
    });
  }
  if (!st.isFile()) return jsonResponse(res, 415, { error: "not-a-file" });

  // Videos → metadata only; the phone streams the bytes from /cmux/media.
  const vidMime = CMUX_VIDEO_EXT[path.extname(rp).toLowerCase()];
  if (vidMime) {
    return jsonResponse(res, 200, {
      type: "video", name: path.basename(rp), path: rp, mime: vidMime, size: st.size,
    });
  }

  // Images → return base64 so the phone can render a preview (instead of the
  // "binary file" rejection). Capped; oversized images report tooLarge.
  const imgMime = CMUX_IMAGE_EXT[path.extname(rp).toLowerCase()];
  if (imgMime) {
    if (st.size > CMUX_IMAGE_MAX) {
      return jsonResponse(res, 200, {
        type: "image", name: path.basename(rp), path: rp, mime: imgMime,
        size: st.size, tooLarge: true,
      });
    }
    let imgBuf;
    try { imgBuf = await fs.promises.readFile(rp); }
    catch { return jsonResponse(res, 500, { error: "read-failed" }); }
    return jsonResponse(res, 200, {
      type: "image", name: path.basename(rp), path: rp, mime: imgMime,
      size: st.size, data: imgBuf.toString("base64"),
    });
  }

  let fh;
  try {
    fh = await fs.promises.open(rp, "r");
    const len = Math.min(st.size, CMUX_FILE_MAX);
    const buf = Buffer.alloc(len);
    await fh.read(buf, 0, len, 0);
    // crude binary sniff — a NUL byte in the first chunk means "not text".
    if (buf.includes(0)) return jsonResponse(res, 415, { error: "binary-file" });
    return jsonResponse(res, 200, {
      type: "file",
      name: path.basename(rp),
      path: rp,
      content: buf.toString("utf8"),
      size: st.size,
      truncated: st.size > CMUX_FILE_MAX,
    });
  } catch {
    return jsonResponse(res, 500, { error: "read-failed" });
  } finally {
    if (fh) await fh.close().catch(() => {});
  }
}

// POST /cmux/upload?id=<terminalId>&ext=<png|jpg|…> — save an image sent from the
// phone (photo/screenshot) into the terminal's cwd under .cmux-uploads/, so the
// agent running there can read it. Raw image bytes in the body. Returns the
// saved path (absolute + cwd-relative). Writes only inside cwd, generated name.
const CMUX_UPLOAD_MAX = 16 * 1024 * 1024; // 16 MB
const CMUX_UPLOAD_EXT = new Set(["png", "jpg", "jpeg", "gif", "webp", "heic"]);
async function handleCmuxUpload(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });
  const id = url.searchParams.get("id");
  if (!id) return jsonResponse(res, 400, { error: "Missing id" });
  let ext = (url.searchParams.get("ext") || "jpg").toLowerCase().replace(/[^a-z0-9]/g, "");
  if (!CMUX_UPLOAD_EXT.has(ext)) ext = "jpg";

  const cwd = await cmux.terminalCwd(id);
  if (!cwd) return jsonResponse(res, 404, { error: "terminal-cwd-unavailable" });

  let bytes;
  try { bytes = await readRawBody(req, CMUX_UPLOAD_MAX); }
  catch { return jsonResponse(res, 413, { error: "too-large" }); }
  if (!bytes || !bytes.length) return jsonResponse(res, 400, { error: "empty" });

  try {
    const base = path.resolve(cwd);
    const dir = path.join(base, ".cmux-uploads");
    await fs.promises.mkdir(dir, { recursive: true });
    const rand = crypto.randomBytes(3).toString("hex");
    const name = `iphone-${Date.now()}-${rand}.${ext}`;
    const full = path.join(dir, name);
    await fs.promises.writeFile(full, bytes);
    return jsonResponse(res, 200, { path: full, relPath: path.join(".cmux-uploads", name), name });
  } catch {
    return jsonResponse(res, 500, { error: "write-failed" });
  }
}

// GET /cmux/media?id=<terminalId>&path=<path>[&token=…] — stream a media file
// (video) with HTTP Range support so the phone's player can seek. Same cwd
// scoping + denylist as /cmux/file. Auth accepts a query token (AVPlayer can't
// set headers). Raw bytes, not JSON.
async function handleCmuxMedia(req, res) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return jsonResponse(res, 405, { error: "Method not allowed" });
  }
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });
  const id = url.searchParams.get("id");
  const rel = url.searchParams.get("path");
  if (!id || !rel) return jsonResponse(res, 400, { error: "Missing id or path" });

  const cwd = await cmux.terminalCwd(id);
  if (!cwd) return jsonResponse(res, 404, { error: "terminal-cwd-unavailable" });

  let target, rp;
  try {
    const base = path.resolve(cwd);
    target = path.isAbsolute(rel) ? path.resolve(rel) : path.resolve(base, rel);
    rp = await fs.promises.realpath(target);
  } catch {
    return jsonResponse(res, 404, { error: "not-found" });
  }
  if (cmuxPathDenied(target) || cmuxPathDenied(rp)) {
    return jsonResponse(res, 403, { error: "denied" });
  }
  let st;
  try { st = await fs.promises.stat(rp); } catch { return jsonResponse(res, 404, { error: "not-found" }); }
  if (!st.isFile()) return jsonResponse(res, 415, { error: "not-a-file" });

  const ext = path.extname(rp).toLowerCase();
  const mime = CMUX_VIDEO_EXT[ext] || CMUX_MEDIA_MIME[ext] || CMUX_IMAGE_EXT[ext]
    || "application/octet-stream";
  const total = st.size;
  const range = req.headers.range;
  const baseHeaders = { "Content-Type": mime, "Accept-Ranges": "bytes" };

  if (range) {
    const m = /bytes=(\d*)-(\d*)/.exec(range);
    let start = m && m[1] ? parseInt(m[1], 10) : 0;
    let end = m && m[2] ? parseInt(m[2], 10) : total - 1;
    if (Number.isNaN(start) || Number.isNaN(end) || start > end || start >= total) {
      res.writeHead(416, { "Content-Range": `bytes */${total}` });
      return res.end();
    }
    end = Math.min(end, total - 1);
    res.writeHead(206, {
      ...baseHeaders,
      "Content-Range": `bytes ${start}-${end}/${total}`,
      "Content-Length": end - start + 1,
    });
    if (req.method === "HEAD") return res.end();
    fs.createReadStream(rp, { start, end }).on("error", () => res.destroy()).pipe(res);
    return;
  }

  res.writeHead(200, { ...baseHeaders, "Content-Length": total });
  if (req.method === "HEAD") return res.end();
  fs.createReadStream(rp).on("error", () => res.destroy()).pipe(res);
}

// POST /cmux/new-session — start a new agent session from the phone. Body:
// { cwd?, agent: "claude"|"codex", name? }. Creates a cmux workspace running the
// agent; it then appears in the mirror. cwd (if given) must be an existing dir.
async function handleCmuxNewSession(req, res) {
  if (req.method !== "POST") return jsonResponse(res, 405, { error: "Method not allowed" });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });
  let body;
  try { body = await readBody(req); } catch { return jsonResponse(res, 400, { error: "bad-body" }); }
  const agent = body.agent === "codex" ? "codex" : "claude";
  const cwd = typeof body.cwd === "string" && body.cwd.trim() ? body.cwd.trim() : null;
  const name = typeof body.name === "string" && body.name.trim() ? body.name.trim() : null;
  if (cwd) {
    try {
      const st = await fs.promises.stat(cwd);
      if (!st.isDirectory()) return jsonResponse(res, 400, { error: "cwd-not-a-directory" });
    } catch { return jsonResponse(res, 400, { error: "cwd-not-found" }); }
  }
  try {
    await cmux.newSession({ cwd, agent, name });
    return jsonResponse(res, 200, { ok: true });
  } catch (e) {
    return jsonResponse(res, 500, { error: "create-failed" });
  }
}

// GET /cmux/mdview?id&path[&token] — serve a markdown file as a rendered HTML
// page (dark-themed, marked.js from CDN, <pre> fallback if the CDN is
// unreachable). Full file content — no 512KB /cmux/file truncation.
const CMUX_MD_MAX = 4 * 1024 * 1024; // 4 MB
function escapeHtml(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
async function handleCmuxMdview(req, res) {
  if (req.method !== "GET") return jsonResponse(res, 405, { error: "Method not allowed" });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });
  const id = url.searchParams.get("id");
  const rel = url.searchParams.get("path");
  if (!id || !rel) return jsonResponse(res, 400, { error: "Missing id or path" });

  const cwd = await cmux.terminalCwd(id);
  if (!cwd) return jsonResponse(res, 404, { error: "terminal-cwd-unavailable" });
  let target, rp;
  try {
    const base = path.resolve(cwd);
    target = path.isAbsolute(rel) ? path.resolve(rel) : path.resolve(base, rel);
    rp = await fs.promises.realpath(target);
  } catch {
    return jsonResponse(res, 404, { error: "not-found" });
  }
  if (cmuxPathDenied(target) || cmuxPathDenied(rp)) {
    return jsonResponse(res, 403, { error: "denied" });
  }
  let md;
  try {
    const st = await fs.promises.stat(rp);
    if (!st.isFile() || st.size > CMUX_MD_MAX) return jsonResponse(res, 415, { error: "too-large" });
    md = await fs.promises.readFile(rp, "utf8");
  } catch {
    return jsonResponse(res, 404, { error: "not-found" });
  }

  const page = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
body{font-family:-apple-system,system-ui,sans-serif;margin:16px;background:#0f0f10;color:#ececec;line-height:1.6;word-wrap:break-word}
pre{background:#1c1c1e;border-radius:8px;padding:12px;overflow-x:auto}
code{background:#1c1c1e;border-radius:4px;padding:2px 5px;font-family:ui-monospace,Menlo,monospace;font-size:.88em}
pre code{padding:0;background:none}
a{color:#5aa9ff} img{max-width:100%;border-radius:6px}
table{border-collapse:collapse;display:block;overflow-x:auto} td,th{border:1px solid #333;padding:5px 10px}
h1,h2{border-bottom:1px solid #2a2a2c;padding-bottom:5px}
blockquote{border-left:3px solid #444;margin-left:0;padding-left:12px;color:#b8b8b8}
hr{border:none;border-top:1px solid #2a2a2c}
</style></head><body>
<div id="c"><pre style="white-space:pre-wrap">${escapeHtml(md)}</pre></div>
<script>window.__md=${JSON.stringify(md).replace(/</g, "\\u003c")};<\/script>
<script src="https://cdn.jsdelivr.net/npm/marked@12/marked.min.js"
 onload="document.getElementById('c').innerHTML=marked.parse(window.__md)"><\/script>
</body></html>`;
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  return res.end(page);
}

// GET /cmux/statuses — per-terminal run state for the dashboard. The cmux tree
// only exposes is_ready (always true), so "running" is detected from the live
// VISIBLE screen: vanilla Claude/Codex show "esc to interrupt" while generating;
// the OMC statusline shows "| thinking". Reads are bounded-concurrent.
// Three states from the live screen:
//   running  — actively generating ("esc to interrupt" / "esc to cancel")
//   waiting  — an agent session (Claude/Codex UI present) sitting at its prompt,
//              i.e. waiting for the user's next input (NOT generating)
//   idle     — a plain shell / tmux / finished command (no agent UI)
function classifyTerminalState(text) {
  const t = (text || "").toLowerCase();
  if (t.includes("esc to interrupt") || t.includes("esc to cancel")) return "running";
  const agentUI = ["shift+tab to cycle", "bypass permissions", "? for shortcuts",
                   "for shortcuts", "← for agents", "⏎ send"]
    .some((m) => t.includes(m));
  if (agentUI) return "waiting";
  return "idle";
}

async function handleCmuxStatuses(req, res) {
  if (req.method !== "GET") return jsonResponse(res, 405, { error: "Method not allowed" });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });

  const tree = await cmux.mobileWorkspaces();
  const ids = [];
  for (const w of (tree?.workspaces || [])) {
    for (const t of (w.terminals || [])) ids.push(t.id);
  }
  const statuses = {};
  let idx = 0;
  const worker = async () => {
    while (idx < ids.length) {
      const id = ids[idx++];
      try { statuses[id] = classifyTerminalState(await cmux.readVisibleText(id)); }
      catch { statuses[id] = "idle"; }
    }
  };
  await Promise.all(Array.from({ length: Math.min(8, ids.length) }, worker));
  return jsonResponse(res, 200, { statuses });
}

// --- localhost dev-server proxy --------------------------------------------
// Agents print http://localhost:<port> URLs for dev servers that bind only to
// 127.0.0.1 and so are unreachable from the phone. On demand we stand up a raw
// TCP forwarder on BIND_ADDRESS (the Tailscale/LAN interface the phone reaches)
// that pipes to 127.0.0.1:<port>. Raw TCP = HTTP, assets, and websockets all
// pass through untouched, and the proxy root maps to the dev-server root so
// absolute asset paths work. One forwarder per target port (reused).
const tcpProxies = new Map(); // targetPort -> { server, proxyPort }
const MAX_PROXIES = 64;

// HTTP-level proxy (not raw TCP): it rewrites the Host header to
// "localhost:<targetPort>" so dev servers that validate Host (Vite/Next/
// webpack — they otherwise show "Blocked request"/a host-check page) accept it.
// Absolute-PATH assets (/assets/x.js) still work because the proxy root maps to
// the dev-server root. Websocket upgrades (HMR) are forwarded with Host rewritten.
function ensureTcpProxy(targetPort) {
  return new Promise((resolve, reject) => {
    const existing = tcpProxies.get(targetPort);
    if (existing) return resolve(existing.proxyPort);
    if (tcpProxies.size >= MAX_PROXIES) return reject(new Error("too-many-proxies"));
    const hostHeader = `localhost:${targetPort}`;

    const server = http.createServer((creq, cres) => {
      const preq = http.request(
        { host: "127.0.0.1", port: targetPort, method: creq.method, path: creq.url,
          headers: { ...creq.headers, host: hostHeader } },
        (pres) => { cres.writeHead(pres.statusCode || 502, pres.headers); pres.pipe(cres); }
      );
      preq.on("error", () => { try { cres.writeHead(502); cres.end("proxy error"); } catch {} });
      creq.pipe(preq);
    });

    // Websocket / HTTP upgrade — replay the request line + headers (Host
    // rewritten) to the upstream, then pipe both ways.
    server.on("upgrade", (creq, csocket, head) => {
      const upstream = net.connect(targetPort, "127.0.0.1", () => {
        const headers = { ...creq.headers, host: hostHeader };
        let raw = `${creq.method} ${creq.url} HTTP/1.1\r\n`;
        for (const [k, v] of Object.entries(headers)) {
          for (const val of (Array.isArray(v) ? v : [v])) raw += `${k}: ${val}\r\n`;
        }
        raw += "\r\n";
        upstream.write(raw);
        if (head && head.length) upstream.write(head);
        upstream.pipe(csocket);
        csocket.pipe(upstream);
      });
      upstream.on("error", () => csocket.destroy());
      csocket.on("error", () => upstream.destroy());
    });

    server.on("error", reject);
    // Bind to the same interface as the API so the phone reaches it the same way.
    server.listen(0, BIND_ADDRESS, () => {
      const proxyPort = server.address().port;
      tcpProxies.set(targetPort, { server, proxyPort });
      log("info", `proxy: ${BIND_ADDRESS}:${proxyPort} -> 127.0.0.1:${targetPort} (Host: ${hostHeader})`);
      resolve(proxyPort);
    });
  });
}

// GET /proxy/open?port=3000 — ensure a forwarder exists for a localhost port,
// returning the proxy port the phone should connect to (on the bridge host).
async function handleProxyOpen(req, res) {
  if (req.method !== "GET") return jsonResponse(res, 405, { error: "Method not allowed" });
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (!authOk(req, url)) return jsonResponse(res, 401, { error: "Unauthorized" });
  const port = parseInt(url.searchParams.get("port"), 10);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return jsonResponse(res, 400, { error: "invalid-port" });
  }
  try {
    const proxyPort = await ensureTcpProxy(port);
    return jsonResponse(res, 200, { targetPort: port, proxyPort });
  } catch {
    return jsonResponse(res, 500, { error: "proxy-failed" });
  }
}

// --- cmux events -> SSE (live mirror updates) ------------------------------
let cmuxEventChild = null;
let cmuxRespawnTimer = null;
let cmuxDirtyTimer = null;

// Coalesce bursts of cmux events into one "refetch" signal (~400ms).
function signalCmuxDirty() {
  if (cmuxDirtyTimer) return;
  cmuxDirtyTimer = setTimeout(() => {
    cmuxDirtyTimer = null;
    pushSseEvent("cmux-event", { dirty: true });
  }, 400);
}

function startCmuxEventStream() {
  if (!cmux.cmuxAvailable()) return;
  try {
    cmuxEventChild = cmux.streamEvents(() => signalCmuxDirty());
  } catch {
    cmuxEventChild = null;
  }
  const scheduleRespawn = () => {
    cmuxEventChild = null;
    if (cmuxRespawnTimer) clearTimeout(cmuxRespawnTimer);
    // cmux may be unreachable (pre-restart / password not yet active) — retry.
    cmuxRespawnTimer = setTimeout(startCmuxEventStream, 5000);
  };
  if (cmuxEventChild) {
    cmuxEventChild.on("exit", scheduleRespawn);
    cmuxEventChild.on("error", scheduleRespawn);
  } else {
    scheduleRespawn();
  }
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

const routes = {
  "GET /": handleWebClient,
  "POST /pair": handlePair,
  "POST /command": handleCommand,
  "GET /events": handleEvents,
  "POST /hooks/tool-output": handleHookToolOutput,
  "POST /hooks/permission": handleHookPermission,
  "POST /hooks/stop": handleHookStop,
  "POST /hooks/task-complete": handleHookTaskComplete,
  "POST /hooks/error": handleHookError,
  "POST /hooks/session-end": handleHookSessionEnd,
  "POST /hooks/session-start": handleHookSessionStart,
  "POST /hooks/pre-tool-use": handleHookPreToolUse,
  "POST /supervise": handleSupervise,
  "GET /health": handleHealth,
  "GET /status": handleStatus,
  "GET /devices": handleDevices,
  "POST /devices/revoke": handleDevicesRevoke,
  "GET /pair-code": handlePairCode,
  "GET /cmux/tree": handleCmuxTree,
  "GET /cmux/screen": handleCmuxScreen,
  "GET /cmux/file": handleCmuxFile,
  "GET /cmux/media": handleCmuxMedia,
  "HEAD /cmux/media": handleCmuxMedia,
  "GET /cmux/mdview": handleCmuxMdview,
  "GET /cmux/statuses": handleCmuxStatuses,
  "POST /cmux/new-session": handleCmuxNewSession,
  "GET /proxy/open": handleProxyOpen,
  "POST /cmux/upload": handleCmuxUpload,
};

function isLocalRequest(req) {
  const addr = req.socket?.remoteAddress || "";
  return addr === "127.0.0.1" || addr === "::1" || addr === "::ffff:127.0.0.1";
}

// --- DNS-rebinding defense -------------------------------------------------
// A browser-driven DNS-rebinding attack reaches the bridge over a socket to a
// local IP, yet the Host header still carries the ATTACKER'S domain (the browser
// preserves the original hostname). Legitimate clients reach the bridge by IP
// literal (Bonjour / manual entry), by "localhost", or by an mDNS / Tailscale
// name (*.local / *.ts.net). So accept only those and reject any other host —
// blocking foreign domains before they can read /pair-code or drive /command.
function hostnameFromHeader(hostHeader) {
  if (typeof hostHeader !== "string") return null;
  let h = hostHeader.trim();
  if (!h) return null;
  if (h.startsWith("[")) {                 // [::1]:7860 -> ::1  (bracketed IPv6)
    const end = h.indexOf("]");
    return end === -1 ? null : h.slice(1, end);
  }
  // Strip a trailing :port only when there's a single colon (a bare IPv6 literal
  // like "::1" has several and must be left intact for net.isIP).
  if (h.indexOf(":") !== -1 && h.indexOf(":") === h.lastIndexOf(":")) {
    h = h.slice(0, h.indexOf(":"));
  }
  return h || null;
}

function isHostAllowed(req) {
  const name = hostnameFromHeader(req.headers.host);
  if (!name) return false;                 // missing / malformed Host
  if (net.isIP(name)) return true;         // reached us by IP literal
  const lower = name.toLowerCase();
  return lower === "localhost" || lower.endsWith(".local") || lower.endsWith(".ts.net");
}

async function dispatch(req, res, routeKey) {
  const handler = routes[routeKey];
  if (!handler) return jsonResponse(res, 404, { error: "Not found" });
  try {
    await handler(req, res);
  } catch (err) {
    log("error", `Unhandled error in ${routeKey}:`, err.message);
    if (!res.headersSent) {
      jsonResponse(res, 500, { error: "Internal server error" });
    }
  }
}

// Phone-facing listener (binds 127.0.0.1 by default; opt into LAN/Tailscale via
// bindAddress/HOST) — serves the app API only; never exposes hook endpoints.
async function onApiRequest(req, res) {
  // Reject a foreign Host header (DNS-rebinding defense) before doing anything.
  if (!isHostAllowed(req)) {
    return jsonResponse(res, 403, { error: "Forbidden" });
  }
  let url;
  try {
    // A malformed Host header makes new URL() throw; an uncaught throw here would
    // crash the whole bridge (unhandled rejection) — i.e. unauthenticated remote
    // DoS. Parse defensively and answer 400 instead.
    url = new URL(req.url, `http://${req.headers.host}`);
  } catch {
    return jsonResponse(res, 400, { error: "Bad request" });
  }
  // /hooks/* and /pair-code are served ONLY on the loopback control listener,
  // never on the phone-facing API (the latter would expose /pair-code to a
  // DNS-rebinding page that passes an allowed Host).
  if (url.pathname.startsWith("/hooks/") || url.pathname === "/pair-code") {
    return jsonResponse(res, 404, { error: "Not found" });
  }
  await dispatch(req, res, `${req.method} ${url.pathname}`);
}

// Loopback control listener (127.0.0.1:7861) — local Claude/Codex hooks AND
// local-only control routes (e.g. /pair-code), gated by a shared secret header
// so other local processes (and rebinding browsers) can't forge or read them.
async function onHookRequest(req, res) {
  let url;
  try {
    url = new URL(req.url, `http://${req.headers.host}`);
  } catch {
    return jsonResponse(res, 400, { error: "Bad request" });
  }
  if (!(url.pathname.startsWith("/hooks/") || url.pathname === "/pair-code")) {
    return jsonResponse(res, 404, { error: "Not found" });
  }
  if (!isLocalRequest(req)) {
    return jsonResponse(res, 403, { error: "Forbidden" });
  }
  if (hookSecret && req.headers["x-cmux-iphone-secret"] !== hookSecret) {
    return jsonResponse(res, 403, { error: "Forbidden" });
  }
  await dispatch(req, res, `${req.method} ${url.pathname}`);
}

// ---------------------------------------------------------------------------
// Server startup
// ---------------------------------------------------------------------------

function tryListen(server, port) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, BIND_ADDRESS, () => {
      server.removeListener("error", reject);
      resolve(port);
    });
  });
}

async function startServer() {
  const server = http.createServer(onApiRequest);

  let boundPort = null;
  // Honor an explicit PORT (env / installer arg); otherwise scan the range.
  const envPort = parseInt(process.env.PORT, 10);
  const candidatePorts = Number.isInteger(envPort) ? [envPort] : [];
  for (let p = PORT_RANGE_START; p <= PORT_RANGE_END; p++) {
    if (p !== envPort && p !== HOOK_PORT) candidatePorts.push(p); // never steal the hook port
  }
  for (const port of candidatePorts) {
    try {
      boundPort = await tryListen(server, port);
      break;
    } catch (err) {
      if (err.code === "EADDRINUSE") {
        log("warn", `Port ${port} in use, trying next...`);
        continue;
      }
      throw err;
    }
  }

  if (boundPort === null) {
    log("error", `No available port in range ${PORT_RANGE_START}-${PORT_RANGE_END}`);
    process.exit(1);
  }

  log("info", `Bridge server listening on ${BIND_ADDRESS}:${boundPort}`);
  if (BIND_ADDRESS === "0.0.0.0" || BIND_ADDRESS === "::") {
    log("warn", "bindAddress is 0.0.0.0 — the bridge is reachable over PLAINTEXT HTTP by anyone on this network. " +
      "Since 0.1.1 the secure default is loopback; this is likely a leftover config. " +
      "Prefer Tailscale (cmux-iphone setup --bind <tailscale-ip>) or set bindAddress to 127.0.0.1.");
  }

  // Record the ACTUALLY-bound port so the CLI (status/doctor/pair) probes the
  // right place even when the configured start port (7860) was busy and we
  // fell back to e.g. 7862.
  writeRuntime({
    apiPort: boundPort,
    hookPort: HOOK_PORT,
    bindAddress: BIND_ADDRESS,
    pid: process.pid,
    startedAt: new Date().toISOString(),
  });

  loadPersistedToken();
  loadOrCreateHookSecret();

  // Separate loopback-only listener for Claude/Codex hooks (secret-gated).
  const hookServer = http.createServer(onHookRequest);
  hookServer.on("error", (err) => log("error", `Hook listener error on :${HOOK_PORT}: ${err.message}`));
  hookServer.listen(HOOK_PORT, "127.0.0.1", () => {
    log("info", `Hook listener on 127.0.0.1:${HOOK_PORT} (secret-gated)`);
  });

  startCmuxEventStream();

  const code = generatePairingCode();

  // Bonjour
  bonjourInstance = new Bonjour();
  bonjourService = bonjourInstance.publish({
    name: `Cmux iPhone Bridge (${os.hostname()})`,
    type: "cmux-iphone",
    protocol: "tcp",
    port: boundPort,
    txt: {
      version: "2",
      bridgeId: BRIDGE_ID,
      sessionId: BRIDGE_ID, // backward compat
      machineName: os.hostname(),
    },
  });

  log("info", `Bonjour advertising _cmux-iphone._tcp on port ${boundPort}`);
  startCodexMonitor();

  const agents = [];
  if (CLAUDE_BIN) agents.push("Claude");
  if (CODEX_BIN) agents.push("Codex");
  log("info", `Bridge ready. Available agents: ${agents.join(", ") || "none"}. Sessions spawn on demand.`);

  // Get LAN IP
  const interfaces = os.networkInterfaces();
  let lanIP = "127.0.0.1";
  for (const [, addrs] of Object.entries(interfaces)) {
    for (const addr of addrs) {
      if (addr.family === "IPv4" && !addr.internal) {
        lanIP = addr.address;
        break;
      }
    }
    if (lanIP !== "127.0.0.1") break;
  }

  const agentLine = agents.length ? agents.join(" + ") : "none";
  // Only print the actual code to an interactive terminal. Under launchd this
  // stream is a plaintext log file, so there we show a retrieval hint instead of
  // persisting the code (read it via the loopback CLI: `cmux-iphone pair`).
  const codeLine = process.stdout.isTTY ? code : "run: cmux-iphone pair";
  console.log("");
  console.log("╔═══════════════════════════════════════╗");
  console.log("║        AGENT IPHONE BRIDGE             ║");
  console.log("╠═══════════════════════════════════════╣");
  console.log(`║  Pairing Code:  ${codeLine.padEnd(20)}║`);
  console.log(`║  IP Address:    ${lanIP.padEnd(20)}║`);
  console.log(`║  Port:          ${String(boundPort).padEnd(20)}║`);
  console.log(`║  Agents:        ${agentLine.padEnd(20)}║`);
  console.log("╚═══════════════════════════════════════╝");
  console.log("");

  // --- Graceful shutdown ---

  let shuttingDown = false;

  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    log("info", `Received ${signal}, shutting down gracefully...`);

    for (const client of sseClients) {
      try { client.end(); } catch { /* ignore */ }
    }
    sseClients.clear();

    // Kill all session PTYs
    for (const [id, slot] of sessions) {
      if (slot.ptyProcess) {
        try { slot.ptyProcess.kill(); } catch { /* ignore */ }
        log("info", `Killed session ${id} (${slot.agent})`);
      }
    }
    sessions.clear();
    stopCodexMonitor();

    if (bonjourService) {
      try { bonjourInstance.unpublishAll(); } catch { /* ignore */ }
    }
    if (bonjourInstance) {
      try { bonjourInstance.destroy(); } catch { /* ignore */ }
    }

    for (const [id, pending] of pendingPermissions) {
      clearTimeout(pending.timer);
      pending.resolve({ behavior: "deny", reason: "Server shutting down" });
    }
    pendingPermissions.clear();

    clearRuntime(); // remove the stale bound-port marker

    server.close(() => {
      log("info", "Server closed");
      process.exit(0);
    });

    setTimeout(() => {
      log("warn", "Forced exit after timeout");
      process.exit(1);
    }, 5000);
  }

  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));

  return { server, port: boundPort };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

// Last-resort safety net: a single malformed request must never take the bridge
// down. Log and keep serving instead of letting Node's default crash-on-throw
// turn any unhandled error into an unauthenticated remote DoS.
process.on("uncaughtException", (err) => {
  log("error", `Uncaught exception (continuing): ${err?.stack || err?.message || err}`);
});
process.on("unhandledRejection", (reason) => {
  log("error", `Unhandled rejection (continuing): ${reason?.stack || reason?.message || reason}`);
});

startServer().catch((err) => {
  log("error", "Failed to start server:", err.message);
  process.exit(1);
});
