// Strict enough to verify Fountain's wire, independent of its SDK followers.
// TCP chunks are not frames; decode UTF-8 and CR/LF boundaries incrementally.
export async function* parseSse(body, { maxBytes = 4 * 1024 * 1024 } = {}) {
  const reader = body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let buffer = '', bytes = 0, frame = [];
  function finish() {
    if (!frame.length) return null;
    const raw = frame.join('\n') + '\n\n';
    const result = { event: 'message', data: [], raw };
    for (const line of frame) {
      if (line.startsWith(':')) continue;
      const colon = line.indexOf(':');
      const field = colon < 0 ? line : line.slice(0, colon);
      let value = colon < 0 ? '' : line.slice(colon + 1);
      if (value.startsWith(' ')) value = value.slice(1);
      if (field === 'data') result.data.push(value);
      if (field === 'event') result.event = value;
      if (field === 'id' && !value.includes('\0')) result.id = value;
    }
    frame = [];
    return result.data.length ? { ...result, data: result.data.join('\n') } : null;
  }
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) buffer += decoder.decode();
      else {
        bytes += value.length;
        if (bytes > maxBytes) throw new Error('SSE response exceeds byte budget');
        buffer += decoder.decode(value, { stream: true });
      }
      while (true) {
        const index = buffer.search(/[\r\n]/);
        if (index < 0 || (!done && buffer[index] === '\r' && index === buffer.length - 1)) break;
        const line = buffer.slice(0, index);
        const width = buffer[index] === '\r' && buffer[index + 1] === '\n' ? 2 : 1;
        buffer = buffer.slice(index + width);
        if (line) frame.push(line);
        else { const ready = finish(); if (ready) yield ready; }
      }
      if (done) break;
    }
    // A trailing partial frame is a connection failure, not a successful turn.
    if (buffer.trim() || frame.some(line => !line.startsWith(':'))) throw new Error('SSE connection ended mid-frame');
  } finally { await reader.cancel().catch(() => {}); }
}

export async function* streamEvents(client, path, { signal = client.signal, after, maxBytes, trace = client.trace } = {}) {
  if (!/^\/api\/conversations\/[a-f0-9-]+\/stream(?:\?|$)/i.test(path)) throw new Error('Expected a conversation stream path');
  if (after !== undefined && (!Number.isSafeInteger(after) || after < 0)) throw new Error('Invalid SSE cursor');
  const headers = { accept: 'text/event-stream', authorization: `Bearer ${client.key}` };
  if (after !== undefined) headers['last-event-id'] = String(after);
  const stop = new AbortController();
  const combined = signal ? AbortSignal.any([signal, stop.signal]) : stop.signal;
  const started = performance.now();
  let response;
  try {
    response = await fetch(client.baseUrl + path, { headers, signal: combined, redirect: 'manual' });
    trace({ method: 'GET', path, after, status: response.status, request_id: response.headers.get('x-request-id'), transport: 'sse' });
    if (response.status !== 200 || !/^text\/event-stream(?:;|$)/i.test(response.headers.get('content-type') ?? '')) {
      throw new Error(`SSE expected 200 text/event-stream, received ${response.status}`);
    }
    for await (const frame of parseSse(response.body, { maxBytes })) {
      const receivedMs = performance.now();
      let event;
      try { event = JSON.parse(frame.data); } catch { throw new Error('SSE data is not JSON'); }
      client.redactor.value(event);
      trace({ transport: 'sse', path, after, received_ms: receivedMs - started, frame: client.redactor.text(frame.raw) });
      client.assertPublicSafe?.(event, { path, transport: 'sse' });
      if (frame.id === undefined) throw new Error(`SSE diagnostic without a durable ID (${event.stage ?? frame.event})`);
      if (!/^\d+$/.test(frame.id) || !Number.isSafeInteger(Number(frame.id))) throw new Error('SSE event has an invalid ID');
      event = { ...event, id: Number(frame.id) };
      if (frame.event !== event.kind) throw new Error('SSE event kind disagrees with payload');
      client.contract?.validate(event, { ref: 'LogEvent' });
      yield { event, receivedMs };
    }
  } finally {
    stop.abort();
    if (response?.body && !response.body.locked) await response.body.cancel().catch(() => {});
  }
}
