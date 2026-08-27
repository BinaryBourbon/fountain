package runner

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"
)

// GuestPort is the vsock port the in-VM agent listens on.
const GuestPort = 1024

func encodeB64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

// guestLink is the host's end of one microVM's agent connection.
//
// Firecracker publishes a guest's listening vsock ports on the host as a
// unix socket with a text handshake, so this needs no AF_VSOCK support on
// the host side: dial the socket, send "CONNECT 1024", and what comes back
// is a stream to `fountain runner-guest` inside the VM. Over it runs the
// same newline-delimited protocol Fountain speaks to the daemon, which is
// what lets the guest serve it with an ordinary Process backend.
//
// The link forwards a request and waits for its reply. Two things it must
// get right, both of them ordering:
//
//   - A spawn's replay must not overtake the spawn's own reply. The guest
//     honours that on its side, but the host's reply is only written after
//     this call returns, so frames arriving in between are held and
//     released by the `after` the caller runs.
//   - A VM that dies mid-turn must not look like a command that succeeded.
//     Fountain reads a stream that ends without an exit frame as exit 0, so
//     a dropped link synthesises exit 137 for every session still running.
type guestLink struct {
	uds string
	log Logger

	mu      sync.Mutex
	conn    net.Conn
	reader  *bufio.Reader
	pending map[int]*pendingCall
	gates   map[string][]Frame // session id → frames held until `after`
	live    map[string]bool    // session id → running, no exit seen yet
	emit    Emitter
	probe   int // ids for the daemon's own requests; Fountain's are positive
	epoch   int // bumped on every drop, so a stale reader exits quietly
}

type pendingCall struct {
	gating bool // spawn/attach: the reply names a session whose frames gate
	reply  chan Frame
}

func newGuestLink(uds string, log Logger) *guestLink {
	return &guestLink{
		uds:     uds,
		log:     log,
		pending: map[int]*pendingCall{},
		gates:   map[string][]Frame{},
		live:    map[string]bool{},
	}
}

// dialGuest opens the vsock stream: connect to the host-side socket, ask for
// the guest port, and check the acknowledgement before handing the stream on.
// Firecracker answers "OK <port>" and nothing else means the guest is not
// listening — which is a rootfs that never started the agent, and worth
// saying so rather than reporting a generic timeout.
func dialGuest(ctx context.Context, uds string) (net.Conn, *bufio.Reader, error) {
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", uds)
	if err != nil {
		return nil, nil, err
	}
	if _, err := fmt.Fprintf(conn, "CONNECT %d\n", GuestPort); err != nil {
		_ = conn.Close()
		return nil, nil, err
	}
	r := bufio.NewReader(conn)
	line, err := r.ReadString('\n')
	if err != nil {
		_ = conn.Close()
		return nil, nil, fmt.Errorf("no answer from the guest agent on vsock port %d: %w", GuestPort, err)
	}
	if !strings.HasPrefix(line, "OK ") {
		_ = conn.Close()
		return nil, nil, fmt.Errorf("guest agent is not listening on vsock port %d (firecracker said %q) — "+
			"the base rootfs must start `fountain runner-guest` at boot", GuestPort, strings.TrimSpace(line))
	}
	return conn, r, nil
}

// connect brings the link up if it is down. Callers hold no lock.
func (g *guestLink) connect(ctx context.Context) error {
	g.mu.Lock()
	if g.conn != nil {
		g.mu.Unlock()
		return nil
	}
	g.mu.Unlock()

	conn, reader, err := dialGuest(ctx, g.uds)
	if err != nil {
		return err
	}

	g.mu.Lock()
	if g.conn != nil { // another caller won the race
		g.mu.Unlock()
		_ = conn.Close()
		return nil
	}
	g.conn = conn
	g.reader = reader
	g.epoch++
	epoch := g.epoch
	g.mu.Unlock()

	go g.read(epoch, reader)
	return nil
}

// call forwards one request and waits for its reply. The returned `after`
// releases the frames held while the reply was in flight.
func (g *guestLink) call(ctx context.Context, req Request, emit Emitter) (map[string]any, func(), error) {
	if err := g.connect(ctx); err != nil {
		return nil, nil, unavailable(err.Error())
	}
	gating := req.Op == "spawn" || req.Op == "attach"
	pc := &pendingCall{gating: gating, reply: make(chan Frame, 1)}

	g.mu.Lock()
	if emit != nil {
		g.emit = emit
	}
	if _, taken := g.pending[req.ID]; taken {
		g.mu.Unlock()
		return nil, nil, unavailable(fmt.Sprintf("request id %d is already in flight to this sandbox", req.ID))
	}
	g.pending[req.ID] = pc
	conn := g.conn
	g.mu.Unlock()

	payload, err := json.Marshal(req)
	if err != nil {
		g.forget(req.ID)
		return nil, nil, invalid(err.Error())
	}
	g.mu.Lock()
	_, werr := conn.Write(append(payload, '\n'))
	g.mu.Unlock()
	if werr != nil {
		g.forget(req.ID)
		g.drop(werr)
		return nil, nil, unavailable(werr.Error())
	}

	select {
	case <-ctx.Done():
		g.forget(req.ID)
		return nil, nil, unavailable(ctx.Err().Error())
	case frame, ok := <-pc.reply:
		if !ok {
			return nil, nil, unavailable("the microVM's agent connection dropped")
		}
		return g.decode(frame)
	}
}

