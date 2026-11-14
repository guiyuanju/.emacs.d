// Time the bridge spends in the dev Emacs: flushes while a reply streams, and dashboard serialization.
// node bridge-cost.mjs [projects] [agents per project]   Needs go and emacs.
import { setup, until } from "./e2e.mjs";

const [projects = 8, agents = 6] = process.argv.slice(2).map(Number);
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const env = await setup();
try {
  await env.startDaemon();
  await env.startEmacs();
  await until(async () => (await env.health()).emacs === "online", { what: "Emacs online" });
  const total = await env.el(`(e2e-populate ${projects} ${agents})`);
  await wait(1500);
  const timed = ["overlook-remote-bridge--flush", "overlook-remote-bridge--sections", "overlook-remote-bridge--conversation-json"];
  const show = async (title) => {
    console.log(`\n${title}`);
    for (const fn of timed) {
      const t = await env.el(`(e2e-timings '${fn})`);
      const ms = (v) => (v ?? 0).toFixed(2);
      console.log(`  ${fn}: n=${t.count} median=${ms(t.median)} p90=${ms(t.p90)} max=${ms(t.max)} total=${ms(t.total)} ms`);
    }
  };
  console.log(`${total} agents in ${projects + 1} projects; dashboard JSON ${await env.el("(length overlook-remote-bridge--sent-dashboard)")} bytes`);

  await env.el(`(e2e-time ${timed.map((f) => `'${f}`).join(" ")})`);
  const reply = "Streaming reply text, in small chunks as agents send it. ".repeat(100).slice(0, 5000);
  const chunks = await env.el(`(e2e-stream "alpha" ${JSON.stringify(reply)} 20 0.02)`);
  await wait(chunks * 20 + 1500);
  await show(`Streaming 5 KB in ${chunks} chunks of 20 characters, 20 ms apart`);

  await env.el(`(e2e-time ${timed.map((f) => `'${f}`).join(" ")})`);
  for (let i = 0; i < 20; i++) {
    await env.el(`(e2e-set "beta" :status '${i % 2 ? "idle" : "working"})`);
    await wait(150);
  }
  await wait(500);
  await show("20 dashboard changes (an agent's status), 150 ms apart");
} finally {
  await env.close();
}
