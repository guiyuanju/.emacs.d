// Incremental text/event-stream parser (WHATWG rules: event, data, id; comments ignored).
export class SSEParser {
  constructor(onEvent) {
    this.onEvent = onEvent;
    this.buffer = "";
    this.reset();
  }

  reset() {
    this.event = "";
    this.data = [];
    this.id = null;
  }

  push(chunk) {
    this.buffer += chunk;
    let start = 0;
    for (;;) {
      const match = /\r\n|\r|\n/g;
      match.lastIndex = start;
      const found = match.exec(this.buffer);
      // A lone trailing "\r" may be the first half of "\r\n".
      if (!found || (found[0] === "\r" && found.index === this.buffer.length - 1)) break;
      this.line(this.buffer.slice(start, found.index));
      start = found.index + found[0].length;
    }
    this.buffer = this.buffer.slice(start);
  }

  line(line) {
    if (line === "") {
      if (this.data.length) this.onEvent({ event: this.event || "message", data: this.data.join("\n"), id: this.id });
      this.reset();
      return;
    }
    if (line.startsWith(":")) return;
    const colon = line.indexOf(":");
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? "" : line.slice(colon + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") this.event = value;
    else if (field === "data") this.data.push(value);
    else if (field === "id" && !value.includes("\0")) this.id = value;
  }
}
