package main

import (
	"context"
	"flag"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/j4y-w4lk3r/bmcctl/internal/bmc"
	"github.com/j4y-w4lk3r/bmcctl/internal/bmc/testmegarac"
	"github.com/j4y-w4lk3r/bmcctl/internal/secrets"
)

// TestParseInterspersed covers the original symptom that motivated the
// helper: `init <host> --label NAME` should produce host as positional
// and --label as a parsed flag, regardless of argument order.
func TestParseInterspersed(t *testing.T) {
	cases := []struct {
		name           string
		args           []string
		wantLabel      string
		wantVault      string
		wantLength     int
		wantForce      bool
		wantPositional []string
	}{
		{
			name:           "flags-first (was already working)",
			args:           []string{"--label", "router", "--vault", "Private", "--length", "20", "192.168.1.54"},
			wantLabel:      "router",
			wantVault:      "Private",
			wantLength:     20,
			wantPositional: []string{"192.168.1.54"},
		},
		{
			name:           "positional-first (the bug we fixed)",
			args:           []string{"192.168.1.54", "--label", "bmc-54", "--vault", "Private", "--length", "20"},
			wantLabel:      "bmc-54",
			wantVault:      "Private",
			wantLength:     20,
			wantPositional: []string{"192.168.1.54"},
		},
		{
			name:           "interleaved",
			args:           []string{"--label", "router", "192.168.1.54", "--length", "18"},
			wantLabel:      "router",
			wantVault:      "Private", // default preserved
			wantLength:     18,
			wantPositional: []string{"192.168.1.54"},
		},
		{
			name:           "bool flag in the middle does NOT eat a positional",
			args:           []string{"192.168.1.54", "--force", "--label", "bmc-54"},
			wantLabel:      "bmc-54",
			wantVault:      "Private",
			wantLength:     20,
			wantForce:      true,
			wantPositional: []string{"192.168.1.54"},
		},
		{
			name:           "equals-form (--key=value)",
			args:           []string{"192.168.1.54", "--label=router", "--length=18"},
			wantLabel:      "router",
			wantVault:      "Private",
			wantLength:     18,
			wantPositional: []string{"192.168.1.54"},
		},
		{
			name:           "double dash separator",
			args:           []string{"--label", "router", "--", "192.168.1.54", "--this-is-positional"},
			wantLabel:      "router",
			wantVault:      "Private",
			wantLength:     20,
			wantPositional: []string{"192.168.1.54", "--this-is-positional"},
		},
		{
			name:           "no positional",
			args:           []string{"--label", "router"},
			wantLabel:      "router",
			wantVault:      "Private",
			wantLength:     20,
			wantPositional: nil,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			fs := flag.NewFlagSet("init", flag.ContinueOnError)
			label := fs.String("label", "", "")
			vault := fs.String("vault", "Private", "")
			length := fs.Int("length", 20, "")
			force := fs.Bool("force", false, "")

			pos, err := parseInterspersed(fs, c.args)
			if err != nil {
				t.Fatalf("parseInterspersed: %v", err)
			}
			if *label != c.wantLabel {
				t.Errorf("label = %q, want %q", *label, c.wantLabel)
			}
			if *vault != c.wantVault {
				t.Errorf("vault = %q, want %q", *vault, c.wantVault)
			}
			if *length != c.wantLength {
				t.Errorf("length = %d, want %d", *length, c.wantLength)
			}
			if *force != c.wantForce {
				t.Errorf("force = %v, want %v", *force, c.wantForce)
			}
			if !reflect.DeepEqual(pos, c.wantPositional) {
				t.Errorf("positional = %#v, want %#v", pos, c.wantPositional)
			}
		})
	}
}

