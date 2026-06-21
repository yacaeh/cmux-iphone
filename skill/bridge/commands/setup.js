// agent-watch setup — idempotent bootstrap. Safe to re-run: it never rotates
// existing secrets, backs up Claude settings before merging hooks, and reports
// "already configured" for steps that are already done.

import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getConfig, saveConfig, paths } from "../lib/config.js";
import { which, lanIPv4, tailscaleIPv4 } from "../lib/sys.js";
import { api, bridgeUp } from "../lib/bridge-client.js";
import * as cmux from "../cmux.js";

const sh = (p) => fileURLToPath(new URL(p, import.meta.url));

export async function run() {
  const cfg = getConfig();
  const apiPort = String(process.env.PORT || cfg.ports.apiPort);

  // 1) Preflight
  if (process.platform !== "darwin") {
    console.error("agent-watch targets macOS.");
    return 1;
  }
  const major = parseInt(process.versions.node, 10);
  if (major < 18) {
    console.error(`Node 18+ required (have v${process.versions.node}).`);
    return 1;
  }
  console.log(`✓ macOS ${os.release()} · Node v${process.versions.node}`);

  // 2) Detect tooling + pick a runner
  const cmuxPresent = cmux.cmuxAvailable();
  const runner = cmuxPresent ? "cmux" : "launchd";
  console.log(cmuxPresent ? "✓ cmux detected — mirror ON (runner: in-cmux)" : "• cmux not found — hook/phone only (runner: LaunchAgent)");
  if (which("claude")) console.log("✓ Claude Code detected");
  if (which("codex")) console.log("✓ Codex detected");

  // 3) Persist config (merge, never clobber)
  saveConfig({ runner, cmux: { ...cfg.cmux, enabled: cmuxPresent } });
  console.log(`✓ config written → ${paths.configFile}`);

  // 4) Dependencies (reproducible)
  const dep = spawnSync("bash", [sh("../../setup.sh")], { stdio: "inherit" });
  if (dep.status !== 0) { console.error("Dependency install failed."); return 1; }

  // 5) Claude hooks (the script backs up settings.json + generates the secret)
  const hooks = spawnSync("bash", [sh("../../setup-hooks.sh"), apiPort], { stdio: "inherit" });
  if (hooks.status !== 0) { console.error("Hook install failed."); return 1; }

  // 6) Runner
  if (runner === "launchd") {
    const la = spawnSync("bash", [sh("../install-launchd.sh"), apiPort], { stdio: "inherit" });
    if (la.status !== 0) { console.error("LaunchAgent install failed."); return 1; }
  } else if (!(await bridgeUp())) {
    // cmux runner: the bridge must live inside a cmux workspace (only a cmux
    // descendant can drive the control socket). Auto-registering reliably needs
    // the cmux socket password + GUI session, so print the exact command.
    const cmd = sh("../run-in-cmux.sh");
    console.log("\nTo start the bridge inside cmux, run:");
    console.log(`  cmux new-workspace --name "Agent Bridge" --command "${cmd}"`);
    console.log("(It then survives restarts via cmux session-restore + a supervisor loop.)");
  } else {
    console.log("✓ bridge already running");
  }

  // 7) Health check
  let up = false;
  for (let i = 0; i < 10; i++) {
    if (await bridgeUp()) { up = true; break; }
    await new Promise((r) => setTimeout(r, 600));
  }
  console.log(up ? "✓ health check passed" : "• bridge not up yet (start it, then run 'agent-watch status')");

  // 8) Pair info
  console.log("\nPair your iPhone:");
  const lan = lanIPv4();
  const ts = tailscaleIPv4();
  if (lan) console.log(`  LAN:       http://${lan}:${apiPort}`);
  if (ts) console.log(`  Tailscale: http://${ts}:${apiPort}`);
  if (up) {
    const pc = await api("GET", "/pair-code");
    if (pc.ok && pc.json && pc.json.code) console.log(`  Code:      ${pc.json.code}`);
  }
  console.log("\nThen run 'agent-watch doctor' if anything looks off.");
  return 0;
}
