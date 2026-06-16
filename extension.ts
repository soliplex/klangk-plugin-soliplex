import { Type } from "@sinclair/typebox";

// Pi extension: exposes Soliplex room tools to the agent. Each tool delegates
// to the user's browser session (where the Flutter soliplex plugin holds the
// auth + talks to the Soliplex server) via the klangk browser-delegate bridge.
//
// We use the *streaming* bridge endpoint (/api/browser-delegate/stream): the
// browser pushes incremental chunks which we read as they arrive. That keeps
// the connection alive for long RAG + LLM answers, so the old fixed 30s
// round-trip timeout no longer applies — only the per-chunk idle timeout does.

const BRIDGE_URL = process.env.KLANGK_BRIDGE_URL;
const BRIDGE_TOKEN = process.env.KLANGK_BRIDGE_TOKEN;

interface BridgeResult {
  text: string;
  error?: string;
}

/// POST to the streaming bridge and consume the NDJSON relay:
///   {"type":"chunk","delta":"..."}*  then
///   {"type":"done","result":{"status":"ok","result":"<text>"}}
///   | {"type":"error","error":"..."}
async function streamBridge(
  action: string,
  params: Record<string, unknown>,
  onUpdate?: (update: unknown) => void,
): Promise<BridgeResult> {
  const resp = await fetch(`${BRIDGE_URL}/api/browser-delegate/stream`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action, token: BRIDGE_TOKEN, ...params }),
  });
  if (!resp.ok) {
    const t = await resp.text().catch(() => "");
    return { text: "", error: `Bridge error (${resp.status}): ${t}` };
  }
  if (!resp.body) {
    return { text: await resp.text() };
  }

  const reader = (resp.body as ReadableStream<Uint8Array>).getReader();
  const decoder = new TextDecoder();
  let buf = "";
  let acc = "";
  let finalText: string | null = null;
  let errText: string | undefined;

  const handleLine = (line: string) => {
    const s = line.trim();
    if (!s) return;
    let ev: any;
    try {
      ev = JSON.parse(s);
    } catch {
      return;
    }
    if (ev.type === "chunk") {
      acc += ev.delta ?? "";
      if (typeof onUpdate === "function") {
        try {
          onUpdate({ content: [{ type: "text", text: acc }] });
        } catch {
          /* ignore onUpdate contract mismatches across pi versions */
        }
      }
    } else if (ev.type === "done") {
      // result is the browser_response payload: {status:'ok', result:<text>}.
      const r = ev.result ?? {};
      if (r.error) errText = String(r.error);
      finalText = typeof r.result === "string" ? r.result : acc;
    } else if (ev.type === "error") {
      errText = String(ev.error ?? "bridge stream error");
    }
  };

  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let nl: number;
    while ((nl = buf.indexOf("\n")) >= 0) {
      handleLine(buf.slice(0, nl));
      buf = buf.slice(nl + 1);
    }
  }
  if (buf.trim()) handleLine(buf);

  if (errText) return { text: finalText ?? acc, error: errText };
  return { text: finalText ?? acc };
}

function textResult(text: string) {
  return { content: [{ type: "text", text }], details: {} };
}

// Collapse whitespace/newlines so a value renders on a single line.
function oneLine(s: unknown): string {
  return (typeof s === "string" ? s : s == null ? "" : String(s))
    .replace(/\s+/g, " ")
    .trim();
}

// A single-line tool-call component. We can't value-import pi's Text from a raw
// .ts extension (pi-tui is nested under pi's global install, unreachable by Node
// ESM resolution from the extension dir — pi's own shipped extensions only
// `import type` from the pi package). So implement pi-tui's public `Component`
// interface directly. CRITICAL: render() MUST truncate to the given width — pi
// crashes if a rendered line exceeds the terminal width.
function callLine(text: string): { render: (w: number) => string[]; invalidate: () => void } {
  return {
    render: (width: number) => {
      const w = typeof width === "number" && width > 4 ? width : 80;
      return [text.length <= w ? text : `${text.slice(0, w - 1)}…`];
    },
    invalidate: () => {},
  };
}

