// Starts a real overlook-remoted and a dev Emacs (e2e-emacs.el) connected over its bridge, for tests and measurements.
import { execFileSync, spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const here = path.dirname(new URL(import.meta.url).pathname);
export const REMOTE = path.resolve(here, "..");
export const PACKAGE = path.resolve(REMOTE, "..");
export const EMACS = process.env.EMACS || "emacs";

export const freePort = () => new Promise((resolve) => {
  const server = net.createServer().listen(0, "127.0.0.1", () => { const { port } = server.address(); server.close(() => resolve(port)); });
});

// Why the end-to-end setup cannot run here, or null.
export function missing() {
  if (spawnSync("go", ["version"]).status !== 0) return "go not found";
  if (spawnSync(EMACS, ["--version"]).status !== 0) return `${EMACS} not found`;
  const load = spawnSync(EMACS, ["-Q", "--batch", "--eval", "(require 'overlook-remote-bridge)"], { env: { ...process.env, EMACSLOADPATH: loadPath() } });
  if (load.status !== 0) return "overlook's dependencies not found: set OVERLOOK_LOAD_PATH";
  return null;
}

// Load path for the dev Emacs: overlook, its dependencies from OVERLOOK_LOAD_PATH or the repository's elpaca builds, then the defaults.
export function loadPath() {
  let deps = (process.env.OVERLOOK_LOAD_PATH || "").split(":").filter(Boolean);
  const builds = path.resolve(PACKAGE, "../../elpaca/builds");
  if (!deps.length && fs.existsSync(builds)) deps = fs.readdirSync(builds).map((name) => path.join(builds, name));
  return [PACKAGE, ...deps].join(":") + ":";
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export async function until(predicate, { timeout = 10000, interval = 50, what = "condition" } = {}) {
  const deadline = Date.now() + timeout;
  for (;;) {
    try { const value = await predicate(); if (value) return value; } catch (_) { /* not yet */ }
    if (Date.now() > deadline) throw new Error("Timed out waiting for " + what);
    await wait(interval);
  }
}

// One Elisp form, sent as a JSON string, evaluated in the dev Emacs; resolves to its JSON value.
export function elisp(control, form) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(control);
    let data = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      data += chunk;
      const end = data.indexOf("\n");
      if (end < 0) return;
      socket.end();
      const answer = JSON.parse(data.slice(0, end));
      if ("error" in answer) reject(new Error(`${form}: ${answer.error}`)); else resolve(answer.ok);
    });
    socket.on("error", reject);
    socket.write(JSON.stringify(form) + "\n");
  });
}

// A temp directory with the daemon binary, a token, the bridge socket and the dev Emacs's control socket.
export async function setup({ token = "e2e-token" } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ovl-e2e-"));
  fs.chmodSync(dir, 0o700);
  const root = path.join(dir, "shop");
  fs.mkdirSync(root);
  const files = { binary: path.join(dir, "overlook-remoted"), tokenFile: path.join(dir, "token"), socket: path.join(dir, "bridge.sock"), control: path.join(dir, "control.sock") };
  fs.writeFileSync(files.tokenFile, token + "\n", { mode: 0o600 });
  const env = { dir, root, token, ...files, port: await freePort(), children: new Set() };
  env.base = `http://127.0.0.1:${env.port}`;
  execFileSync("go", ["build", "-o", files.binary, "./cmd/overlook-remoted"], { cwd: REMOTE, stdio: "inherit" });
  env.el = (form) => elisp(files.control, form);
  env.health = async () => (await fetch(env.base + "/overlook/healthz")).json();
  env.track = (child) => { env.children.add(child); child.on("exit", () => env.children.delete(child)); return child; };

  env.startDaemon = async (args = []) => {
    env.daemon = env.track(spawn(files.binary, ["-listen", `127.0.0.1:${env.port}`, "-token-file", files.tokenFile, "-socket", files.socket, "-cache-dir", path.join(dir, "cache"), ...args],
      { stdio: ["ignore", "ignore", process.env.OVERLOOK_E2E_VERBOSE ? "inherit" : "ignore"] }));
    await until(env.health, { what: "the daemon" });
  };
  env.stopDaemon = async () => {
    const daemon = env.daemon;
    if (!daemon || daemon.exitCode !== null) return;
    const exited = new Promise((resolve) => daemon.once("exit", resolve));
    daemon.kill("SIGTERM");
    await exited;
  };

  env.startEmacs = async () => {
    const vars = { ...process.env, EMACSLOADPATH: loadPath(), OVERLOOK_E2E_CONTROL: files.control, OVERLOOK_E2E_ROOT: root };
    vars.OVERLOOK_E2E_SOCKET = files.socket;
    let output = "";
    env.emacs = env.track(spawn(EMACS, ["-Q", "--batch", "-l", path.join(here, "e2e-emacs.el")], { env: vars, stdio: ["ignore", "pipe", "pipe"] }));
    env.emacs.stdout.on("data", (chunk) => { output += chunk; });
    env.emacs.stderr.on("data", (chunk) => { output += chunk; if (process.env.OVERLOOK_E2E_VERBOSE) process.stderr.write(chunk); });
    env.emacsOutput = () => output;
    await until(() => { if (env.emacs.exitCode !== null) throw new Error("dev Emacs exited:\n" + output); return output.includes("e2e-emacs ready"); },
      { timeout: 30000, what: "the dev Emacs" }).catch((error) => { throw new Error(error.message + "\n" + output); });
  };

  env.close = async () => {
    if (env.emacs?.exitCode === null) { try { await env.el("(setq e2e-done t)"); } catch (_) { /* gone */ } }
    for (const child of env.children) child.kill("SIGTERM");
    await Promise.all([...env.children].map((child) => new Promise((resolve) => {
      const timer = setTimeout(() => { child.kill("SIGKILL"); resolve(); }, 3000);
      child.once("exit", () => { clearTimeout(timer); resolve(); });
    })));
    fs.rmSync(dir, { recursive: true, force: true });
  };
  return env;
}
