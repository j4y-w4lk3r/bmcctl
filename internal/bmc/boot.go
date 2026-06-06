// Boot override: the Redfish mechanism for telling the host's BIOS
// "boot from CD next time" without permanently rewriting the BIOS
// boot order.
//
//	GET   /redfish/v1/Systems/Self
//	      -> { Boot: { BootSourceOverrideTarget, BootSourceOverrideEnabled,
//	                   BootSourceOverrideMode } }
//	PATCH /redfish/v1/Systems/Self  (with If-Match ETag)
//	      body: { "Boot": { "BootSourceOverrideTarget": "Cd",
//	                        "BootSourceOverrideEnabled": "Once" } }
//
// AMI MegaRAC enforces the same ETag/If-Match dance here as on the
// AccountService PATCH (we hit the same 428 PreconditionRequired
// without it). So the implementation mirrors SetPassword: GET first
// to capture the ETag, then PATCH it back in If-Match.
//
// PollPowerState sits in this file because it's the natural counterpart
// to SetBootOverride for orchestrators like `install-arch` that need
// to "set boot=cd, power on, wait for the host to actually be On".

package bmc

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
)

// BootOverrideTarget is the Redfish enum we PATCH onto Systems/Self.
// Aliased to a named string type so the compiler catches typos at the
// CLI/orchestrator boundary.
type BootOverrideTarget string

const (
	BootTargetNone      BootOverrideTarget = "None"
	BootTargetPxe       BootOverrideTarget = "Pxe"
	BootTargetCD        BootOverrideTarget = "Cd"
	BootTargetHDD       BootOverrideTarget = "Hdd"
	BootTargetBiosSetup BootOverrideTarget = "BiosSetup"
	BootTargetUSB       BootOverrideTarget = "Usb"
	BootTargetDiags     BootOverrideTarget = "Diags"
)

// BootOverrideEnabled is the lifetime of the override. "Once" reverts
// after the next boot — what we always want for install-arch. "Continuous"
// is sticky across reboots (rare, used for PXE-imaging a fleet).
type BootOverrideEnabled string

const (
	BootEnabledDisabled   BootOverrideEnabled = "Disabled"
	BootEnabledOnce       BootOverrideEnabled = "Once"
	BootEnabledContinuous BootOverrideEnabled = "Continuous"
)

// FormatBootTarget normalizes friendly user input ("cd", "pxe",
// "disk", "bios"...) into the Redfish-canonical enum.
func FormatBootTarget(s string) (BootOverrideTarget, error) {
	switch strings.ToLower(s) {
	case "none", "off":
		return BootTargetNone, nil
	case "pxe", "net", "network":
		return BootTargetPxe, nil
	case "cd", "dvd", "iso", "optical":
		return BootTargetCD, nil
	case "hdd", "disk", "harddisk":
		return BootTargetHDD, nil
	case "bios", "biossetup", "setup":
		return BootTargetBiosSetup, nil
	case "usb":
		return BootTargetUSB, nil
	case "diags", "diag", "diagnostics":
		return BootTargetDiags, nil
	}
	return "", fmt.Errorf("unknown boot target %q (valid: none|pxe|cd|disk|bios|usb|diags)", s)
}

// SetBootOverride PATCHes Systems/Self with the requested override.
// The ETag dance matches SetPassword's: GET to capture, PATCH with
// If-Match. Falls back to "*" if the GET returns no ETag (older
// MegaRAC builds).
//
// AMI MegaRAC quirk: newer firmware (W680D4U-2L2T/G5 v6.01.0) returns
// Ami.1.0.OperationSupportedInFutureStateURI on direct Systems/Self
// PATCH and instead exposes Boot at the Settings ("future state")
// resource at /Systems/Self/SD. We try /SD first when the system
// resource advertises a Settings link, and fall back to the direct
// path on older firmware that still accepts it.
func (c *Client) SetBootOverride(ctx context.Context, target BootOverrideTarget, enabled BootOverrideEnabled) error {
	primary := "/redfish/v1/Systems/Self"
	settings := "/redfish/v1/Systems/Self/SD"

	if err := c.patchBoot(ctx, settings, target, enabled); err == nil {
		return nil
	} else if !isFutureStateRedirect(err) && !isResourceMissing(err) {
		return err
	}
	return c.patchBoot(ctx, primary, target, enabled)
}