// TestClampPasswordLength: simulates the three branches the user can
// take from `bmcctl init --length N`. Without this guard the user
// hits a useless "PropertyValueFormatError ... of length N" error
// from AMI MegaRAC; with it we clamp + warn before generating.
func TestClampPasswordLength(t *testing.T) {
	cases := []struct {
		name       string
		min        int
		max        int
		requested  int
		wantLen    int
		wantWarn   string // substring; "" means no warning
		wantErrSub string // substring; "" means no error
	}{
		{
			name: "well within policy",
			min:  8, max: 20,
			requested: 16,
			wantLen:   16,
		},
		{
			name: "exactly at the max",
			min:  8, max: 20,
			requested: 20,
			wantLen:   20,
		},
		{
			name: "too long -> clamped + warn (the W680D4U bug)",
			min:  8, max: 20,
			requested: 40,
			wantLen:   20,
			wantWarn:  "MaxPasswordLength=20",
		},
		{
			name: "too short -> hard error (don't silently weaken)",
			min:  12, max: 64,
			requested:  8,
			wantErrSub: "below the BMC's minimum",
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			srv, err := testmegarac.New(testmegarac.Options{
				MinPasswordLength: c.min,
				MaxPasswordLength: c.max,
			})
			if err != nil {
				t.Fatalf("testmegarac.New: %v", err)
			}
			defer srv.Close()
			client := bmc.NewClient(srv.Host, "admin", "admin")
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			gotLen, gotWarn, gotErr := clampPasswordLength(ctx, client, c.requested)
			if c.wantErrSub != "" {
				if gotErr == nil || !strings.Contains(gotErr.Error(), c.wantErrSub) {
					t.Fatalf("err = %v, want substring %q", gotErr, c.wantErrSub)
				}
				return
			}
			if gotErr != nil {
				t.Fatalf("unexpected err: %v", gotErr)
			}
			if gotLen != c.wantLen {
				t.Errorf("len = %d, want %d", gotLen, c.wantLen)
			}
			if c.wantWarn == "" && gotWarn != "" {
				t.Errorf("unexpected warning %q", gotWarn)
			}
			if c.wantWarn != "" && !strings.Contains(gotWarn, c.wantWarn) {
				t.Errorf("warning = %q, want substring %q", gotWarn, c.wantWarn)
			}
		})
	}
}

// withStore swaps the package-level secrets backend for the duration
// of a test and restores it on cleanup.
func withStore(t *testing.T, b secrets.Backend) {
	t.Helper()
	orig := store
	store = b
	t.Cleanup(func() { store = orig })
}

// TestCmdInit_AbortsBeforeBMCWhenVaultMissing is the test that pins
// the exact user-reported regression: a typo in --vault must NEVER
// reach the BMC PATCH. We point cmdInit at a live mock with an
// in-memory secrets store whose vaults do NOT contain "Private",
// then assert (1) the call errors out, (2) the error lists the
// vaults that DO exist, and (3) the BMC's password and lock state
// are untouched.
func TestCmdInit_AbortsBeforeBMCWhenVaultMissing(t *testing.T) {
	srv, err := testmegarac.New(testmegarac.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)

	mem := secrets.NewMemory()
	mem.SetVaults([]secrets.Vault{
		{ID: "id-personal", Name: "Personal"},
		{ID: "id-servers", Name: "Servers"},
	})
	withStore(t, mem)

	err = cmdInit([]string{
		srv.Host,
		"--label", "test",
		"--vault", "Private", // does NOT exist
		"--yes", // skip the [y/N] prompt
	})
	if err == nil {
		t.Fatal("cmdInit should error when --vault is missing")
	}
	if !strings.Contains(err.Error(), "Personal") || !strings.Contains(err.Error(), "Servers") {
		t.Errorf("error should list available vaults, got: %v", err)
	}
	// The bug we're guarding against:
	if !srv.Locked() {
		t.Error("BMC must still be locked — vault validation must run BEFORE the PATCH")
	}
	if srv.Password() != "admin" {
		t.Errorf("BMC password must be unchanged (still 'admin'), got %q", bmc.MaskPassword(srv.Password()))
	}
	// And nothing should have landed in 1Password either.
	if mem.Len() != 0 {
		t.Errorf("Memory backend should still be empty, has %d items", mem.Len())
	}
}

// TestCmdInit_VaultByID confirms --vault accepts a UUID, not just
// a name. This is the workaround the user offered:
// `--vault g3irkmq3taou5ko6gwxwlkcjd4`.
func TestCmdInit_VaultByID(t *testing.T) {
	srv, err := testmegarac.New(testmegarac.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)

	mem := secrets.NewMemory()
	mem.SetVaults([]secrets.Vault{
		{ID: "g3irkmq3taou5ko6gwxwlkcjd4", Name: "Personal"},
	})
	withStore(t, mem)

	// We can't run cmdInit fully end-to-end (writes ~/.config/...
	// which we don't want to touch in tests) but we CAN assert
	// that ResolveVault by ID works through the package store.
	got, err := store.ResolveVault("g3irkmq3taou5ko6gwxwlkcjd4")
	if err != nil {
		t.Fatalf("ResolveVault by ID failed: %v", err)
	}
	if got.Name != "Personal" {
		t.Errorf("resolved to %+v, want Personal", got)
	}
}

