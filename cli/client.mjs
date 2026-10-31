import { create, fromBinary, toBinary } from "@bufbuild/protobuf";

import { LogService } from "./proto/logs_pb.js";
import { REPLService } from "./proto/repl_pb.js";
import { SwipletService } from "./proto/swiplets_pb.js";
import { SystemService } from "./proto/system_pb.js";

const largestMessage = 128 << 20;
const contentType = "application/grpc-web+proto";
const webSocketSubprotocol = "grpc-websockets";

export const Code = {
  Canceled: 1,
  Unknown: 2,
  DeadlineExceeded: 4,
  NotFound: 5,
  Unimplemented: 12,
  Internal: 13,
  Unavailable: 14,
  Unauthenticated: 16,
};

export class UsageError extends Error {}

export class RpcError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const httpStatusCodes = { 400: Code.Internal, 401: Code.Unauthenticated, 403: Code.Unauthenticated, 404: Code.Unimplemented, 429: Code.Unavailable, 502: Code.Unavailable, 503: Code.Unavailable, 504: Code.Unavailable };

function statusMessage(text) {
  if (text === undefined || text === null) {
    return "";
  }
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

const transportError = error => {
  if (error instanceof RpcError) {
    return error;
  }
  if (error?.name === "AbortError") {
    return new RpcError(Code.Canceled, "the call was canceled");
  }
  const cause = error?.cause;
  return new RpcError(Code.Unavailable, cause?.message || cause?.code || error?.message || String(error));
};

function frame(schema, init) {
  const body = toBinary(schema, create(schema, init));
  const out = Buffer.allocUnsafe(5 + body.length);
  out[0] = 0;
  out.writeUInt32BE(body.length, 1);
  out.set(body, 5);
  return out;
}

function parseMetadata(body) {
  const headers = {};
  for (const line of Buffer.from(body).toString().split("\r\n")) {
    const separator = line.indexOf(":");
    if (separator > 0) {
      headers[line.slice(0, separator).trim().toLowerCase()] = line.slice(separator + 1).trim();
    }
  }
  return headers;
}

class FrameReader {
  pending = Buffer.alloc(0);

  constructor(schema) {
    this.schema = schema;
  }

  push(chunk) {
    this.pending = this.pending.length === 0 ? Buffer.from(chunk) : Buffer.concat([this.pending, Buffer.from(chunk)]);
    const frames = [];
    while (this.pending.length >= 5) {
      const length = this.pending.readUInt32BE(1);
      if (length > largestMessage) {
        throw new RpcError(Code.Internal, `the server sent a message of ${length} bytes`);
      }
      if (this.pending.length < 5 + length) {
        break;
      }
      const body = this.pending.subarray(5, 5 + length);
      frames.push((this.pending[0] & 0x80) !== 0 ? { trailers: parseMetadata(body) } : { message: fromBinary(this.schema, body) });
      this.pending = this.pending.subarray(5 + length);
    }
    return frames;
  }
}

function checkStatus(headers) {
  const status = headers["grpc-status"];
  if (status === undefined || status === null) {
    return false;
  }
  const code = Number(status);
  if (code !== 0) {
    throw new RpcError(code, statusMessage(headers["grpc-message"]));
  }
  return true;
}

function requestHeaders(connection, timeoutMs) {
  const headers = { "content-type": contentType, "x-grpc-web": "1" };
  if (connection.token !== "") {
    headers.authorization = `Bearer ${connection.token}`;
  }
  if (timeoutMs > 0) {
    headers["grpc-timeout"] = `${Math.ceil(timeoutMs)}m`;
  }
  return headers;
}

async function* invokeHTTP(connection, method, input, { signal, timeoutMs }) {
  let response;
  try {
    response = await fetch(`${connection.base}/${method.parent.typeName}/${method.name}`, {
      method: "POST",
      headers: requestHeaders(connection, timeoutMs),
      body: frame(method.input, input),
      signal,
    });
  } catch (error) {
    throw transportError(error);
  }
  const headers = Object.fromEntries(response.headers);
  if (response.status !== 200) {
    await response.body?.cancel();
    throw new RpcError(httpStatusCodes[response.status] ?? Code.Unknown, `HTTP ${response.status}`);
  }
  if (checkStatus(headers)) {
    await response.body?.cancel();
    return;
  }
  const reader = new FrameReader(method.output);
  let ended = false;
  try {
    for await (const chunk of response.body) {
      for (const found of reader.push(chunk)) {
        if (found.trailers) {
          checkStatus(found.trailers);
          ended = true;
        } else if (!ended) {
          yield found.message;
        }
      }
    }
  } catch (error) {
    throw transportError(error);
  }
  if (!ended) {
    throw new RpcError(Code.Unavailable, "the response ended without a status");
  }
}

async function* invokeWebSocket(connection, method, input, { signal, timeoutMs }) {
  const socket = new WebSocket(`${connection.webSocketBase}/${method.parent.typeName}/${method.name}`, [webSocketSubprotocol]);
  socket.binaryType = "arraybuffer";
  const reader = new FrameReader(method.output);
  const messages = [];
  let failure;
  let closed = false;
  let headersSeen = false;
  let wake = () => {};
  const notify = () => {
    const current = wake;
    wake = () => {};
    current();
  };
  const fail = error => {
    failure ??= error;
    socket.close();
    notify();
  };
  const abort = () => fail(new RpcError(Code.Canceled, "the call was canceled"));
  const opened = new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", () => reject(new RpcError(Code.Unavailable, `cannot connect to ${connection.webSocketBase}`)), { once: true });
  });
  socket.addEventListener("message", event => {
    try {
      for (const found of reader.push(new Uint8Array(event.data))) {
        if (found.message) {
          messages.push(found.message);
        } else if (headersSeen || "grpc-status" in found.trailers) {
          checkStatus(found.trailers);
          closed = true;
          socket.close();
        } else {
          headersSeen = true;
        }
      }
    } catch (error) {
      fail(error);
    }
    notify();
  });
  socket.addEventListener("close", event => {
    if (!closed) {
      failure ??= new RpcError(Code.Unavailable, event.reason || "the connection closed before the response");
    }
    closed = true;
    notify();
  });
  socket.addEventListener("error", () => {
    failure ??= new RpcError(Code.Unavailable, `cannot connect to ${connection.webSocketBase}`);
  });
  signal?.addEventListener("abort", abort, { once: true });
  try {
    await opened;
    const headers = requestHeaders(connection, timeoutMs);
    socket.send(Buffer.from(`${Object.entries(headers).map(([key, value]) => `${key}: ${value}\r\n`).join("")}`));
    const sender = (async () => {
      try {
        const body = method.methodKind === "client_streaming" ? input : [input];
        for await (const message of body) {
          if (closed) {
            return;
          }
          socket.send(Buffer.concat([Buffer.from([0]), frame(method.input, message)]));
        }
        if (!closed) {
          socket.send(Buffer.from([1]));
        }
      } catch (error) {
        fail(transportError(error));
      }
    })();
    while (true) {
      if (messages.length > 0) {
        yield messages.shift();
        continue;
      }
      if (closed) {
        break;
      }
      await new Promise(resolve => {
        wake = resolve;
      });
    }
    await sender;
    if (failure) {
      throw failure;
    }
  } finally {
    signal?.removeEventListener("abort", abort);
    if (socket.readyState !== WebSocket.CLOSED) {
      socket.close();
    }
  }
}

