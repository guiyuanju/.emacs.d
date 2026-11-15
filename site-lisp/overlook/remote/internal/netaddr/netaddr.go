// Package netaddr picks the address a phone should use to reach this Mac.
package netaddr

import (
	"net"
	"net/netip"
	"strings"
)

// tailscale is the CGNAT range Tailscale assigns addresses from.
var tailscale = netip.MustParsePrefix("100.64.0.0/10")

// Interface is a network interface's name and IPv4 addresses.
type Interface struct {
	Name  string
	Addrs []netip.Addr
}

// Preferred returns the IPv4 address in ifaces a phone should open: Tailscale's, else an en interface's,
// else any other that is neither loopback nor link-local; "" when there is none.
func Preferred(ifaces []Interface) string {
	var en, other string
	for _, ifc := range ifaces {
		for _, a := range ifc.Addrs {
			if !a.Is4() || a.IsLoopback() || a.IsLinkLocalUnicast() {
				continue
			}
			switch {
			case tailscale.Contains(a):
				return a.String()
			case en == "" && strings.HasPrefix(ifc.Name, "en"):
				en = a.String()
			case other == "":
				other = a.String()
			}
		}
	}
	if en != "" {
		return en
	}
	return other
}

// Interfaces lists the up interfaces of this machine.
func Interfaces() []Interface {
	ifs, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []Interface
	for _, ifc := range ifs {
		if ifc.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := ifc.Addrs()
		if err != nil {
			continue
		}
		i := Interface{Name: ifc.Name}
		for _, a := range addrs {
			if n, ok := a.(*net.IPNet); ok {
				if ip, ok := netip.AddrFromSlice(n.IP); ok {
					i.Addrs = append(i.Addrs, ip.Unmap())
				}
			}
		}
		out = append(out, i)
	}
	return out
}

// Host is Preferred of this machine's interfaces.
func Host() string { return Preferred(Interfaces()) }
