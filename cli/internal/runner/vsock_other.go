//go:build !linux

package runner

import "errors"

// ListenVsock exists on every platform so `fountain runner-guest` is one
// command with one help text. It only ever runs inside a Linux microVM, and
// says so rather than failing as an unknown command on a Mac.
func ListenVsock(port uint32) (GuestListener, error) {
	return nil, errors.New("runner-guest runs inside a Linux microVM; there is no vsock here")
}
