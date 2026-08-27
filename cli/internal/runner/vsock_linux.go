//go:build linux

package runner

import (
	"fmt"
	"io"
	"os"
	"sync"

	"golang.org/x/sys/unix"
)

// vsockListener accepts AF_VSOCK connections from the host.
//
// Go's net package knows AF_INET, AF_INET6 and AF_UNIX, and net.FileListener
// refuses anything else, so this is built on the syscalls directly. Accepted
// connections become *os.File, which is a working io.ReadWriteCloser on a
// socket — enough for the newline-delimited protocol the agent speaks.
type vsockListener struct {
	fd   int
	once sync.Once
}

// ListenVsock listens on a vsock port for connections from the host. The
// guest binds VMADDR_CID_ANY: a microVM has exactly one host, and it is the
// only party that can reach this address at all.
func ListenVsock(port uint32) (GuestListener, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("vsock socket: %w", err)
	}
	sa := &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}
	if err := unix.Bind(fd, sa); err != nil {
		_ = unix.Close(fd)
		return nil, fmt.Errorf("vsock bind port %d: %w", port, err)
	}
	if err := unix.Listen(fd, 16); err != nil {
		_ = unix.Close(fd)
		return nil, fmt.Errorf("vsock listen: %w", err)
	}
	return &vsockListener{fd: fd}, nil
}

func (l *vsockListener) Accept() (io.ReadWriteCloser, error) {
	nfd, _, err := unix.Accept4(l.fd, unix.SOCK_CLOEXEC)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(nfd), "vsock"), nil
}

func (l *vsockListener) Close() error {
	var err error
	l.once.Do(func() { err = unix.Close(l.fd) })
	return err
}
