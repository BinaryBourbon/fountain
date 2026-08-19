package runner

import (
	"encoding/base64"
	"io"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Session is one streaming command: a process, its stdin, and a journal of
// every frame it produced, so an attacher can replay from byte zero. Frames
// reach Fountain only while the session is attached; the journal always
// records them.
type Session struct {
	id        string
	sandbox   string
	command   string
	createdAt time.Time
	emit      Emitter
	log       Logger

	cmd   *exec.Cmd
	stdin io.WriteCloser

	mu           sync.Mutex // journal, attached, exitCode, lastActivity
	journal      []Frame
	attached     bool
	exitCode     *int
	lastActivity time.Time

	stdinMu   sync.Mutex
	stdinOnce sync.Once
	done      chan struct{}
}

func startSession(id, sandbox string, cmd *exec.Cmd, withStdin bool, emit Emitter, log Logger) (*Session, error) {
	s := &Session{
		id:           id,
		sandbox:      sandbox,
		command:      strings.Join(append([]string{cmd.Path}, cmd.Args[1:]...), " "),
		createdAt:    time.Now(),
		lastActivity: time.Now(),
		emit:         emit,
		log:          log,
		cmd:          cmd,
		done:         make(chan struct{}),
	}
	// Its own process group, so terminate() reaches children too (a `bash
	// -lc` wrapper and whatever it started).
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if withStdin {
		s.stdin, err = cmd.StdinPipe()
		if err != nil {
			return nil, err
		}
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	var pumps sync.WaitGroup
	pumps.Add(2)
	go s.pump("stdout", stdout, &pumps)
	go s.pump("stderr", stderr, &pumps)
	go func() {
		pumps.Wait()
		err := cmd.Wait()
		code := 0
		if err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				code = ee.ExitCode()
				if code < 0 {
					code = 137
				}
			} else {
				code = 1
			}
		}
		s.finish(code)
	}()
	return s, nil
}

// failedSession is what a command that could not start looks like: exit 127
// with the reason on stdout, already finished, ready to be replayed.
func failedSession(id, sandbox, command string, cause error, emit Emitter) *Session {
	s := &Session{
		id:           id,
		sandbox:      sandbox,
		command:      command,
		createdAt:    time.Now(),
		lastActivity: time.Now(),
		emit:         emit,
		done:         make(chan struct{}),
	}
	s.record("stdout", []byte("fountain runner: "+cause.Error()+"\n"))
	s.finish(127)
	return s
}

func (s *Session) pump(stream string, r io.Reader, wg *sync.WaitGroup) {
	defer wg.Done()
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			s.record(stream, chunk)
		}
		if err != nil {
			return
		}
	}
}

func (s *Session) record(stream string, data []byte) {
	frame := Frame{
		"stream":     stream,
		"session_id": s.id,
		"data":       base64.StdEncoding.EncodeToString(data),
	}
	// Emitted under the lock: attach() replays the journal under the same
	// lock, so a live frame can never be sent both as replay and as live to
	// the same attacher, and journal order is wire order.
	s.mu.Lock()
	defer s.mu.Unlock()
	s.journal = append(s.journal, frame)
	s.lastActivity = time.Now()
	if s.attached && s.emit != nil {
		s.emit.Emit(frame)
	}
}

func (s *Session) finish(code int) {
	frame := Frame{"stream": "exit", "session_id": s.id, "code": code}
	s.mu.Lock()
	if s.exitCode != nil {
		s.mu.Unlock()
		return
	}
	c := code
	s.exitCode = &c
	s.journal = append(s.journal, frame)
	if s.attached && s.emit != nil {
		s.emit.Emit(frame)
	}
	s.mu.Unlock()
	if s.stdin != nil {
		s.stdinOnce.Do(func() { _ = s.stdin.Close() })
	}
	close(s.done)
}

// attach replays the journal from byte zero, tagged for the requester, and
// switches live emission on — under one lock, so no frame is missed or
// delivered twice around the switch.
func (s *Session) attach(reqID int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, f := range s.journal {
		replay := make(Frame, len(f)+1)
		for k, v := range f {
			replay[k] = v
		}
		replay["replay_for"] = reqID
		if s.emit != nil {
			s.emit.Emit(replay)
		}
	}
	s.attached = true
}

func (s *Session) detach() {
	s.mu.Lock()
	s.attached = false
	s.mu.Unlock()
}

func (s *Session) exited() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.exitCode != nil
}

// write is total: a session that has ended answers command_exited.
func (s *Session) write(data []byte) error {
	if s.exited() {
		return commandExited()
	}
	if s.stdin == nil {
		return writeFailed("command was spawned without stdin")
	}
	s.stdinMu.Lock()
	defer s.stdinMu.Unlock()
	if _, err := s.stdin.Write(data); err != nil {
		if s.exited() {
			return commandExited()
		}
		return writeFailed(err.Error())
	}
	s.mu.Lock()
	s.lastActivity = time.Now()
	s.mu.Unlock()
	return nil
}

func (s *Session) closeStdin() {
	if s.stdin != nil {
		s.stdinOnce.Do(func() { _ = s.stdin.Close() })
	}
}

// terminate asks the process group to stop and kills it after grace.
func (s *Session) terminate(grace time.Duration) {
	if s.cmd == nil || s.cmd.Process == nil || s.exited() {
		return
	}
	pgid := -s.cmd.Process.Pid
	_ = syscall.Kill(pgid, syscall.SIGTERM)
	select {
	case <-s.done:
	case <-time.After(grace):
		_ = syscall.Kill(pgid, syscall.SIGKILL)
		select {
		case <-s.done:
		case <-time.After(2 * time.Second):
		}
	}
}

func (s *Session) describe() map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := map[string]any{
		"id":               s.id,
		"command":          s.command,
		"created_at":       s.createdAt.UTC().Format(time.RFC3339),
		"last_activity_at": s.lastActivity.UTC().Format(time.RFC3339),
		"tty":              false,
	}
	if s.exitCode != nil {
		out["exit_code"] = *s.exitCode
	}
	return out
}
