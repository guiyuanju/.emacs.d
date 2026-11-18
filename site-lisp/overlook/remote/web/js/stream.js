// The page's one server-sent event stream, read with fetch so the token stays in a header.
import { BASE, ApiError, headers, checkProtocol } from "js/api.js";
import { SSEParser } from "js/sse.js";

const QUIET_MS = 60000;

export const backoff = (failures) => Math.min(30000, 1000 * 2 ** Math.min(failures, 5));

export class Stream {
  // onEvent(name, data) handles one event; onOpen() runs when events flow; onError(error) returns true to stop retrying.
  constructor({ onEvent, onOpen = () => {}, onError = () => false, hidden = () => document.hidden }) {
    Object.assign(this, { onEvent, onOpen, onError, hidden });
    this.query = null;
    this.generation = 0;
    this.controller = null;
    this.running = false;
    this.wake = null;
  }

  // Subscribes to query (the resume query string), replacing any previous subscription.
  open(query) {
    this.close();
    this.query = query;
    this.run(this.generation);
  }

  close() {
    this.generation++;
    this.query = null;
    this.stop();
  }

  stop() {
    this.controller?.abort();
    this.controller = null;
    this.wake?.();
  }

  // Drops the connection while the page is hidden; resume() reconnects with the latest cursors.
  pause() {
    this.generation++;
    this.stop();
  }

  resume() {
    if (this.query === null || (this.running && this.runner === this.generation)) return;
    this.generation++;
    this.run(this.generation);
  }

  // Reconnects now instead of waiting out the backoff.
  retry() {
    if (this.query === null) return;
    this.pause();
    this.resume();
  }

  async run(generation) {
    const current = () => this.generation === generation;
    this.running = true;
    this.runner = generation;
    let failures = 0;
    try {
      while (current() && !this.hidden()) {
        try {
          await this.listen(current, () => { failures = 0; });
        } catch (error) {
          if (!current()) return;
          if (this.onError(error)) return;
          await new Promise((resolve) => {
            const timer = setTimeout(resolve, backoff(failures++));
            this.wake = () => { clearTimeout(timer); resolve(); };
          });
          this.wake = null;
        }
      }
    } finally {
      if (this.runner === generation) this.running = false;
    }
  }

  async listen(current, healthy) {
    const controller = new AbortController();
    this.controller = controller;
    let timer;
    const quiet = () => { clearTimeout(timer); timer = setTimeout(() => controller.abort(), QUIET_MS); };
    quiet();
    try {
      const response = await fetch(BASE + "stream?" + this.query, {
        headers: headers({ "Accept": "text/event-stream" }), signal: controller.signal, cache: "no-store",
      });
      checkProtocol(response);
      if (!response.ok) {
        let problem = {};
        try { problem = await response.json(); } catch (_) { /* not JSON */ }
        throw new ApiError(problem.detail || response.statusText, { status: response.status, code: problem.code || "" });
      }
      if (!response.body || !response.headers.get("Content-Type")?.startsWith("text/event-stream")) {
        throw new ApiError("The server did not open a stream", { status: response.status, code: "no_stream" });
      }
      if (!current()) return;
      const parser = new SSEParser(({ event, data, id }) => {
        if (!current()) return;
        this.onEvent(event, JSON.parse(data));
        // Resume only past updates the consumer applied to this subscription.
        if (current() && id !== null && (event === "dashboard" || event === "conversation")) this.query = id;
      });
      const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
      let opened = false;
      for (;;) {
        const { value, done } = await reader.read();
        if (!current()) { reader.cancel().catch(() => {}); return; }
        if (done) throw new ApiError("The stream ended", { code: "stream_ended" });
        quiet();
        parser.push(value);
        if (!opened) { opened = true; healthy(); this.onOpen(); }
      }
    } catch (error) {
      if (error.name === "AbortError") {
        if (!current()) return;
        throw new ApiError("The connection went quiet", { code: "quiet" });
      }
      if (error instanceof TypeError) throw new ApiError("Network unavailable", { code: "network" });
      throw error;
    } finally {
      clearTimeout(timer);
      controller.abort();
      if (this.controller === controller) this.controller = null;
    }
  }
}
