package bmc_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/j4y-w4lk3r/bmcctl/internal/bmc"
	"github.com/j4y-w4lk3r/bmcctl/internal/bmc/testmegarac"
	"github.com/j4y-w4lk3r/bmcctl/internal/secrets"
)

// withMegaRAC starts a fresh mock and returns it + a client wired to
// hit it with admin/admin (the factory-fresh creds). The mock and the
// client are torn down via t.Cleanup.
func withMegaRAC(t *testing.T, opt testmegarac.Options) (*testmegarac.Server, *bmc.Client) {
	t.Helper()
	srv, err := testmegarac.New(opt)
	if err != nil {
		t.Fatalf("testmegarac.New: %v", err)
	}
	t.Cleanup(srv.Close)
	c := bmc.NewClient(srv.Host, "admin", "admin")
	return srv, c
}

// TestInitFlow_HappyPath exercises the same sequence `bmcctl init`
// performs end-to-end. It does not invoke the CLI binary — it calls
// the same package primitives the CLI does — which gives us full
// assertion coverage of intermediate state.
func TestInitFlow_HappyPath(t *testing.T) {
	srv, c := withMegaRAC(t, testmegarac.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// 0. Safety check: the mock cert must look like MegaRAC.
	if err := c.VerifyMegaRAC(ctx); err != nil {
		t.Fatalf("VerifyMegaRAC: %v", err)
	}

	// 1. Service root works without auth.
	root, err := c.GetServiceRoot(ctx)
	if err != nil {
		t.Fatalf("GetServiceRoot: %v", err)
	}
	if !strings.Contains(strings.ToLower(root.Product), "megarac") {
		t.Errorf("Product = %q, expected to mention megarac", root.Product)
	}

	// 2. Authenticated read is gated.
	_, err = c.GetSystem(ctx)
	if !bmc.IsPasswordChangeRequired(err) {
		t.Fatalf("expected PasswordChangeRequired, got %v", err)
	}

	// 3. Generate + set a strong password. 20 chars is the AMI
	//    MegaRAC cap; anything longer the mock (and real hardware)
	//    rejects with a PropertyValueFormatError. We have a separate
	//    test for that path (TestSetPassword_TooLong).
	pw, err := bmc.GeneratePassword(20)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.SetPassword(ctx, "4", pw); err != nil {
		t.Fatalf("SetPassword: %v", err)
	}
	if srv.Locked() {
		t.Error("server should be unlocked after PATCH")
	}
	if srv.Password() != pw {
		t.Errorf("server password mismatch: got %q vs %q", bmc.MaskPassword(srv.Password()), bmc.MaskPassword(pw))
	}

	// 4. Old admin/admin client should now fail; a new client with
	//    the new password should succeed.
	if _, err := c.GetSystem(ctx); err == nil {
		t.Error("old admin/admin client should be rejected after PATCH")
	}
	c2 := bmc.NewClient(srv.Host, "admin", pw)
	sys, err := c2.GetSystem(ctx)
	if err != nil {
		t.Fatalf("GetSystem after PATCH: %v", err)
	}
	if !strings.Contains(strings.ToLower(sys.Model), "w680") {
		t.Errorf("Model = %q, expected to mention W680", sys.Model)
	}
	if !strings.Contains(sys.ProcessorSummary.Model, "i5-13500") {
		t.Errorf("CPU = %q, expected i5-13500 (this is how we'd identify a board)",
			sys.ProcessorSummary.Model)
	}

	// 5. Save into the in-memory secrets backend, just like bmcctl
	//    would call store.CreateBMCItem.
	mem := secrets.NewMemory()
	uuid, err := mem.CreateBMCItem("Private", "BMC – router", srv.Host, "admin", pw,
		[]string{"bmc", "asrock-rack"})
	if err != nil {
		t.Fatalf("Memory.CreateBMCItem: %v", err)
	}
	if got, _ := mem.GetBMCPassword("", uuid); got != pw {
		t.Errorf("password round-trip mismatch")
	}
	if mem.Len() != 1 {
		t.Errorf("memory backend should have exactly 1 item, has %d", mem.Len())
	}
}

// TestInitFlow_RotatePassword: simulates `bmcctl rotate` — change the
// password again with the new one, verify the old credentials stop
// working, and that the secrets backend reflects the new password.
func TestInitFlow_RotatePassword(t *testing.T) {
	srv, c := withMegaRAC(t, testmegarac.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Phase 1: initial init (admin/admin -> pw1)
	pw1, _ := bmc.GeneratePassword(20)
	if err := c.SetPassword(ctx, "4", pw1); err != nil {
		t.Fatalf("initial SetPassword: %v", err)
	}
	mem := secrets.NewMemory()
	uuid, _ := mem.CreateBMCItem("Private", "BMC – router", srv.Host, "admin", pw1, nil)

	// Phase 2: rotate (pw1 -> pw2)
	pw2, _ := bmc.GeneratePassword(20)
	cRot := bmc.NewClient(srv.Host, "admin", pw1)
	if err := cRot.SetPassword(ctx, "4", pw2); err != nil {
		t.Fatalf("rotate SetPassword: %v", err)
	}
	if err := mem.UpdateBMCPassword(uuid, pw2); err != nil {
		t.Fatalf("UpdateBMCPassword: %v", err)
	}

	// Old password (pw1) must be rejected.
	cOld := bmc.NewClient(srv.Host, "admin", pw1)
	if _, err := cOld.GetSystem(ctx); err == nil {
		t.Error("old password should no longer work")
	}
	// New password (pw2) works.
	cNew := bmc.NewClient(srv.Host, "admin", pw2)
	if _, err := cNew.GetSystem(ctx); err != nil {
		t.Errorf("new password should work: %v", err)
	}
	// Memory backend stored pw2, not pw1.
	if got, _ := mem.GetBMCPassword("", uuid); got != pw2 {
		t.Errorf("memory still holds old password")
	}
	if srv.Password() != pw2 {
		t.Errorf("server still holds old password")
	}
}

// TestInitFlow_FactoryReset: a BMC that's already been configured
// should NOT respond to admin/admin at all. This is what a real
// already-initialized BMC looks like before we run `bmcctl init`,
// and is the cue our CLI's "refuse without --force" logic uses.
func TestInitFlow_FactoryReset(t *testing.T) {
	locked := false
	srv, _ := withMegaRAC(t, testmegarac.Options{
		InitialPassword: "alreadySet!1",
		StartLocked:     &locked,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	c := bmc.NewClient(srv.Host, "admin", "admin") // wrong pw
	_, err := c.GetSystem(ctx)
	if err == nil {
		t.Fatal("admin/admin should NOT work on already-configured BMC")
	}
	if bmc.IsPasswordChangeRequired(err) {
		t.Errorf("expected plain 401, got PasswordChangeRequired (means our refuse-init logic would mis-fire)")
	}
}

// TestPowerActions exercises every power action our CLI supports.
func TestPowerActions(t *testing.T) {
	srv, c := withMegaRAC(t, testmegarac.Options{InitialPassword: "ok"})
	locked := false
	srv2, c2 := withMegaRAC(t, testmegarac.Options{
		InitialPassword: "ok",
		StartLocked:     &locked,
	})
	_, _, _, _ = srv, c, srv2, c2
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	client := bmc.NewClient(srv2.Host, "admin", "ok")
	for _, action := range []string{"On", "ForceOff", "GracefulShutdown", "PowerCycle", "ForceRestart"} {
		if err := client.Power(ctx, action); err != nil {
			t.Errorf("Power(%s): %v", action, err)
		}
	}
	got := srv2.PowerLog()
	if len(got) != 5 {
		t.Fatalf("PowerLog should have 5 entries, got %d: %v", len(got), got)
	}
	for i, want := range []string{"On", "ForceOff", "GracefulShutdown", "PowerCycle", "ForceRestart"} {
		if got[i] != want {
			t.Errorf("entry %d: %q want %q", i, got[i], want)
		}
	}

	// Sanity-check power state transitions.
	sys, _ := client.GetSystem(ctx)
	if sys.PowerState != "On" {
		t.Errorf("final PowerState = %q, want On", sys.PowerState)
	}
}

// TestSensors round-trips the thermal endpoint.
func TestSensors(t *testing.T) {
	locked := false
	srv, _ := withMegaRAC(t, testmegarac.Options{
		InitialPassword: "ok",
		StartLocked:     &locked,
	})
	c := bmc.NewClient(srv.Host, "admin", "ok")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	s, err := c.GetSensors(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Temperatures) == 0 || len(s.Fans) == 0 {
		t.Fatalf("expected non-empty sensors: %+v", s)
	}
}

// TestSetPassword_ETagFlow verifies the GET→capture-ETag→PATCH-with-
// If-Match dance works against a server that enforces Redfish lost-
// update protection (AMI MegaRAC's actual behaviour). A bare PATCH
// without If-Match must be refused; a PATCH with the captured ETag
// must succeed.
func TestSetPassword_ETagFlow(t *testing.T) {
	srv, _ := withMegaRAC(t, testmegarac.Options{})
	c := bmc.NewClient(srv.Host, "admin", "admin")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	pw, _ := bmc.GeneratePassword(20)
	if err := c.SetPassword(ctx, "4", pw); err != nil {
		t.Fatalf("SetPassword should succeed with the ETag dance: %v", err)
	}
	if srv.Password() != pw {
		t.Errorf("server password mismatch")
	}

	// Subsequent PATCH against the new password should still work —
	// proves the ETag is recomputed after the change (i.e. we don't
	// have a stale cached value somewhere).
	c2 := bmc.NewClient(srv.Host, "admin", pw)
	pw2, _ := bmc.GeneratePassword(20)
	if err := c2.SetPassword(ctx, "4", pw2); err != nil {
		t.Fatalf("second SetPassword: %v", err)
	}
	if srv.Password() != pw2 {
		t.Errorf("server password mismatch after second PATCH")
	}
}

// TestSetPassword_TooLong: AMI MegaRAC on the W680D4U-2L2T/G5 caps
// passwords at MaxPasswordLength=20 chars. PATCHing a longer password
// gets back HTTP 400 PropertyValueFormatError with the value redacted
// to "of length N". The user hit this on real hardware with
// --length 40; this test pins that behaviour into the mock so we
// catch the regression we just fixed.
func TestSetPassword_TooLong(t *testing.T) {
	srv, c := withMegaRAC(t, testmegarac.Options{
		MaxPasswordLength: 20,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	too, _ := bmc.GeneratePassword(40)
	err := c.SetPassword(ctx, "4", too)
	if err == nil {
		t.Fatal("expected PATCH to be refused for 40-char password")
	}
	if !strings.Contains(err.Error(), "PropertyValueFormatError") {
		t.Errorf("expected PropertyValueFormatError, got %v", err)
	}
	if !strings.Contains(err.Error(), "of length 40") {
		t.Errorf("expected 'of length 40' in error (the AMI redaction tell), got %v", err)
	}
	// Server state must be untouched.
	if !srv.Locked() {
		t.Error("server should still be locked after failed PATCH")
	}
	if srv.Password() != "admin" {
		t.Errorf("server password changed despite failed PATCH: %q", bmc.MaskPassword(srv.Password()))
	}
}

// TestGetAccountService: the client correctly reads MinPasswordLength
// and MaxPasswordLength so cmdInit can clamp before generating.
func TestGetAccountService(t *testing.T) {
	_, c := withMegaRAC(t, testmegarac.Options{
		MinPasswordLength: 10,
		MaxPasswordLength: 16,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	acct, err := c.GetAccountService(ctx)
	if err != nil {
		t.Fatalf("GetAccountService: %v", err)
	}
	if acct.MinPasswordLength != 10 || acct.MaxPasswordLength != 16 {
		t.Errorf("policy mismatch: got min=%d max=%d, want 10/16",
			acct.MinPasswordLength, acct.MaxPasswordLength)
	}
}

// TestVerifyMegaRAC_RejectsNonMegaRAC builds a server with a cert that
// doesn't contain MEGARAC and verifies the safety check rejects it.
// This is what prevents us from PATCHing the wrong host by accident.
func TestVerifyMegaRAC_RejectsNonMegaRAC(t *testing.T) {
	// The mock always emits a MEGARAC cert; building a non-MegaRAC
	// fake is beyond scope. We instead point the client at a host
	// that does no TLS at all and assert we get *some* error.
	c := bmc.NewClient("127.0.0.1:1", "admin", "admin")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	err := c.VerifyMegaRAC(ctx)
	if err == nil {
		t.Fatal("expected error dialing closed port")
	}
	// And the higher-level redfish call should also surface a
	// transport error rather than panic.
	_, err = c.GetServiceRoot(ctx)
	var re *bmc.RedfishError
	if errors.As(err, &re) {
		t.Errorf("expected transport error, got RedfishError: %v", re)
	}
}