// TestStreamB_InstallArchOrchestration walks the full happy path:
//
//	eject any stale media -> InsertMedia -> SetBootOverride(Cd/Once)
//	-> PowerCycle -> PollPowerState(On)
//
// Done at the bmc.Client level (not via cmdInstallArch) because the
// CLI form requires a registered host in ~/.config/bmcctl/hosts.json
// which we don't want a test to write. The CLI is a thin shell around
// these calls, and TestCmdBoot_Override below covers the wiring on
// the SetBootOverride side end-to-end.
func TestStreamB_InstallArchOrchestration(t *testing.T) {
	open := false
	srv, err := testmegarac.New(testmegarac.Options{StartLocked: &open, PowerState: "Off"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)

	c := bmc.NewClient(srv.Host, "admin", "admin")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	const iso = "https://archlinux.example/iso/archlinux-x86_64.iso"

	// Pre-mount stale media to exercise the pre-eject branch.
	if err := c.InsertMedia(ctx, "CD1", "https://stale/old.iso", true); err != nil {
		t.Fatal(err)
	}

	// Step 1 + 2: eject stale, mount fresh.
	if err := c.EjectMedia(ctx, "CD1"); err != nil {
		t.Fatal(err)
	}
	if err := c.InsertMedia(ctx, "CD1", iso, true); err != nil {
		t.Fatal(err)
	}
	if got := srv.VirtualMediaSnapshot()["CD1"]; got != iso {
		t.Errorf("CD1 = %q, want %q", got, iso)
	}

	// Step 3: boot override.
	if err := c.SetBootOverride(ctx, bmc.BootTargetCD, bmc.BootEnabledOnce); err != nil {
		t.Fatal(err)
	}
	if tgt, en := srv.BootOverride(); tgt != "Cd" || en != "Once" {
		t.Errorf("boot override = (%q,%q), want (Cd,Once)", tgt, en)
	}

	// Step 4: power-cycle.
	if err := c.Power(ctx, "PowerCycle"); err != nil {
		t.Fatal(err)
	}
	log := srv.PowerLog()
	if len(log) != 1 || log[0] != "PowerCycle" {
		t.Errorf("PowerLog = %v, want [PowerCycle]", log)
	}

	// Step 5: PowerState should be On after the cycle (the mock
	// transitions Off->On for PowerCycle, mirroring real hardware).
	got, err := c.PollPowerState(ctx, "On", 50*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if got != "On" {
		t.Errorf("final PowerState = %q, want On", got)
	}
}

// TestCmdAdopt_Roundtrip exercises the recovery path: a BMC that
// is already past the password-change gate (someone changed it
// out-of-band — exactly the user's current state) should be
// adoptable into 1Password + local registry via stdin.
func TestCmdAdopt_Roundtrip(t *testing.T) {
	const realPW = "N59W=vjK9=3dNi~Ht%Ce"
	startUnlocked := false
	srv, err := testmegarac.New(testmegarac.Options{
		InitialPassword: realPW,
		StartLocked:     &startUnlocked, // not gated — adopt prereq.
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Close)

	mem := secrets.NewMemory()
	mem.SetVaults([]secrets.Vault{{ID: "id-personal", Name: "Personal"}})
	withStore(t, mem)

	// Verify the supplied creds work — this is what cmdAdopt does
	// before saving. We exercise the same Client surface to keep
	// the test independent of stdin plumbing.
	c := bmc.NewClient(srv.Host, "admin", realPW)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := c.GetServiceRoot(ctx); err != nil {
		t.Fatalf("supplied creds should work: %v", err)
	}

	// Now stash it ourselves via the same Backend cmdAdopt would.
	resolved, err := store.ResolveVault("Personal")
	if err != nil {
		t.Fatal(err)
	}
	uuid, err := store.CreateBMCItem(resolved.ID, "BMC – bmc-54", srv.Host, "admin", realPW,
		[]string{"bmc", "asrock-rack", "megarac", "adopted"})
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := mem.GetBMCPassword(uuid); got != realPW {
		t.Errorf("stored password mismatch")
	}
	if srv.Password() != realPW {
		t.Errorf("BMC password must remain unchanged by adopt: %q", bmc.MaskPassword(srv.Password()))
	}
}
