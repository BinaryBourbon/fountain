package runner

import (
	"errors"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestParseFCNetRequiresABridge(t *testing.T) {
	if _, err := ParseFCNet("", "10.61.0.0/24"); err == nil || !strings.Contains(err.Error(), "--bridge") {
		t.Fatalf("err = %v", err)
	}
}

func TestParseFCNetRejectsABadSubnet(t *testing.T) {
	for _, subnet := range []string{"", "10.61.0.0", "nonsense", "fd00::/64"} {
		if _, err := ParseFCNet("fcbr0", subnet); err == nil {
			t.Fatalf("subnet %q was accepted", subnet)
		}
	}
}

// The gateway is the subnet's first host address, which is the address the
// operator is told to give the bridge. Getting it wrong would hand every
// guest a default route to nowhere.
func TestGatewayIsTheFirstHostAddress(t *testing.T) {
	n, err := ParseFCNet("fcbr0", "10.61.0.0/24")
	if err != nil {
		t.Fatal(err)
	}
	if n.Gateway.String() != "10.61.0.1" {
		t.Fatalf("gateway = %s", n.Gateway)
	}
}

// The address pool must skip the network address, the gateway and the
// broadcast address; handing one of those to a guest is a sandbox that
// cannot reach anything.
func TestHostAddressesSkipTheReservedOnes(t *testing.T) {
	n, err := ParseFCNet("fcbr0", "10.61.0.0/29")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, ip := range n.hostAddresses() {
		got = append(got, ip.String())
	}
	want := []string{"10.61.0.2", "10.61.0.3", "10.61.0.4", "10.61.0.5", "10.61.0.6"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("addresses = %v, want %v", got, want)
	}
}

// A Fountain sandbox name is 47 bytes and Linux caps an interface name at
// 15, so the tap name is hashed. Truncating would give two sandboxes the
// same device, and they share a name prefix by construction.
func TestTapNamesFitAndDoNotCollide(t *testing.T) {
	a := tapName("runner-0123456789abcdef0123456789abcdef-aabbccdd")
	b := tapName("runner-0123456789abcdef0123456789abcdef-aabbccde")
	if len(a) > 15 {
		t.Fatalf("tap name %q is %d bytes, over the 15-byte limit", a, len(a))
	}
	if a == b {
		t.Fatalf("two sandboxes share the tap device %q", a)
	}
	if a != tapName("runner-0123456789abcdef0123456789abcdef-aabbccdd") {
		t.Fatal("tap name is not stable across calls")
	}
}

func TestBootIPCarriesAddressGatewayAndMask(t *testing.T) {
	n, err := ParseFCNet("fcbr0", "10.61.0.0/24")
	if err != nil {
		t.Fatal(err)
	}
	got := n.bootIP(net.ParseIP("10.61.0.7"))
	if got != "ip=10.61.0.7::10.61.0.1:255.255.255.0::eth0:off" {
		t.Fatalf("bootIP = %q", got)
	}
}

func TestMACIsLocallyAdministeredAndDerivedFromTheAddress(t *testing.T) {
	got := macFor(net.ParseIP("10.61.0.7"))
	if got != "02:fc:0a:3d:00:07" {
		t.Fatalf("mac = %q", got)
	}
	hw, err := net.ParseMAC(got)
	if err != nil {
		t.Fatal(err)
	}
	// Bit 1 of the first octet marks a locally administered address; bit 0
	// clear marks it unicast.
	if hw[0]&0b10 == 0 || hw[0]&0b1 != 0 {
		t.Fatalf("%s is not a locally administered unicast address", got)
	}
}

// The configuration is checked before the machine, so an operator who
// mistypes a path is told that rather than being told their host has no KVM.
func TestNewFirecrackerReportsConfigurationBeforeEnvironment(t *testing.T) {
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	n, err := ParseFCNet("fcbr0", "10.61.0.0/24")
	if err != nil {
		t.Fatal(err)
	}
	_, err = NewFirecracker(FirecrackerConfig{Root: t.TempDir(), Net: n}, log)
	if err == nil || !strings.Contains(err.Error(), "--fc-kernel") {
		t.Fatalf("err = %v, want one naming --fc-kernel", err)
	}

	kernel := filepath.Join(t.TempDir(), "vmlinux")
	if err := os.WriteFile(kernel, []byte("not really a kernel"), 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = NewFirecracker(FirecrackerConfig{Root: t.TempDir(), Net: n, Kernel: kernel}, log)
	if err == nil || !strings.Contains(err.Error(), "--fc-rootfs") {
		t.Fatalf("err = %v, want one naming --fc-rootfs", err)
	}
}

// An existing disk is the agent's memory. A second create must adopt it,
// never replace it with a fresh copy of the base image.
func TestRootfsCopyNeverOverwritesAnExistingDisk(t *testing.T) {
	dir := t.TempDir()
	base := filepath.Join(dir, "base.ext4")
	target := filepath.Join(dir, "rootfs.ext4")
	if err := os.WriteFile(base, []byte("base image"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := ensureRootfsCopy(base, target); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(target); string(got) != "base image" {
		t.Fatalf("first copy = %q", got)
	}

	if err := os.WriteFile(target, []byte("the agent's work"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ensureRootfsCopy(base, target); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(target); string(got) != "the agent's work" {
		t.Fatalf("the sandbox disk was overwritten: %q", got)
	}
}

// A copy that is interrupted must not be mistaken for a sandbox's disk on
// the next boot, so it lands under a partial name and is renamed only once
// it is whole.
func TestRootfsCopyLeavesNoPartialBehind(t *testing.T) {
	dir := t.TempDir()
	base := filepath.Join(dir, "base.ext4")
	target := filepath.Join(dir, "rootfs.ext4")
	if err := os.WriteFile(base, []byte("base image"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ensureRootfsCopy(base, target); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(target + ".partial"); !os.IsNotExist(err) {
		t.Fatal("a .partial file was left behind")
	}
}

// The lifecycle half of the backend does not need KVM to be checked: a
// sandbox with no microVM behind it still has to answer correctly, and those
// answers are what protect an agent's memory from the reaper.
func newTestFirecracker(t *testing.T) *Firecracker {
	t.Helper()
	n, err := ParseFCNet("fcbr0", "10.61.0.0/24")
	if err != nil {
		t.Fatal(err)
	}
	return &Firecracker{
		cfg:       FirecrackerConfig{Root: t.TempDir(), Net: n},
		log:       slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError})),
		vms:       map[string]*microVM{},
		bootGates: map[string]*sync.Mutex{},
		sessions:  map[string]string{},
	}
}

// A disk with no microVM behind it is parked, never missing. Fountain gives
// up a sandbox on not_found, and that disk is the agent's memory.
func TestGetReportsADiskWithNoVMAsSuspended(t *testing.T) {
	f := newTestFirecracker(t)
	if err := os.MkdirAll(filepath.Join(f.cfg.Root, "runner-a-1"), 0o700); err != nil {
		t.Fatal(err)
	}
	result, _, err := f.Get(Request{Name: "runner-a-1"})
	if err != nil {
		t.Fatal(err)
	}
	if result["status"] != "suspended" {
		t.Fatalf("status = %v, want suspended", result["status"])
	}

	_, _, err = f.Get(Request{Name: "runner-gone"})
	var op *OpError
	if !errors.As(err, &op) || op.Code != "not_found" {
		t.Fatalf("err = %v, want not_found", err)
	}
}

func TestDestroyToleratesASandboxThatIsAlreadyGone(t *testing.T) {
	f := newTestFirecracker(t)
	if _, _, err := f.Destroy(Request{Name: "runner-never-existed"}); err != nil {
		t.Fatalf("destroy = %v, want nil", err)
	}
}

func TestListNamesEverySandboxDirectory(t *testing.T) {
	f := newTestFirecracker(t)
	for _, name := range []string{"runner-b-2", "runner-a-1", ".hidden"} {
		if err := os.MkdirAll(filepath.Join(f.cfg.Root, name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	result, _, err := f.List()
	if err != nil {
		t.Fatal(err)
	}
	names := result["names"].([]string)
	if strings.Join(names, ",") != "runner-a-1,runner-b-2" {
		t.Fatalf("names = %v", names)
	}
}

// stdin and attach name a session rather than a sandbox, so the host has to
// remember which VM a session lives in. It must survive a link that drops
// and reconnects: the guest still holds the session, and answering not_found
// would be a permanent error for something still running.
func TestSessionOwnershipIsHeldByTheBackend(t *testing.T) {
	f := newTestFirecracker(t)
	f.sessions["s-1"] = "runner-a-1"

	got, err := f.sandboxOfSession("s-1")
	if err != nil || got != "runner-a-1" {
		t.Fatalf("sandboxOfSession = %q, %v", got, err)
	}

	_, err = f.sandboxOfSession("s-unknown")
	var op *OpError
	if !errors.As(err, &op) || op.Code != "not_found" {
		t.Fatalf("err = %v, want not_found", err)
	}

	f.forgetSessions("runner-a-1")
	if _, err := f.sandboxOfSession("s-1"); err == nil {
		t.Fatal("a destroyed sandbox still owns its sessions")
	}
}

// Two conversations starting together must not each spawn a firecracker
// process on the same API socket.
func TestBootGateIsOnePerSandbox(t *testing.T) {
	f := newTestFirecracker(t)
	if f.bootGate("runner-a-1") != f.bootGate("runner-a-1") {
		t.Fatal("a sandbox got two different boot gates")
	}
	if f.bootGate("runner-a-1") == f.bootGate("runner-b-2") {
		t.Fatal("two sandboxes share one boot gate")
	}
}

// `path` is the path a process inside the sandbox sees as its home, not the
// host directory holding the disk. Fountain rewrites the ACP `cwd` through
// it (Fountain.Sandbox.Runner.host_path/2), and an agent CLI validates that
// path in band before it starts a session — so naming the host's state
// directory fails the turn with an invalid-cwd error, after a microVM has
// booted and provisioned perfectly. Found on hardware, not in a test.
func TestGetReportsTheInGuestHomeAsThePath(t *testing.T) {
	f := newTestFirecracker(t)
	dir := filepath.Join(f.cfg.Root, "runner-a-1")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	result, _, err := f.Get(Request{Name: "runner-a-1"})
	if err != nil {
		t.Fatal(err)
	}
	if result["path"] != spriteHome {
		t.Fatalf("path = %v, want %s — the ACP cwd is rewritten through this", result["path"], spriteHome)
	}
	if result["host_dir"] != dir {
		t.Fatalf("host_dir = %v, want %s", result["host_dir"], dir)
	}
}
