// Finds Playwright and a Chromium for the page tests.
const fs = require('fs');
const path = require('path');
const os = require('os');

// Playwright as `require('playwright')` finds it (NODE_PATH included), else OVERLOOK_PLAYWRIGHT, else the global npm root's.
let found;
function playwright() {
  if (found !== undefined) return found;
  const candidates = ['playwright', process.env.OVERLOOK_PLAYWRIGHT];
  try {
    const root = require('child_process').execFileSync('npm', ['root', '-g'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    if (root) candidates.push(path.join(root, 'playwright'));
  } catch (_) { /* no npm */ }
  for (const name of candidates.filter(Boolean)) {
    try { return (found = require(name)); } catch (_) { /* next */ }
  }
  return (found = null);
}

// Why the browser tests cannot run, or null.
function unavailable() {
  return playwright() ? null : 'Playwright not found: install it (npm i -g playwright), or set NODE_PATH or OVERLOOK_PLAYWRIGHT';
}

// PLAYWRIGHT_CHROMIUM_EXECUTABLE, else Playwright's own, else the newest cached headless shell.
function executablePath(chromium) {
  if (process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE) return process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
  try { if (fs.existsSync(chromium.executablePath())) return undefined; } catch (_) { /* fall through */ }
  const cache = path.join(os.homedir(), 'Library/Caches/ms-playwright');
  const shells = fs.existsSync(cache) ? fs.readdirSync(cache).filter((name) => name.startsWith('chromium_headless_shell-')).sort().reverse() : [];
  for (const shell of shells) {
    for (const sub of ['chrome-headless-shell-mac-arm64/chrome-headless-shell', 'chrome-headless-shell-mac-x64/chrome-headless-shell', 'chrome-headless-shell-linux64/chrome-headless-shell']) {
      const file = path.join(cache, shell, sub);
      if (fs.existsSync(file)) return file;
    }
  }
  return undefined;
}

async function launch() {
  if (!playwright()) throw new Error(unavailable());
  const { chromium, devices } = playwright();
  const browser = await chromium.launch({ headless: true, executablePath: executablePath(chromium) });
  return { browser, devices };
}

module.exports = { playwright, unavailable, launch };