// decode turns the guest's reply frame back into the daemon's triple, so an
// error the guest raised reaches Fountain as the same code it chose rather
// than as a generic provider failure.
func (g *guestLink) decode(frame Frame) (map[string]any, func(), error) {
	if ok, _ := frame["ok"].(bool); !ok {
		code, _ := frame["error"].(string)
		detail, _ := frame["detail"].(string)
		if code == "" {
			code = "provider"
		}
		return nil, nil, &OpError{Code: code, Detail: detail}
	}
	result, _ := frame["result"].(map[string]any)
	if result == nil {
		result = map[string]any{}
	}
	sid, _ := result["session_id"].(string)
	var after func()
	if sid != "" {
		if _, gated := g.gateOf(sid); gated {
			after = func() { g.release(sid) }
		}
	}
	return result, after, nil
}

func (g *guestLink) gateOf(sid string) ([]Frame, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	held, ok := g.gates[sid]
	return held, ok
}

// release emits the held frames and reopens the session's path to the wire.
// Emitting under the lock is deliberate: the reader takes the same lock, so
// a frame arriving now cannot overtake the ones being flushed.
func (g *guestLink) release(sid string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	held := g.gates[sid]
	delete(g.gates, sid)
	for _, f := range held {
		if g.emit != nil {
			g.emit.Emit(f)
		}
	}
}

// probeID mints an id for a request the daemon makes on its own account (a
// boot ping, a sync before shutdown), kept negative so it can never collide
// with one of Fountain's.
func (g *guestLink) probeID() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.probe--
	return g.probe
}

func (g *guestLink) forget(id int) {
	g.mu.Lock()
	delete(g.pending, id)
	g.mu.Unlock()
}

// read pumps the guest's frames until the link drops.
func (g *guestLink) read(epoch int, reader *bufio.Reader) {
	for {
		line, err := reader.ReadString('\n')
		if len(line) > 0 {
			g.handle(line)
		}
		if err != nil {
			g.mu.Lock()
			stale := g.epoch != epoch
			g.mu.Unlock()
			if !stale {
				g.drop(err)
			}
			return
		}
	}
}

func (g *guestLink) handle(line string) {
	var frame Frame
	if err := json.Unmarshal([]byte(line), &frame); err != nil {
		return
	}
	if raw, isReply := frame["id"]; isReply {
		id, ok := raw.(float64)
		if !ok {
			return
		}
		g.deliver(int(id), frame)
		return
	}
	g.stream(frame)
}

// deliver hands a reply to its caller, gating the session it names first so
// that no frame of that session can reach the wire before the reply does.
func (g *guestLink) deliver(id int, frame Frame) {
	g.mu.Lock()
	pc, ok := g.pending[id]
	if !ok {
		g.mu.Unlock()
		return
	}
	delete(g.pending, id)
	if pc.gating {
		if result, isMap := frame["result"].(map[string]any); isMap {
			if sid, isStr := result["session_id"].(string); isStr && sid != "" {
				g.gates[sid] = nil
			}
		}
	}
	g.mu.Unlock()
	pc.reply <- frame
}

func (g *guestLink) stream(frame Frame) {
	sid, _ := frame["session_id"].(string)
	g.mu.Lock()
	if sid != "" {
		if frame["stream"] == "exit" {
			delete(g.live, sid)
		} else {
			g.live[sid] = true
		}
		if held, gated := g.gates[sid]; gated {
			g.gates[sid] = append(held, frame)
			g.mu.Unlock()
			return
		}
	}
	emit := g.emit
	g.mu.Unlock()
	if emit != nil {
		emit.Emit(frame)
	}
}

// drop tears the link down and tells the truth about what it was carrying:
// every pending call fails transiently, and every session still running gets
// a terminal frame. A stream that just stops is read by Fountain as exit 0,
// which would turn a microVM crash into a turn that looks like it worked.
func (g *guestLink) drop(cause error) {
	g.mu.Lock()
	if g.conn == nil {
		g.mu.Unlock()
		return
	}
	_ = g.conn.Close()
	g.conn = nil
	g.reader = nil
	pending := g.pending
	g.pending = map[int]*pendingCall{}
	live := g.live
	g.live = map[string]bool{}
	g.gates = map[string][]Frame{}
	emit := g.emit
	reason := "unknown cause"
	if cause != nil {
		reason = cause.Error()
	}
	// Terminal frames go out under the lock, in the same place every other
	// frame is emitted, so ordering holds against a reconnect.
	for sid := range live {
		if emit == nil {
			break
		}
		emit.Emit(Frame{
			"stream":     "stderr",
			"session_id": sid,
			"data":       encodeB64("\nfountain runner: the microVM's agent connection dropped (" + reason + ")\n"),
		})
		emit.Emit(Frame{"stream": "exit", "session_id": sid, "code": 137})
	}
	g.mu.Unlock()

	for _, pc := range pending {
		close(pc.reply)
	}
	if g.log != nil {
		g.log.Warn("runner: guest agent link dropped", "uds", g.uds, "err", reason)
	}
}

// close shuts the link without synthesising anything: the caller is
// destroying or parking the sandbox on purpose.
func (g *guestLink) close() {
	g.mu.Lock()
	conn := g.conn
	g.conn = nil
	g.reader = nil
	g.epoch++
	pending := g.pending
	g.pending = map[int]*pendingCall{}
	g.live = map[string]bool{}
	g.gates = map[string][]Frame{}
	g.mu.Unlock()
	if conn != nil {
		_ = conn.Close()
	}
	for _, pc := range pending {
		close(pc.reply)
	}
}