// patchBoot is the inner ETag GET + PATCH pair for the Boot subset
// of a ComputerSystem (or its Settings sibling). Always pins
// BootSourceOverrideMode to "UEFI" — without it, AMI MegaRAC inherits
// whatever the firmware NVRAM had last set (often "Legacy"), and the
// override silently no-ops once the on-disk system gains a UEFI
// bootloader because the BIOS prefers UEFI entries over Legacy
// overrides in mixed-mode builds. Reinstalls onto a previously-imaged
// disk all stop working in that case (host just reboots into the old
// install with the override quietly cleared to "Disabled").
func (c *Client) patchBoot(ctx context.Context, path string, target BootOverrideTarget, enabled BootOverrideEnabled) error {
	var doc map[string]any
	status, headers, errBody, err := c.doFull(ctx, "GET", path, nil, nil, &doc)
	if err != nil {
		return fmt.Errorf("ETag GET %s: %w", path, err)
	}
	if status >= 300 {
		return parseRedfishError(status, errBody)
	}
	etag := headers.Get("ETag")
	if etag == "" {
		if v, ok := doc["@odata.etag"].(string); ok {
			etag = v
		}
	}
	if etag == "" {
		etag = "*"
	}

	bootBody := map[string]any{
		"BootSourceOverrideTarget":  string(target),
		"BootSourceOverrideEnabled": string(enabled),
	}
	// Only pin Mode for actual boot redirects; clearing the override
	// (target=None) shouldn't perturb the firmware's persistent Mode.
	if target != BootTargetNone {
		bootBody["BootSourceOverrideMode"] = "UEFI"
	}
	body := map[string]any{"Boot": bootBody}
	status, _, errBody, err = c.doFull(ctx, "PATCH", path, body,
		map[string]string{"If-Match": etag}, nil)
	if err != nil {
		return err
	}
	if status >= 300 {
		return parseRedfishError(status, errBody)
	}
	return nil
}

func isFutureStateRedirect(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(err.Error(), "OperationSupportedInFutureStateURI")
}

func isResourceMissing(err error) bool {
	if err == nil {
		return false
	}
	var re *RedfishError
	if errors.As(err, &re) && re.Status == 404 {
		return true
	}
	s := err.Error()
	return strings.Contains(s, "ResourceMissingAtURI") ||
		strings.Contains(s, "ResourceNotFound")
}

// PollPowerState repeatedly GETs /Systems/Self.PowerState every
// `interval` until it equals `want` or the context is cancelled.
// Returns the final state on success, or the ctx error on timeout.
//
// Used by install-arch to wait for the host to come up after a
// power-on, and to wait for the post-install reboot to complete.
func (c *Client) PollPowerState(ctx context.Context, want string, interval time.Duration) (string, error) {
	if interval <= 0 {
		interval = 5 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()

	// Sample once up front so a request that's already in the
	// desired state returns immediately.
	sys, err := c.GetSystem(ctx)
	if err == nil && strings.EqualFold(sys.PowerState, want) {
		return sys.PowerState, nil
	}
	for {
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("waiting for PowerState=%s: %w", want, ctx.Err())
		case <-t.C:
			sys, err := c.GetSystem(ctx)
			if err != nil {
				// Transient errors are common during reboot
				// (BMC briefly drops the host link). Don't
				// fail the whole poll — just try again.
				continue
			}
			if strings.EqualFold(sys.PowerState, want) {
				return sys.PowerState, nil
			}
		}
	}
}

// WaitForInstallComplete blocks until the unattended installer signals
// it is done, then returns a short human-readable reason.
//
// The installer ends with `systemctl poweroff`, so the canonical signal
// is the host going On->Off. But that signal is fragile: on boards whose
// power-restore policy is "Always On" / "Last State", the BMC bounces the
// host back On within a second or two of the OS halting — fast enough that
// a slow PowerState poll steps right over the brief Off and then waits
// forever (this is the "missed-Off race" that left an installer ISO + boot
// override stuck on a host). To be robust we watch two independent signals
// and succeed on whichever lands first:
//
//   - PowerState == Off            (clean halt, observed in time)
//   - BootProgress leaves OSRunning (the live installer) for a fresh boot
//     cycle — proof the box halted and rebooted into the installed disk,
//     even when the Off itself was never observable.
//
// Callers must have already confirmed the host is On (installer running)
// before calling this. `interval` should be short (a couple of seconds) so
// a brief Off is actually caught; <=0 defaults to 2s.
func (c *Client) WaitForInstallComplete(ctx context.Context, interval time.Duration) (string, error) {
	if interval <= 0 {
		interval = 2 * time.Second
	}
	t := time.NewTicker(interval)
	defer t.Stop()

	// sawOSRunning gates the reboot signal: we only treat a departure
	// from OSRunning as "rebooted after install" once we've actually
	// seen the live installer reach OSRunning. That avoids a false
	// positive from early boot states the live env may pass through.
	sawOSRunning := false
	check := func(sys *SystemInfo) (string, bool) {
		if strings.EqualFold(sys.PowerState, "Off") {
			return "host powered off — install.sh ran `systemctl poweroff`", true
		}
		ls := sys.BootProgress.LastState
		switch {
		case strings.EqualFold(ls, "OSRunning"):
			sawOSRunning = true
		case sawOSRunning && ls != "":
			return fmt.Sprintf("host rebooted (BootProgress=%s) — install halted and the board bounced it back On", ls), true
		}
		return "", false
	}

	// Sample once up front: the install may have finished between the
	// power-on confirmation and this call.
	if sys, err := c.GetSystem(ctx); err == nil {
		if reason, done := check(sys); done {
			return reason, nil
		}
	}
	for {
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("waiting for install to complete: %w", ctx.Err())
		case <-t.C:
			sys, err := c.GetSystem(ctx)
			if err != nil {
				// Host link commonly drops mid-reboot; keep polling.
				continue
			}
			if reason, done := check(sys); done {
				return reason, nil
			}
		}
	}
}
