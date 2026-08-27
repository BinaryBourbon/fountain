package runner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"os/exec"
	"strings"
)

// FCNet is the host networking a microVM backend needs: one tap device per
// VM, enslaved to a bridge the operator already owns, and a static address
// for the guest handed over on the kernel command line.
//
// The daemon deliberately stops at the bridge. Creating it, giving it an
// address, and deciding what may leave it are the host's business and an
// operator's choice — a daemon that wrote NAT rules would be reconfiguring
// a machine it was only invited to run sandboxes on.
type FCNet struct {
	Bridge  string
	Subnet  *net.IPNet
	Gateway net.IP
}

// ParseFCNet builds the config from the two flags that describe it.
func ParseFCNet(bridge, subnet string) (*FCNet, error) {
	if bridge == "" {
		return nil, fmt.Errorf("--bridge is required with --backend firecracker")
	}
	ip, cidr, err := net.ParseCIDR(subnet)
	if err != nil {
		return nil, fmt.Errorf("--subnet %q: %w", subnet, err)
	}
	if ip.To4() == nil {
		return nil, fmt.Errorf("--subnet %q: IPv4 only", subnet)
	}
	// The gateway is the subnet's first host address, which is the address
	// the operator is expected to have given the bridge.
	gw := make(net.IP, len(cidr.IP.To4()))
	copy(gw, cidr.IP.To4())
	gw[3]++
	return &FCNet{Bridge: bridge, Subnet: cidr, Gateway: gw}, nil
}

// tapName is derived from the sandbox name rather than a counter, so the
// same sandbox gets the same device across daemon restarts. Linux caps an
// interface name at 15 bytes and a Fountain sandbox name is 47, so the name
// is hashed rather than truncated — two sandboxes sharing a prefix must not
// share a device.
func tapName(sandbox string) string {
	sum := sha256.Sum256([]byte(sandbox))
	return "fc" + hex.EncodeToString(sum[:])[:12]
}

// macFor derives a locally-administered unicast MAC from the guest address,
// so a VM's identity on the bridge is stable across reboots too.
func macFor(ip net.IP) string {
	v4 := ip.To4()
	return fmt.Sprintf("02:fc:%02x:%02x:%02x:%02x", v4[0], v4[1], v4[2], v4[3])
}

// bootIP is the kernel's own ip= parameter: address, gateway, netmask, and
// off for autoconf. It is why the guest needs no DHCP client.
func (n *FCNet) bootIP(guest net.IP) string {
	mask := net.IP(n.Subnet.Mask).String()
	return fmt.Sprintf("ip=%s::%s:%s::eth0:off", guest.String(), n.Gateway.String(), mask)
}

// hostAddresses walks the subnet's usable addresses, skipping the network
// address and the gateway.
func (n *FCNet) hostAddresses() []net.IP {
	var out []net.IP
	ip := n.Subnet.IP.To4()
	for candidate := ipAdd(ip, 1); n.Subnet.Contains(candidate); candidate = ipAdd(candidate, 1) {
		// The broadcast address ends the range.
		if isBroadcast(candidate, n.Subnet) {
			break
		}
		if candidate.Equal(n.Gateway) {
			continue
		}
		out = append(out, candidate)
	}
	return out
}

func ipAdd(ip net.IP, n uint32) net.IP {
	v4 := ip.To4()
	value := uint32(v4[0])<<24 | uint32(v4[1])<<16 | uint32(v4[2])<<8 | uint32(v4[3])
	value += n
	return net.IPv4(byte(value>>24), byte(value>>16), byte(value>>8), byte(value)).To4()
}

func isBroadcast(ip net.IP, subnet *net.IPNet) bool {
	v4, mask := ip.To4(), subnet.Mask
	for i := range v4 {
		if v4[i]|mask[i] != 0xff {
			return false
		}
	}
	return true
}

// ensureTap creates the device and attaches it to the bridge. It is
// idempotent: a tap already there is adopted, because a create that retries
// must not fail on its own leftovers.
func ensureTap(ctx context.Context, name, bridge string) error {
	if err := ip(ctx, "tuntap", "add", name, "mode", "tap"); err != nil && !alreadyExists(err) {
		return err
	}
	if err := ip(ctx, "link", "set", name, "master", bridge); err != nil {
		return err
	}
	return ip(ctx, "link", "set", name, "up")
}

func deleteTap(ctx context.Context, name string) {
	_ = ip(ctx, "link", "del", name)
}

func ip(ctx context.Context, args ...string) error {
	cmd := exec.CommandContext(ctx, "ip", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ip %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return nil
}

func alreadyExists(err error) bool {
	return err != nil && strings.Contains(strings.ToLower(err.Error()), "file exists")
}
