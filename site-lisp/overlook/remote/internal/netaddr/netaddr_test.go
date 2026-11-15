package netaddr

import (
	"net/netip"
	"testing"
)

func ifc(name string, addrs ...string) Interface {
	i := Interface{Name: name}
	for _, a := range addrs {
		i.Addrs = append(i.Addrs, netip.MustParseAddr(a))
	}
	return i
}

func TestPreferred(t *testing.T) {
	cases := []struct {
		name   string
		ifaces []Interface
		want   string
	}{
		{"tailscale wins", []Interface{ifc("lo0", "127.0.0.1"), ifc("en0", "192.168.1.5"), ifc("utun4", "fe80::1", "100.101.2.3")}, "100.101.2.3"},
		{"en next", []Interface{ifc("bridge0", "10.0.0.1"), ifc("en1", "169.254.3.4", "192.168.1.5")}, "192.168.1.5"},
		{"other last", []Interface{ifc("lo0", "127.0.0.1"), ifc("bridge0", "10.0.0.1")}, "10.0.0.1"},
		{"outside 100.64/10 is not tailscale", []Interface{ifc("en0", "192.168.1.5"), ifc("utun1", "100.128.0.1")}, "192.168.1.5"},
		{"ipv6 only", []Interface{ifc("en0", "2001:db8::1")}, ""},
		{"none", nil, ""},
	}
	for _, c := range cases {
		if got := Preferred(c.ifaces); got != c.want {
			t.Errorf("%s: Preferred = %q, want %q", c.name, got, c.want)
		}
	}
}