export default function (pi: any) {
  if (!BRIDGE_URL || !BRIDGE_TOKEN) return;

  pi.registerTool({
    name: "soliplex_list_rooms",
    description:
      "List the available Soliplex knowledge-base rooms (id, name, description) " +
      "for a server. The header also names other configured servers you can " +
      "target with the `server` argument on query/reply.",
    parameters: Type.Object({
      server: Type.Optional(
        Type.String({
          description:
            "Soliplex server name. Omit for the default server.",
        }),
      ),
    }),
    async execute(_id: string, params: { server?: string }) {
      try {
        const { text, error } = await streamBridge("soliplex_list_rooms", {
          server: params.server,
        });
        return textResult(error ? `Error: ${error}` : text);
      } catch (e: any) {
        return textResult(`soliplex_list_rooms failed: ${e?.message ?? e}`);
      }
    },
  });

  pi.registerTool({
    name: "soliplex_query",
    description:
      "Ask a question to a Soliplex room (RAG + LLM). Starts a NEW conversation " +
      "thread and returns the answer. The result ends with the server + thread_id " +
      "— pass BOTH to soliplex_reply to continue the same conversation " +
      "(multi-turn). Long-running answers stream and will not time out.",
    parameters: Type.Object({
      room_id: Type.String({
        description: "Room id (from soliplex_list_rooms).",
      }),
      question: Type.String({ description: "The question to ask." }),
      server: Type.Optional(
        Type.String({
          description:
            "Soliplex server name (from soliplex_list_rooms). Omit for the " +
            "default server.",
        }),
      ),
    }),
    renderCall(args: any) {
      const a = args ?? {};
      const srv = oneLine(a.server);
      return callLine(
        `soliplex_query(${srv ? `server: ${srv}, ` : ""}roomId: ${oneLine(a.room_id) || "?"}, message: ${oneLine(a.question)})`,
      );
    },
    async execute(
      _id: string,
      params: { room_id: string; question: string; server?: string },
      _signal: AbortSignal | undefined,
      onUpdate: any,
    ) {
      try {
        const { text, error } = await streamBridge(
          "soliplex_query",
          {
            room_id: params.room_id,
            question: params.question,
            server: params.server,
          },
          onUpdate,
        );
        return textResult(error ? `Error: ${error}` : text);
      } catch (e: any) {
        return textResult(`soliplex_query failed: ${e?.message ?? e}`);
      }
    },
  });

  pi.registerTool({
    name: "soliplex_reply",
    description:
      "Continue an existing Soliplex conversation thread (multi-turn). Use the " +
      "server + thread_id returned by a prior soliplex_query. The room keeps the " +
      "thread history, so earlier turns stay in context. Long answers stream.",
    parameters: Type.Object({
      room_id: Type.String({ description: "Room id of the thread." }),
      message: Type.String({ description: "The follow-up message." }),
      thread_id: Type.String({
        description: "thread_id from a prior soliplex_query result.",
      }),
      server: Type.Optional(
        Type.String({
          description:
            "Soliplex server name from the prior soliplex_query result. Must " +
            "match — omit only if that query used the default server.",
        }),
      ),
    }),
    renderCall(args: any) {
      const a = args ?? {};
      const srv = oneLine(a.server);
      return callLine(
        `soliplex_reply(${srv ? `server: ${srv}, ` : ""}roomId: ${oneLine(a.room_id) || "?"}, ` +
          `message: ${oneLine(a.message)}, threadId: ${oneLine(a.thread_id)})`,
      );
    },
    async execute(
      _id: string,
      params: {
        room_id: string;
        message: string;
        thread_id: string;
        server?: string;
      },
      _signal: AbortSignal | undefined,
      onUpdate: any,
    ) {
      try {
        const { text, error } = await streamBridge(
          "soliplex_reply",
          {
            room_id: params.room_id,
            message: params.message,
            thread_id: params.thread_id,
            server: params.server,
          },
          onUpdate,
        );
        return textResult(error ? `Error: ${error}` : text);
      } catch (e: any) {
        return textResult(`soliplex_reply failed: ${e?.message ?? e}`);
      }
    },
  });

  pi.registerTool({
    name: "soliplex_list_servers",
    description:
      "List the configured Soliplex servers (the names usable as the `server` " +
      "argument to soliplex_query/reply/list_rooms).",
    parameters: Type.Object({}),
    async execute() {
      try {
        const { text, error } = await streamBridge("soliplex_list_servers", {});
        return textResult(error ? `Error: ${error}` : text);
      } catch (e: any) {
        return textResult(`soliplex_list_servers failed: ${e?.message ?? e}`);
      }
    },
  });

  pi.registerTool({
    name: "soliplex_add_server",
    description:
      "Register an additional Soliplex server so it can be queried by name. " +
      "After adding, the user may need to authenticate to it via the " +
      "'Connect to Soliplex' overlay (each server has its own login); no-auth " +
      "servers work immediately. The name is then usable as the `server` arg.",
    parameters: Type.Object({
      name: Type.String({
        description: "Short name for the server (used as the `server` arg).",
      }),
      url: Type.String({
        description: "Base URL of the Soliplex server, e.g. https://rag.example.net",
      }),
    }),
    renderCall(args: any) {
      const a = args ?? {};
      return callLine(
        `soliplex_add_server(name: ${oneLine(a.name) || "?"}, url: ${oneLine(a.url) || "?"})`,
      );
    },
    async execute(_id: string, params: { name: string; url: string }) {
      try {
        const { text, error } = await streamBridge("soliplex_add_server", {
          name: params.name,
          url: params.url,
        });
        return textResult(error ? `Error: ${error}` : text);
      } catch (e: any) {
        return textResult(`soliplex_add_server failed: ${e?.message ?? e}`);
      }
    },
  });
}
