package bmc

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/j4y-w4lk3r/bmcctl/internal/bmc/testmegarac"
)

// pwForMock returns a client authenticated with the mock's
// initial credentials and unlocks the password gate (so the
// VirtualMedia / Boot endpoints — which sit behind the gate —
// are reachable).
func pwForMock(t *testing.T) (*Client, *testmegarac.Server) {
	t.Helper()
	open := false
	srv, err := testmegarac.New(testmegarac.Options{StartLocked: &open})
	if err != nil {
		t.Fatalf("testmegarac.New: %v", err)
	}
	t.Cleanup(srv.Close)
	return NewClient(srv.Host, "admin", "admin"), srv
}

func TestListVirtualMedia_DefaultSlots(t *testing.T) {
	c, _ := pwForMock(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	slots, err := c.ListVirtualMedia(ctx)
	if err != nil {
		t.Fatalf("ListVirtualMedia: %v", err)
	}
	if len(slots) != 2 {
		t.Fatalf("expected 2 default slots (CD1+HD1), got %d", len(slots))
	}
	// The mock's slots ship un-inserted with a NotConnected state.
	for _, s := range slots {
		if s.Inserted {
			t.Errorf("slot %s should start un-inserted", s.ID)
		}
		if s.ConnectedVia != "NotConnected" {
			t.Errorf("slot %s: ConnectedVia = %q, want NotConnected", s.ID, s.ConnectedVia)
		}
	}
}

func TestSelectCDSlot_PicksOpticalNotUSB(t *testing.T) {
	c, _ := pwForMock(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cd, err := c.SelectCDSlot(ctx)
	if err != nil {
		t.Fatalf("SelectCDSlot: %v", err)
	}
	if cd.ID != "CD1" {
		t.Errorf("picked %q, want CD1 (the only optical slot)", cd.ID)
	}
	if !cd.IsCD() {
		t.Error("picked slot should report IsCD()==true")
	}
}

func TestInsertEjectMedia_Roundtrip(t *testing.T) {
	c, srv := pwForMock(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	const url = "https://example.com/Arch.iso"
	if err := c.InsertMedia(ctx, "CD1", url, true); err != nil {
		t.Fatalf("InsertMedia: %v", err)
	}

	snap := srv.VirtualMediaSnapshot()
	if snap["CD1"] != url {
		t.Errorf("CD1 image after insert = %q, want %q", snap["CD1"], url)
	}

	// GET should now show the slot inserted with our URL.
	slot, err := c.GetVirtualMediaSlot(ctx, "CD1")
	if err != nil {
		t.Fatalf("GetVirtualMediaSlot: %v", err)
	}
	if !slot.Inserted {
		t.Error("slot.Inserted must be true after InsertMedia")
	}
	if slot.Image != url {
		t.Errorf("slot.Image = %q, want %q", slot.Image, url)
	}
	if slot.ImageName != "Arch.iso" {
		t.Errorf("slot.ImageName = %q, want Arch.iso", slot.ImageName)
	}
	if !slot.WriteProtected {
		t.Error("slot.WriteProtected must be true (we asked for ro)")
	}

	// Now eject and assert the slot is empty again.
	if err := c.EjectMedia(ctx, "CD1"); err != nil {
		t.Fatalf("EjectMedia: %v", err)
	}
	if got := srv.VirtualMediaSnapshot()["CD1"]; got != "" {
		t.Errorf("CD1 image after eject = %q, want empty", got)
	}
}

func TestInsertMedia_RejectsEmptyURL(t *testing.T) {
	c, _ := pwForMock(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := c.InsertMedia(ctx, "CD1", "", true); err == nil {
		t.Fatal("InsertMedia should reject an empty URL on the client side")
	}
}

func TestSetBootOverride_PatchesSystem(t *testing.T) {
	c, srv := pwForMock(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Default state.
	if tgt, en := srv.BootOverride(); tgt != "None" || en != "Disabled" {
		t.Fatalf("initial boot override = (%q,%q), want (None,Disabled)", tgt, en)
	}

	if err := c.SetBootOverride(ctx, BootTargetCD, BootEnabledOnce); err != nil {
		t.Fatalf("SetBootOverride: %v", err)
	}
	if tgt, en := srv.BootOverride(); tgt != "Cd" || en != "Once" {
		t.Errorf("after PATCH: (%q,%q), want (Cd,Once)", tgt, en)
	}
}

func TestSetBootOverride_BadTargetRejected(t *testing.T) {
	// The mock rejects values not in the allow-list with 400. The
	// client's FormatBootTarget guards the typical CLI path, but
	// this test covers the (rare) case of an internal caller
	// passing a bad enum directly. The error must surface as a
	// RedfishError so the user sees what was wrong.
	c, _ := pwForMock(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := c.SetBootOverride(ctx, BootOverrideTarget("Banana"), BootEnabledOnce)
	if err == nil {
		t.Fatal("expected error for invalid boot target")
	}
	if !strings.Contains(err.Error(), "Banana") {
		t.Errorf("error should mention the bad target: %v", err)
	}
}

func TestFormatBootTarget(t *testing.T) {
	cases := []struct {
		in   string
		want BootOverrideTarget
		err  bool
	}{
		{"cd", BootTargetCD, false},
		{"DVD", BootTargetCD, false},
		{"iso", BootTargetCD, false},
		{"pxe", BootTargetPxe, false},
		{"net", BootTargetPxe, false},
		{"disk", BootTargetHDD, false},
		{"hdd", BootTargetHDD, false},
		{"bios", BootTargetBiosSetup, false},
		{"none", BootTargetNone, false},
		{"usb", BootTargetUSB, false},
		{"diags", BootTargetDiags, false},
		{"banana", "", true},
	}
	for _, c := range cases {
		got, err := FormatBootTarget(c.in)
		if (err != nil) != c.err {
			t.Errorf("FormatBootTarget(%q) err=%v, wantErr=%v", c.in, err, c.err)
			continue
		}
		if !c.err && got != c.want {
			t.Errorf("FormatBootTarget(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestPollPowerState_ReturnsImmediatelyIfAlreadyOn(t *testing.T) {
	c, _ := pwForMock(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	got, err := c.PollPowerState(ctx, "On", 50*time.Millisecond)
	if err != nil {
		t.Fatalf("PollPowerState: %v", err)
	}
	if got != "On" {
		t.Errorf("got %q, want On", got)
	}
}

func TestPollPowerState_WaitsUntilTransition(t *testing.T) {
	c, srv := pwForMock(t)
	srv.SetPowerState("Off")

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	// Flip to On after a short delay; the poller should pick it up.
	go func() {
		time.Sleep(150 * time.Millisecond)
		srv.SetPowerState("On")
	}()

	got, err := c.PollPowerState(ctx, "On", 50*time.Millisecond)
	if err != nil {
		t.Fatalf("PollPowerState: %v", err)
	}
	if got != "On" {
		t.Errorf("got %q, want On", got)
	}
}

func TestPollPowerState_HonorsContextCancel(t *testing.T) {
	c, srv := pwForMock(t)
	srv.SetPowerState("Off")

	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()
	_, err := c.PollPowerState(ctx, "On", 50*time.Millisecond)
	if err == nil {
		t.Fatal("PollPowerState must error on context deadline")
	}
	if !strings.Contains(err.Error(), "PowerState=On") {
		t.Errorf("error should mention the target state: %v", err)
	}
}

func TestWaitForInstallComplete_DetectsPowerOff(t *testing.T) {
	c, srv := pwForMock(t)
	srv.SetPowerState("On") // installer running

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	// install.sh halts the box after a moment.
	go func() {
		time.Sleep(120 * time.Millisecond)
		srv.SetPowerState("Off")
	}()

	reason, err := c.WaitForInstallComplete(ctx, 30*time.Millisecond)
	if err != nil {
		t.Fatalf("WaitForInstallComplete: %v", err)
	}
	if !strings.Contains(reason, "powered off") {
		t.Errorf("reason = %q, want it to mention the power-off signal", reason)
	}
}

func TestWaitForInstallComplete_DetectsRebootWhenOffMissed(t *testing.T) {
	c, srv := pwForMock(t)
	// Simulate a board whose power-restore policy keeps PowerState=On
	// throughout: the only observable signal is BootProgress cycling
	// from the live installer (OSRunning) back through a boot state.
	srv.SetPowerState("On")
	srv.SetBootProgress("OSRunning")

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	go func() {
		time.Sleep(120 * time.Millisecond)
		srv.SetBootProgress("SystemHardwareInitializationComplete")
	}()

	reason, err := c.WaitForInstallComplete(ctx, 30*time.Millisecond)
	if err != nil {
		t.Fatalf("WaitForInstallComplete: %v", err)
	}
	if !strings.Contains(reason, "rebooted") {
		t.Errorf("reason = %q, want it to mention the reboot signal", reason)
	}
}

func TestWaitForInstallComplete_HonorsContextCancel(t *testing.T) {
	c, srv := pwForMock(t)
	// Stays On with no boot-progress change forever — must time out.
	srv.SetPowerState("On")

	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()
	if _, err := c.WaitForInstallComplete(ctx, 40*time.Millisecond); err == nil {
		t.Fatal("WaitForInstallComplete must error on context deadline")
	}
}