async function single(iterable) {
  let found;
  for await (const message of iterable) {
    found ??= message;
  }
  if (found === undefined) {
    throw new RpcError(Code.Internal, "the server sent no response");
  }
  return found;
}

function bind(service, connection) {
  const client = {};
  for (const method of service.methods) {
    const streamsInput = method.methodKind === "client_streaming" || method.methodKind === "bidi_streaming";
    client[method.localName] = (input, options = {}) => {
      const call = (streamsInput ? invokeWebSocket : invokeHTTP)(connection, method, input, { signal: options.signal, timeoutMs: options.timeoutMs ?? 0 });
      return method.methodKind === "unary" || method.methodKind === "client_streaming" ? single(call) : call;
    };
  }
  return client;
}

export function open({ host, token }) {
  host ||= process.env.SWIPT_HOST ?? "";
  token ||= process.env.SWIPT_TOKEN ?? "";
  if (host === "") {
    throw new UsageError('give --host or set SWIPT_HOST; "swipt devices" lists the hosts on the local network');
  }
  let parsed;
  try {
    parsed = new URL(host.includes("://") ? host : `http://${host}`);
  } catch {
    throw new UsageError(`--host is not a URL: ${host}`);
  }
  if (parsed.hostname === "" || (parsed.protocol !== "http:" && parsed.protocol !== "https:")) {
    throw new UsageError(`--host is an http or https URL: ${host}`);
  }
  const base = `${parsed.origin}${parsed.pathname.replace(/\/+$/, "")}`;
  const connection = { token, base, webSocketBase: base.replace(/^http/, "ws") };
  return {
    system: bind(SystemService, connection),
    logs: bind(LogService, connection),
    swiplets: bind(SwipletService, connection),
    repl: bind(REPLService, connection),
  };
}

export const unauthenticated = error => error instanceof RpcError && error.code === Code.Unauthenticated;
