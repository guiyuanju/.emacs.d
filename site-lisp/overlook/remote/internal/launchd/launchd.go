// Package launchd takes over listening sockets that launchd holds for the job (the plist's Sockets key).
//
// launchd keeps such sockets open while the daemon restarts, so connections wait in the
// backlog instead of being refused.
package launchd

import (
	"fmt"
	"net"
	"os"
	"strings"
)

// Prefix marks a listen address naming a launchd socket, as in "launchd:http".
const Prefix = "launchd:"

// Name returns the socket name of a "launchd:<name>" address.
func Name(addr string) (string, bool) {
	name, ok := strings.CutPrefix(addr, Prefix)
	if !ok || name == "" {
		return "", false
	}
	return name, true
}

// Listeners returns the listeners launchd made for the plist's Sockets entry name.
func Listeners(name string) ([]net.Listener, error) {
	fds, err := activate(name)
	if err != nil {
		return nil, fmt.Errorf("launchd socket %q: %w", name, err)
	}
	var out []net.Listener
	for _, fd := range fds {
		f := os.NewFile(uintptr(fd), "launchd:"+name)
		ln, err := net.FileListener(f)
		f.Close()
		if err != nil {
			for _, l := range out {
				l.Close()
			}
			return nil, fmt.Errorf("launchd socket %q: %w", name, err)
		}
		out = append(out, ln)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("launchd socket %q: no sockets", name)
	}
	return out, nil
}
