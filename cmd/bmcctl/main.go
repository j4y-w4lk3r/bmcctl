// bmcctl manages AMI MegaRAC BMCs (the firmware ASRock Rack ships on
// the W680D4U-2L2T/G5 and friends). Subcommands:
//
//	bmcctl discover [--cidr 192.168.1.0/24]
//	    Scan a CIDR and list every host whose TLS cert says MEGARAC.
//
//	bmcctl init <host> --label NAME [--vault Private] [--length 20] [--force]
//	    Generate a strong password, PATCH it into account "4",
//	    verify by re-auth, and store in 1Password. Bails out if the
//	    BMC is already past its first-login wall, unless --force.
//
//	    The default length is 20 because that's the AMI MegaRAC cap
//	    on the W680D4U-2L2T/G5. If the BMC advertises a longer max
//	    via /AccountService, we honour it; if it advertises a shorter
//	    one, we clamp down and warn rather than letting AMI reject.
//
//	bmcctl adopt <host> --label NAME --vault VAULT [--user admin]
//	    Register an already-configured BMC. Reads the existing
//	    password from stdin, verifies it works, then stores it in
//	    1Password and writes the local registry entry. Use this
//	    when `bmcctl init` got partway and failed (e.g. saved the
//	    password to the wrong vault), or when the BMC was set up
//	    outside bmcctl.
//
//	      echo 'thePassword' | bmcctl adopt 192.168.1.54 \
//	          --label bmc-54 --vault Personal
//
//	bmcctl rotate <host|label> [--length 20]
//	    Generate a new password, set it on the BMC, update the
//	    existing 1Password item.
//
//	bmcctl info  <host|label>      System + chassis + manager summary
//	bmcctl power <host|label> <on|off|cycle|reset|graceful|status>
//	bmcctl fru   <host|label>      ipmitool fru print 0
//	bmcctl mc    <host|label>      ipmitool mc info
//	bmcctl sensors <host|label>    /Chassis/Self/Thermal
//	bmcctl ls                      list BMCs known to local config
//	bmcctl kvm   <host|label>      open https://host/#/kvm in browser
//
//	bmcctl mount-iso  <host|label> --url URL [--slot CD1] [--no-write-protect]
//	    Mount an ISO over Redfish VirtualMedia. The URL must be
//	    reachable from the BMC (HTTPS with public CA, or plain HTTP).
//	bmcctl eject-iso  <host|label> [--slot CD1]
//	    Detach whatever is currently in the slot.
//	bmcctl boot       <host|label> <target> [--continuous]
//	    Set a one-shot (default) or continuous boot override. Targets:
//	    none, pxe, cd, disk, bios, usb, diags.
//	bmcctl install-arch <host|label> --iso URL [--wait MIN] [--no-wait]
//	    Orchestrate eject -> mount-iso -> boot=cd-once -> power-cycle ->
//	    poll PowerState until the host comes up. With --no-wait we
//	    return as soon as the cycle command lands.
//
// Local config: ~/.config/bmcctl/hosts.json (non-secret).
// Secrets: 1Password, accessed via the `op` CLI on demand.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/j4y-w4lk3r/bmcctl/internal/bmc"
	"github.com/j4y-w4lk3r/bmcctl/internal/secrets"
)

// store is the credentials backend used by all subcommands. It's a
// package-level variable so tests can swap it for secrets.Memory; in
// production it stays as the 1Password backend.
var store secrets.Backend = secrets.Default()

// Version metadata stamped at link time by goreleaser via -ldflags.
// Local `go build` leaves them at the "dev" defaults so a developer
// running ./bmcctl from a source tree gets a clear "this is not a
// release build" signal rather than a misleading version number.
var (
	version = "dev"
	commit  = "none"
	date    = "unknown"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	sub := os.Args[1]
	args := os.Args[2:]

	var err error
	switch sub {
	case "discover":
		err = cmdDiscover(args)
	case "init":
		err = cmdInit(args)
	case "adopt":
		err = cmdAdopt(args)
	case "rotate":
		err = cmdRotate(args)
	case "info":
		err = cmdInfo(args)
	case "power":
		err = cmdPower(args)
	case "fru":
		err = cmdIpmi(args, "fru", "print", "0")
	case "mc":
		err = cmdIpmi(args, "mc", "info")
	case "sensors":
		err = cmdSensors(args)
	case "ls":
		err = cmdLs(args)
	case "kvm":
		err = cmdKVM(args)
	case "mount-iso":
		err = cmdMountISO(args)
	case "eject-iso":
		err = cmdEjectISO(args)
	case "boot":
		err = cmdBoot(args)
	case "install-arch":
		err = cmdInstallArch(args)
	case "-v", "--version", "version":
		fmt.Printf("bmcctl %s (commit %s, built %s)\n", version, commit, date)
		return
	case "-h", "--help", "help":
		usage()
		return
	default:
		fmt.Fprintf(os.Stderr, "bmcctl: unknown subcommand %q\n\n", sub)
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "bmcctl %s: %v\n", sub, err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `bmcctl — manage AMI MegaRAC BMCs (ASRock Rack W680D4U-2L2T/G5 etc.)

USAGE
  bmcctl discover [--cidr 192.168.1.0/24]
  bmcctl init  <host>          --label NAME [--vault VAULT] [--length 20] [--force]
  bmcctl adopt <host>          --label NAME [--vault VAULT]   # password from stdin
  bmcctl rotate <host|label>                [--length 20]
  bmcctl info   <host|label>
  bmcctl power  <host|label> <on|off|graceful|cycle|reset|status>
  bmcctl fru    <host|label>
  bmcctl mc     <host|label>
  bmcctl sensors <host|label>
  bmcctl ls
  bmcctl kvm    <host|label>

  bmcctl mount-iso    <host|label> --url URL [--slot CD1] [--no-write-protect]
  bmcctl eject-iso    <host|label> [--slot CD1]
  bmcctl boot         <host|label> <none|pxe|cd|disk|bios|usb|diags> [--continuous]
  bmcctl install-arch <host|label> --iso URL [--wait MIN] [--no-wait]

  bmcctl -v / --version
  bmcctl -h / --help

Local registry:  ~/.config/bmcctl/hosts.json
Secrets:         1Password via the 'op' CLI (must be installed and signed in)
`)
}

// ----- discover -----

func cmdDiscover(args []string) error {
	fs := flag.NewFlagSet("discover", flag.ContinueOnError)
	cidr := fs.String("cidr", "192.168.1.0/24", "CIDR to scan")
	if err := fs.Parse(args); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	fmt.Printf("Scanning %s for AMI MegaRAC BMCs...\n", *cidr)
	res, err := bmc.DiscoverCIDR(ctx, *cidr)
	if err != nil {
		return err
	}
	if len(res) == 0 {
		fmt.Println("No BMCs found.")
		return nil
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "HOST\tCERT SUBJECT")
	for _, r := range res {
		fmt.Fprintf(w, "%s\t%s\n", r.Host, r.CertSubject)
	}
	w.Flush()
	return nil
}

// parseInterspersed parses `args` against `fs` allowing flags and
// positionals to appear in any order. Go's stdlib `flag` stops at the
// first non-flag token, which makes `init <host> --label NAME` fail
// silently (--label is treated as a positional). This helper fixes
// that without pulling in a third-party flag library.
//
// We use fs.Lookup to know which flags take a value vs which are
// booleans, so `--force <positional>` doesn't eat the positional.
func parseInterspersed(fs *flag.FlagSet, args []string) (positional []string, err error) {
	var flagsOnly []string
	i := 0
	for i < len(args) {
		a := args[i]
		if a == "--" {
			positional = append(positional, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(a, "-") {
			positional = append(positional, a)
			i++
			continue
		}
		flagsOnly = append(flagsOnly, a)
		// `--name=value` is self-contained; `--name value` needs us
		// to grab the next token (unless the flag is a bool).
		if !strings.Contains(a, "=") {
			name := strings.TrimLeft(a, "-")
			f := fs.Lookup(name)
			takesValue := f != nil
			if bf, ok := f.Value.(interface{ IsBoolFlag() bool }); ok && bf.IsBoolFlag() {
				takesValue = false
			}
			if takesValue && i+1 < len(args) {
				i++
				flagsOnly = append(flagsOnly, args[i])
			}
		}
		i++
	}
	if err := fs.Parse(flagsOnly); err != nil {
		return nil, err
	}
	return positional, nil
}

// clampPasswordLength asks the BMC for its MinPasswordLength /
// MaxPasswordLength and reconciles them with what the user requested.
//
// Returns the length we should actually use, plus an optional warning
// line for the caller to print. If the BMC's policy is unknown (the
// GET fails for whatever reason) we fall back to the user's value;
// the BMC will then either accept it or surface a real error from
// SetPassword, which is no worse than today.
//
// We refuse to silently grow a request below the policy minimum —
// that would generate a weak password without the user noticing.
func clampPasswordLength(ctx context.Context, c *bmc.Client, requested int) (int, string, error) {
	const fallbackMax = 20 // AMI MegaRAC default on the W680D4U.
	const safetyMin = 8    // every Redfish impl requires >= 8.

	acct, err := c.GetAccountService(ctx)
	if err != nil {
		// Couldn't query — fall back to a conservative cap so a
		// user asking for 40 doesn't crash on AMI hardware that
		// silently caps at 20.
		if requested > fallbackMax {
			return fallbackMax, fmt.Sprintf(
				"⚠ AccountService unreachable (%v); capping at %d (AMI default)",
				err, fallbackMax), nil
		}
		return requested, "", nil
	}
	min := acct.MinPasswordLength
	max := acct.MaxPasswordLength
	if min == 0 {
		min = safetyMin
	}
	if max == 0 {
		max = fallbackMax
	}
	if requested < min {
		return 0, "", fmt.Errorf(
			"--length %d is below the BMC's minimum (%d); ask for at least that many",
			requested, min)
	}
	if requested > max {
		return max, fmt.Sprintf(
			"⚠ BMC advertises MaxPasswordLength=%d; capping --length %d to %d",
			max, requested, max), nil
	}
	return requested, "", nil
}

// ----- init -----

func cmdInit(args []string) error {
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	label := fs.String("label", "", "friendly label, e.g. \"router\" or \"nas\"")
	vault := fs.String("vault", "Private", "1Password vault name")
	length := fs.Int("length", 20, "generated password length (min 12)")
	username := fs.String("user", "admin", "BMC username")
	accountID := fs.String("account", "4", "Redfish account ID (AMI MegaRAC default = 4)")
	force := fs.Bool("force", false, "PATCH even if admin/admin no longer works")
	yes := fs.Bool("yes", false, "skip confirmation prompt")
	positional, err := parseInterspersed(fs, args)
	if err != nil {
		return err
	}
	if len(positional) < 1 {
		return errors.New("usage: bmcctl init <host> --label NAME")
	}
	host := positional[0]
	if *label == "" {
		return errors.New("--label is required")
	}

	if err := store.Available(); err != nil {
		return err
	}
	if err := store.CheckSignedIn(); err != nil {
		return err
	}

	// Validate the vault BEFORE we touch the BMC. If we don't, a
	// typo in --vault leaves us with a BMC whose password we just
	// changed and no record of it. Better to fail fast.
	resolvedVault, err := store.ResolveVault(*vault)
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	tmpClient := bmc.NewClient(host, "admin", "admin")
	if err := tmpClient.VerifyMegaRAC(ctx); err != nil {
		return fmt.Errorf("safety check failed: %w", err)
	}

	// Step 1: probe with default creds. The "PasswordChangeRequired"
	// error is expected on a factory-fresh BMC and means we're in the
	// right state to do the PATCH.
	_, probeErr := tmpClient.GetSystem(ctx)
	defaultStillWorks := probeErr == nil || bmc.IsPasswordChangeRequired(probeErr)
	if !defaultStillWorks && !*force {
		return fmt.Errorf(
			"refusing to PATCH: admin/admin no longer works on %s "+
				"(BMC may already be configured). "+
				"Use `bmcctl adopt` to register an already-configured BMC, "+
				"or re-run with --force if you really want to overwrite.",
			host)
	}

	// Reconcile requested length with the BMC's actual policy.
	// We do this *before* the confirmation prompt so the user sees
	// the real number they're about to generate.
	pwLen, warn, err := clampPasswordLength(ctx, tmpClient, *length)
	if err != nil {
		return err
	}
	if warn != "" {
		fmt.Fprintln(os.Stderr, warn)
	}

	if !*yes {
		fmt.Printf("About to:\n")
		fmt.Printf("  1. generate a %d-char password\n", pwLen)
		fmt.Printf("  2. PATCH https://%s/redfish/v1/AccountService/Accounts/%s\n", host, *accountID)
		fmt.Printf("  3. store in 1Password vault %q (%s) as %q\n",
			resolvedVault.Name, resolvedVault.ID, "BMC – "+*label)
		fmt.Printf("Proceed? [y/N] ")
		var answer string
		fmt.Fscanln(os.Stdin, &answer)
		if !strings.EqualFold(answer, "y") && !strings.EqualFold(answer, "yes") {
			return errors.New("aborted")
		}
	}

	pw, err := bmc.GeneratePassword(pwLen)
	if err != nil {
		return err
	}

	if err := tmpClient.SetPassword(ctx, *accountID, pw); err != nil {
		return fmt.Errorf("PATCH password: %w", err)
	}
	fmt.Println("✓ password set on BMC")

	// Step 2: verify by re-authenticating with the new password.
	verify := bmc.NewClient(host, *username, pw)
	if _, err := verify.GetServiceRoot(ctx); err != nil {
		// New password isn't working — print it so the user can
		// rescue the situation manually.
		fmt.Fprintf(os.Stderr,
			"⚠ verification failed: %v\n"+
				"   To recover, the password we generated was:\n"+
				"     %s\n"+
				"   Save it NOW; we will not store it in 1Password since we can't confirm it.\n",
			err, pw)
		return errors.New("aborting: new password did not verify")
	}
	if _, err := verify.GetSystem(ctx); err != nil && bmc.IsPasswordChangeRequired(err) {
		// Still gated — would mean the PATCH didn't actually change
		// the password. Shouldn't happen, but be defensive.
		fmt.Fprintf(os.Stderr, "⚠ BMC still demands a password change. Generated password: %s\n", pw)
		return errors.New("password change did not take effect")
	}
	fmt.Println("✓ re-authenticated with new password")

	// Step 3: stash in 1Password. Use the *resolved* vault ID so
	// `op` can't trip on a case mismatch or name-vs-id ambiguity.
	title := fmt.Sprintf("BMC – %s", *label)
	tags := []string{"bmc", "asrock-rack", "megarac"}
	uuid, err := store.CreateBMCItem(resolvedVault.ID, title, host, *username, pw, tags)
	if err != nil {
		fmt.Fprintf(os.Stderr,
			"⚠ 1Password save failed: %v\n"+
				"   The password we set was:\n"+
				"     %s\n"+
				"   Save it in your password manager NOW.\n",
			err, pw)
		return errors.New("aborting: could not save to 1Password")
	}
	fmt.Printf("✓ saved to 1Password (item %s)\n", uuid)

	// Step 4: pull system inventory so we know which board this is.
	sys, _ := verify.GetSystem(ctx)
	chs, _ := verify.GetChassis(ctx)
	mgr, _ := verify.GetManager(ctx)

	cfg, _, err := bmc.LoadConfig()
	if err != nil {
		return err
	}
	entry := bmc.HostEntry{
		Label:      *label,
		Host:       host,
		OpItemUUID: uuid,
		OpVault:    resolvedVault.ID,
		Username:   *username,
		AccountID:  *accountID,
	}
	if chs != nil {
		entry.BoardModel = strings.TrimSpace(chs.Manufacturer + " " + chs.Model)
	}
	if sys != nil && sys.Model != "" {
		entry.HostModel = sys.Model
	}
	cfg.Upsert(entry)
	cfgPath, err := bmc.SaveConfig(cfg)
	if err != nil {
		return err
	}
	fmt.Printf("✓ wrote %s\n", cfgPath)

	fmt.Println()
	fmt.Println("─── inventory ───")
	if sys != nil {
		fmt.Printf("  System.Manufacturer = %s\n", sys.Manufacturer)
		fmt.Printf("  System.Model        = %s\n", sys.Model)
		fmt.Printf("  System.SKU          = %s\n", sys.SKU)
		fmt.Printf("  System.SerialNumber = %s\n", sys.SerialNumber)
		fmt.Printf("  System.BiosVersion  = %s\n", sys.BiosVersion)
		fmt.Printf("  System.PowerState   = %s\n", sys.PowerState)
	}
	if chs != nil {
		fmt.Printf("  Chassis.Model       = %s\n", chs.Model)
		fmt.Printf("  Chassis.SKU         = %s\n", chs.SKU)
	}
	if mgr != nil {
		fmt.Printf("  BMC.FirmwareVersion = %s\n", mgr.FirmwareVersion)
	}
	return nil
}

// ----- adopt -----

// cmdAdopt is the recovery path for "I already changed the password
// but never managed to save it in 1Password" — e.g. when `init` got
// halfway and failed on a wrong --vault. It does NOT touch the BMC:
// it reads the existing password from stdin, verifies it works, and
// only then stores the credential and writes the local registry.
func cmdAdopt(args []string) error {
	fs := flag.NewFlagSet("adopt", flag.ContinueOnError)
	label := fs.String("label", "", "friendly label, e.g. \"router\" or \"nas\"")
	vault := fs.String("vault", "Private", "1Password vault name or ID")
	username := fs.String("user", "admin", "BMC username")
	accountID := fs.String("account", "4", "Redfish account ID (AMI MegaRAC default = 4)")
	positional, err := parseInterspersed(fs, args)
	if err != nil {
		return err
	}
	if len(positional) < 1 {
		return errors.New("usage: bmcctl adopt <host> --label NAME [--vault VAULT] (password on stdin)")
	}
	host := positional[0]
	if *label == "" {
		return errors.New("--label is required")
	}

	if err := store.Available(); err != nil {
		return err
	}
	if err := store.CheckSignedIn(); err != nil {
		return err
	}

	resolvedVault, err := store.ResolveVault(*vault)
	if err != nil {
		return err
	}

	pw, err := readPasswordFromStdin()
	if err != nil {
		return err
	}
	if pw == "" {
		return errors.New("empty password on stdin (pipe one in, e.g. `echo '...' | bmcctl adopt ...`)")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Verify the supplied password actually works on this BMC
	// before we save it. This catches the most common typo
	// (wrong password) and the wrong-host case (right password
	// but pointed at the wrong machine).
	c := bmc.NewClient(host, *username, pw)
	if err := c.VerifyMegaRAC(ctx); err != nil {
		return fmt.Errorf("safety check failed: %w", err)
	}
	if _, err := c.GetServiceRoot(ctx); err != nil {
		return fmt.Errorf("service root with supplied creds: %w", err)
	}
	if _, err := c.GetSystem(ctx); err != nil {
		if bmc.IsPasswordChangeRequired(err) {
			return errors.New(
				"BMC still demands a password change — this isn't an " +
					"adopt scenario. Run `bmcctl init` instead.")
		}
		return fmt.Errorf("authenticated GET /Systems/Self failed: %w", err)
	}
	fmt.Println("✓ supplied password works on", host)

	title := fmt.Sprintf("BMC – %s", *label)
	tags := []string{"bmc", "asrock-rack", "megarac", "adopted"}

	// Idempotency: if an item with this title already exists in
	// the vault (e.g. left over from a previous partial run where
	// `op item create` succeeded but our parser choked), reuse it
	// and just refresh the password. This avoids accumulating
	// duplicate "BMC – bmc-54" entries every time the user retries.
	uuid, findErr := store.FindBMCItem(resolvedVault.ID, title)
	if findErr != nil {
		return fmt.Errorf("1Password search failed: %w", findErr)
	}
	if uuid != "" {
		fmt.Printf("  found existing item %s in vault %q — updating password\n", uuid, resolvedVault.Name)
		if err := store.UpdateBMCPassword(uuid, pw); err != nil {
			return fmt.Errorf("1Password update failed: %w", err)
		}
	} else {
		uuid, err = store.CreateBMCItem(resolvedVault.ID, title, host, *username, pw, tags)
		if err != nil {
			return fmt.Errorf("1Password save failed: %w", err)
		}
	}
	fmt.Printf("✓ saved to 1Password vault %q (item %s)\n", resolvedVault.Name, uuid)

	// Pull inventory for the local registry, same shape as init.
	sys, _ := c.GetSystem(ctx)
	chs, _ := c.GetChassis(ctx)

	cfg, _, err := bmc.LoadConfig()
	if err != nil {
		return err
	}
	entry := bmc.HostEntry{
		Label:      *label,
		Host:       host,
		OpItemUUID: uuid,
		OpVault:    resolvedVault.ID,
		Username:   *username,
		AccountID:  *accountID,
	}
	if chs != nil {
		entry.BoardModel = strings.TrimSpace(chs.Manufacturer + " " + chs.Model)
	}
	if sys != nil && sys.Model != "" {
		entry.HostModel = sys.Model
	}
	cfg.Upsert(entry)
	cfgPath, err := bmc.SaveConfig(cfg)
	if err != nil {
		return err
	}
	fmt.Printf("✓ wrote %s\n", cfgPath)
	return nil
}

// readPasswordFromStdin slurps a single line of password material
// from stdin. We trim the trailing newline that `echo` adds, but
// preserve everything else verbatim — including leading/trailing
// spaces — since AMI passwords can contain anything.
func readPasswordFromStdin() (string, error) {
	buf, err := io.ReadAll(os.Stdin)
	if err != nil {
		return "", fmt.Errorf("read stdin: %w", err)
	}
	s := string(buf)
	s = strings.TrimRight(s, "\r\n")
	return s, nil
}

// ----- rotate -----

func cmdRotate(args []string) error {
	fs := flag.NewFlagSet("rotate", flag.ContinueOnError)
	length := fs.Int("length", 20, "new password length")
	positional, err := parseInterspersed(fs, args)
	if err != nil {
		return err
	}
	if len(positional) < 1 {
		return errors.New("usage: bmcctl rotate <host|label>")
	}
	entry, oldPW, err := resolveAuthed(positional[0])
	if err != nil {
		return err
	}

	if err := store.Available(); err != nil {
		return err
	}
	if err := store.CheckSignedIn(); err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c := bmc.NewClient(entry.Host, entry.Username, oldPW)

	pwLen, warn, err := clampPasswordLength(ctx, c, *length)
	if err != nil {
		return err
	}
	if warn != "" {
		fmt.Fprintln(os.Stderr, warn)
	}
	pw, err := bmc.GeneratePassword(pwLen)
	if err != nil {
		return err
	}

	if err := c.SetPassword(ctx, entry.AccountID, pw); err != nil {
		return err
	}
	verify := bmc.NewClient(entry.Host, entry.Username, pw)
	if _, err := verify.GetServiceRoot(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "⚠ verification failed: %v\n   New password (save it!): %s\n", err, pw)
		return err
	}
	if err := store.UpdateBMCPassword(entry.OpItemUUID, pw); err != nil {
		fmt.Fprintf(os.Stderr, "⚠ 1Password update failed: %v\n   New password: %s\n", err, pw)
		return err
	}
	cfg, _, _ := bmc.LoadConfig()
	cfg.Upsert(*entry)
	_, _ = bmc.SaveConfig(cfg)
	fmt.Printf("✓ rotated password on %s and updated 1Password item %s\n", entry.Host, entry.OpItemUUID)
	return nil
}

// ----- info -----

func cmdInfo(args []string) error {
	if len(args) < 1 {
		return errors.New("usage: bmcctl info <host|label>")
	}
	entry, pw, err := resolveAuthed(args[0])
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	c := bmc.NewClient(entry.Host, entry.Username, pw)

	sys, sysErr := c.GetSystem(ctx)
	chs, chsErr := c.GetChassis(ctx)
	mgr, mgrErr := c.GetManager(ctx)

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintf(w, "HOST\t%s\n", entry.Host)
	fmt.Fprintf(w, "LABEL\t%s\n", entry.Label)
	if sysErr == nil && sys != nil {
		fmt.Fprintf(w, "\nSYSTEM\t\n")
		fmt.Fprintf(w, "  Manufacturer\t%s\n", sys.Manufacturer)
		fmt.Fprintf(w, "  Model\t%s\n", sys.Model)
		fmt.Fprintf(w, "  SKU\t%s\n", sys.SKU)
		fmt.Fprintf(w, "  SerialNumber\t%s\n", sys.SerialNumber)
		fmt.Fprintf(w, "  BiosVersion\t%s\n", sys.BiosVersion)
		fmt.Fprintf(w, "  PowerState\t%s\n", sys.PowerState)
		fmt.Fprintf(w, "  Processor\t%s × %d\n", sys.ProcessorSummary.Model, sys.ProcessorSummary.Count)
		fmt.Fprintf(w, "  MemoryGiB\t%d\n", sys.MemorySummary.TotalSystemMemoryGiB)
		fmt.Fprintf(w, "  Health\t%s (%s)\n", sys.Status.Health, sys.Status.State)
	} else if sysErr != nil {
		fmt.Fprintf(w, "  /Systems\t(error: %v)\n", sysErr)
	}
	if chsErr == nil && chs != nil {
		fmt.Fprintf(w, "\nCHASSIS\t\n")
		fmt.Fprintf(w, "  Model\t%s\n", chs.Model)
		fmt.Fprintf(w, "  SKU\t%s\n", chs.SKU)
		fmt.Fprintf(w, "  ChassisType\t%s\n", chs.ChassisType)
	}
	if mgrErr == nil && mgr != nil {
		fmt.Fprintf(w, "\nBMC\t\n")
		fmt.Fprintf(w, "  Manufacturer\t%s\n", mgr.Manufacturer)
		fmt.Fprintf(w, "  Model\t%s\n", mgr.Model)
		fmt.Fprintf(w, "  FirmwareVersion\t%s\n", mgr.FirmwareVersion)
		fmt.Fprintf(w, "  DateTime\t%s\n", mgr.DateTime)
	}
	w.Flush()
	return nil
}

// ----- power -----

func cmdPower(args []string) error {
	if len(args) < 2 {
		return errors.New("usage: bmcctl power <host|label> <on|off|graceful|cycle|reset|status>")
	}
	entry, pw, err := resolveAuthed(args[0])
	if err != nil {
		return err
	}
	action := args[1]
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	c := bmc.NewClient(entry.Host, entry.Username, pw)

	if strings.EqualFold(action, "status") {
		sys, err := c.GetSystem(ctx)
		if err != nil {
			return err
		}
		fmt.Printf("%s: %s\n", entry.Host, sys.PowerState)
		return nil
	}

	reset, err := bmc.FormatPower(action)
	if err != nil {
		return err
	}
	if err := c.Power(ctx, reset); err != nil {
		return err
	}
	fmt.Printf("✓ %s: %s\n", entry.Host, reset)
	return nil
}

// ----- sensors -----

func cmdSensors(args []string) error {
	if len(args) < 1 {
		return errors.New("usage: bmcctl sensors <host|label>")
	}
	entry, pw, err := resolveAuthed(args[0])
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	c := bmc.NewClient(entry.Host, entry.Username, pw)
	s, err := c.GetSensors(ctx)
	if err != nil {
		return err
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "TEMP\tVALUE\tCRIT")
	for _, t := range s.Temperatures {
		fmt.Fprintf(w, "%s\t%.1f °C\t%.1f °C\n", t.Name, t.ReadingCelsius, t.UpperCritical)
	}
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "FAN\tREADING")
	for _, f := range s.Fans {
		fmt.Fprintf(w, "%s\t%.0f %s\n", f.Name, f.Reading, f.Units)
	}
	w.Flush()
	return nil
}

// ----- ipmi (fru/mc) -----

func cmdIpmi(args []string, ipmiArgs ...string) error {
	if len(args) < 1 {
		return errors.New("usage: bmcctl fru|mc <host|label>")
	}
	entry, pw, err := resolveAuthed(args[0])
	if err != nil {
		return err
	}
	full := []string{"-I", "lanplus", "-H", entry.Host, "-U", entry.Username, "-P", pw, "-C", "17"}
	full = append(full, ipmiArgs...)
	c := exec.Command("ipmitool", full...)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	return c.Run()
}

// ----- ls -----

func cmdLs(_ []string) error {
	cfg, path, err := bmc.LoadConfig()
	if err != nil {
		return err
	}
	if len(cfg.Hosts) == 0 {
		fmt.Printf("(empty — run `bmcctl init` to register a BMC)\n%s\n", path)
		return nil
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "LABEL\tHOST\tBOARD\tHOST MODEL\t1P UUID")
	for _, e := range cfg.Hosts {
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\n",
			e.Label, e.Host, valOrDash(e.BoardModel), valOrDash(e.HostModel), e.OpItemUUID)
	}
	w.Flush()
	return nil
}

// ----- kvm -----

func cmdKVM(args []string) error {
	if len(args) < 1 {
		return errors.New("usage: bmcctl kvm <host|label>")
	}
	cfg, _, _ := bmc.LoadConfig()
	host := args[0]
	if e := cfg.Find(host); e != nil {
		host = e.Host
	}
	url := fmt.Sprintf("https://%s/#/kvm", host)
	fmt.Printf("opening %s\n", url)
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", url).Run()
	case "linux":
		return exec.Command("xdg-open", url).Run()
	default:
		return fmt.Errorf("don't know how to open a browser on %s; URL is %s", runtime.GOOS, url)
	}
}

// resolveAuthed looks up a registered BMC by label/host and fetches its
// password from 1Password. This is the central helper used by every
// authenticated subcommand.
func resolveAuthed(nameOrHost string) (*bmc.HostEntry, string, error) {
	cfg, _, err := bmc.LoadConfig()
	if err != nil {
		return nil, "", err
	}
	entry := cfg.Find(nameOrHost)
	if entry == nil {
		return nil, "", fmt.Errorf("no BMC named %q in config — run `bmcctl init` first or use `bmcctl ls`", nameOrHost)
	}
	if err := store.Available(); err != nil {
		return nil, "", err
	}
	pw, err := store.GetBMCPassword(entry.OpItemUUID)
	if err != nil {
		return nil, "", fmt.Errorf("read 1Password item %s: %w", entry.OpItemUUID, err)
	}
	return entry, pw, nil
}

func valOrDash(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

// ----- mount-iso / eject-iso -----

// cmdMountISO mounts an ISO over Redfish VirtualMedia. The slot
// defaults to whatever the BMC advertises as a CD/DVD-capable slot
// (typically CD1 on AMI MegaRAC). Surface the slot the user actually
// hit so re-mounting / ejection from another shell is unambiguous.
func cmdMountISO(args []string) error {
	fs := flag.NewFlagSet("mount-iso", flag.ContinueOnError)
	url := fs.String("url", "", "HTTP(S) URL of the ISO image (must be reachable from the BMC)")
	slot := fs.String("slot", "", "VirtualMedia slot ID (default: first CD/DVD slot)")
	noWP := fs.Bool("no-write-protect", false, "mount image read-write (rare; default is read-only)")
	positional, err := parseInterspersed(fs, args)
	if err != nil {
		return err
	}
	if len(positional) < 1 {
		return errors.New("usage: bmcctl mount-iso <host|label> --url URL [--slot CD1]")
	}
	if *url == "" {
		return errors.New("--url is required")
	}
	entry, pw, err := resolveAuthed(positional[0])
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c := bmc.NewClient(entry.Host, entry.Username, pw)

	chosen := *slot
	if chosen == "" {
		s, err := c.SelectCDSlot(ctx)
		if err != nil {
			return fmt.Errorf("auto-pick CD slot: %w", err)
		}
		chosen = s.ID
	}
	if err := c.InsertMedia(ctx, chosen, *url, !*noWP); err != nil {
		return fmt.Errorf("InsertMedia %s: %w", chosen, err)
	}
	fmt.Printf("✓ %s: mounted %s into %s%s\n",
		entry.Host, *url, chosen,
		ternary(*noWP, " (read-write)", ""))
	return nil
}

// cmdEjectISO detaches whatever image is currently mounted in the
// slot. If --slot is not given we eject every CD/DVD slot the BMC
// exposes (almost always exactly one — CD1 — but it's cheap and
// makes the command idempotent and forgiving).
func cmdEjectISO(args []string) error {
	fs := flag.NewFlagSet("eject-iso", flag.ContinueOnError)
	slot := fs.String("slot", "", "VirtualMedia slot ID (default: every CD/DVD slot)")
	positional, err := parseInterspersed(fs, args)
	if err != nil {
		return err
	}
	if len(positional) < 1 {
		return errors.New("usage: bmcctl eject-iso <host|label> [--slot CD1]")
	}
	entry, pw, err := resolveAuthed(positional[0])
	if err != nil {
		return err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	c := bmc.NewClient(entry.Host, entry.Username, pw)

	var targets []string
	if *slot != "" {
		targets = []string{*slot}
	} else {
		all, err := c.ListVirtualMedia(ctx)
		if err != nil {
			return fmt.Errorf("list virtual media: %w", err)
		}
		for _, s := range all {
			if s.IsCD() {
				targets = append(targets, s.ID)
			}
		}
		if len(targets) == 0 {
			return errors.New("BMC exposes no CD/DVD VirtualMedia slot to eject")
		}
	}
	for _, id := range targets {
		if err := c.EjectMedia(ctx, id); err != nil {
			return fmt.Errorf("EjectMedia %s: %w", id, err)
		}
		fmt.Printf("✓ %s: ejected %s\n", entry.Host, id)
	}
	return nil
}

func ternary(b bool, yes, no string) string {
	if b {
		return yes
	}
	return no
}

// ----- boot -----

// cmdBoot writes a Redfish BootSourceOverride. Default lifetime is
// "Once" because that's what virtually every operational use case
// wants ("boot from CD once to install, then revert"); --continuous
// is opt-in for fleet imaging via PXE.
func cmdBoot(args []string) error {
	fs := flag.NewFlagSet("boot", flag.ContinueOnError)
	continuous := fs.Bool("continuous", false, "stick across reboots until cleared (default: Once)")
	positional, err := parseInterspersed(fs, args)
	if err != nil {
		return err
	}
	if len(positional) < 2 {
		return errors.New("usage: bmcctl boot <host|label> <none|pxe|cd|disk|bios|usb|diags> [--continuous]")
	}
	entry, pw, err := resolveAuthed(positional[0])
	if err != nil {
		return err
	}
	target, err := bmc.FormatBootTarget(positional[1])
	if err != nil {
		return err
	}

	enabled := bmc.BootEnabledOnce
	if *continuous {
		enabled = bmc.BootEnabledContinuous
	}
	if target == bmc.BootTargetNone {
		// `boot ... none` means "clear the override" — flip the
		// enabled value to Disabled regardless of --continuous so
		// the user has a single muscle-memory move for unwinding.
		enabled = bmc.BootEnabledDisabled
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	c := bmc.NewClient(entry.Host, entry.Username, pw)
	if err := c.SetBootOverride(ctx, target, enabled); err != nil {
		return err
	}
	fmt.Printf("✓ %s: boot override = %s/%s\n", entry.Host, target, enabled)
	return nil
}

// ----- install-arch -----

// cmdInstallArch is the orchestrator that hangs together the previous
// three primitives. Sequence:
//
//  1. Read the current PowerState. The starting state determines
//     which Reset action we issue: Off => On, On => PowerCycle.
//     Real AMI MegaRAC rejects PowerCycle when the host is Off
//     ("InvalidOperation"); we have to use plain On in that case.
//  2. Eject any existing media in every CD slot. Idempotent — a
//     left-over mount from a previous run would otherwise pin the
//     BMC's "ConnectedVia=URI" state and reject InsertMedia.
//  3. Mount the new ISO into the first CD slot.
//  4. PATCH /Systems/Self {Boot:{Cd, Once}} so the very next power-up
//     boots the optical drive.
//  5. Issue the chosen power action (On or PowerCycle).
//  6. Wait for PowerState=On  (POST + GRUB + kernel start).
//  7. Wait for PowerState=Off (install.sh ran `systemctl poweroff`
//     => install completed cleanly). Together with step 6 this is
//     the canonical On->Off transition the README documents as the
//     "install finished" signal.
//
// `--no-wait` short-circuits steps 6+7 for fire-and-forget bring-up.
// `--wait MIN` is the combined budget for both wait phases.
//
// The host coming up to "On" *only* means the BMC sees the host
// drawing power; it does NOT confirm the install ran. For real
// progress signal we will eventually want a `bmcctl install-status`
// that reads SEL or the BMC-recorded console — out of scope for v0.2.0.
func cmdInstallArch(args []string) error {
	fs := flag.NewFlagSet("install-arch", flag.ContinueOnError)
	iso := fs.String("iso", "", "HTTP(S) URL of the Arch installer ISO (must be reachable from the BMC)")
	waitMin := fs.Int("wait", 30, "minutes to wait for PowerState=On after the cycle (use --no-wait to disable)")
	noWait := fs.Bool("no-wait", false, "return as soon as the power-cycle command lands; do not poll PowerState")
	slot := fs.String("slot", "", "VirtualMedia slot ID (default: first CD/DVD slot)")
	positional, err := parseInterspersed(fs, args)
	if err != nil {
		return err
	}
	if len(positional) < 1 {
		return errors.New("usage: bmcctl install-arch <host|label> --iso URL [--wait MIN] [--no-wait]")
	}
	if *iso == "" {
		return errors.New("--iso URL is required")
	}
	entry, pw, err := resolveAuthed(positional[0])
	if err != nil {
		return err
	}

	// Each step gets its own short context; only the final
	// PowerState wait runs against the user-tunable deadline.
	c := bmc.NewClient(entry.Host, entry.Username, pw)

	// Step 1: read the current power state so we know which Reset
	// action to issue. AMI MegaRAC rejects PowerCycle when the host
	// is currently Off, so we branch on initial state.
	probeCtx, cancelP := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancelP()
	sys, err := c.GetSystem(probeCtx)
	if err != nil {
		return fmt.Errorf("read initial PowerState: %w", err)
	}
	initialState := sys.PowerState
	fmt.Printf("→ %s: initial PowerState=%s\n", entry.Host, initialState)

	// Step 2: eject every CD slot to guarantee a clean InsertMedia.
	ejectCtx, cancel1 := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel1()
	all, err := c.ListVirtualMedia(ejectCtx)
	if err != nil {
		return fmt.Errorf("list virtual media: %w", err)
	}
	chosen := *slot
	for _, s := range all {
		if s.IsCD() {
			if chosen == "" {
				chosen = s.ID
			}
			if s.Inserted {
				if err := c.EjectMedia(ejectCtx, s.ID); err != nil {
					return fmt.Errorf("pre-eject %s: %w", s.ID, err)
				}
				fmt.Printf("✓ %s: ejected stale media from %s\n", entry.Host, s.ID)
			}
		}
	}
	if chosen == "" {
		return errors.New("BMC exposes no CD/DVD VirtualMedia slot")
	}

	// Step 3: mount the ISO read-only.
	mountCtx, cancel2 := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel2()
	if err := c.InsertMedia(mountCtx, chosen, *iso, true); err != nil {
		return fmt.Errorf("InsertMedia %s: %w", chosen, err)
	}
	fmt.Printf("✓ %s: mounted %s into %s\n", entry.Host, *iso, chosen)

	// Give the BMC's NFS/HTTPS redirection a moment to actually
	// reach RedirectionStatus="Redirection Started". On AMI, an
	// immediate PowerCycle after InsertMedia can race the BIOS POST
	// against the redirect-not-yet-running state and the BIOS falls
	// through to the next boot entry on the disk.
	time.Sleep(8 * time.Second)

	// Step 4: boot override -> Cd / Continuous (UEFI mode is pinned
	// inside SetBootOverride). Continuous (sticky) instead of Once
	// because AMI's "Once" gets quietly cleared even when the firmware
	// never actually booted from CD — leaves you wondering why the
	// reinstall just rebooted into the existing on-disk system.
	// We clear the override explicitly post-install in the cleanup
	// step (see install-host.sh) so the host boots from disk on its
	// next normal power-on.
	bootCtx, cancel3 := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel3()
	if err := c.SetBootOverride(bootCtx, bmc.BootTargetCD, bmc.BootEnabledContinuous); err != nil {
		return fmt.Errorf("SetBootOverride: %w", err)
	}
	fmt.Printf("✓ %s: boot override = Cd/Continuous (UEFI)\n", entry.Host)

	// Step 5: choose the power action based on the initial state.
	// "Off"  -> "On"          (cold start)
	// "On"   -> "PowerCycle"  (warm cycle, ends in On)
	// other  -> "On"          (assume Off-ish, e.g. "Paused"/"Unknown"
	//                          firmware-isms; "On" is always safe)
	powerAction := "On"
	if strings.EqualFold(initialState, "On") {
		powerAction = "PowerCycle"
	}
	powCtx, cancel4 := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel4()
	if err := c.Power(powCtx, powerAction); err != nil {
		return fmt.Errorf("Power %s: %w", powerAction, err)
	}
	fmt.Printf("✓ %s: %s issued\n", entry.Host, powerAction)

	if *noWait {
		fmt.Printf("→ --no-wait set; not polling. The host should now boot from %s.\n", *iso)
		return nil
	}

	// Step 6 + 7: watch the canonical On->Off transition.
	//
	// Phase 6: wait for PowerState=On (chassis powered, BIOS POSTing
	// or already past it). When initialState was "On" and we did a
	// PowerCycle, the BMC may briefly report Off during the cycle's
	// down phase; we let that go and the next On is what matters.
	//
	// Phase 7: wait for PowerState=Off. install.sh ends with
	// `systemctl poweroff` on success, so On->Off is exactly the
	// "install completed cleanly" signal. On failure install.sh
	// drops to a shell instead of poweroffing — that path stays
	// On and our wait will eventually time out, prompting the
	// operator to attach SOL/KVM and look.
	totalDeadline := time.Now().Add(time.Duration(*waitMin) * time.Minute)

	// Phase 6: cap at 5m or remaining budget, whichever is smaller.
	// 5m is generous for any modern board's POST + GRUB.
	startedDeadline := time.Now().Add(5 * time.Minute)
	if startedDeadline.After(totalDeadline) {
		startedDeadline = totalDeadline
	}
	startedCtx, cancel6 := context.WithDeadline(context.Background(), startedDeadline)
	defer cancel6()
	if strings.EqualFold(initialState, "On") {
		// Give the cycle's down phase a moment to register so we
		// don't immediately match the still-On reading from before
		// the BMC processed PowerCycle.
		select {
		case <-time.After(15 * time.Second):
		case <-startedCtx.Done():
			return fmt.Errorf("waiting for cycle to register: %w", startedCtx.Err())
		}
	}
	fmt.Printf("…  waiting up to %s for PowerState=On (POST + boot)\n",
		time.Until(startedDeadline).Round(time.Second))
	if _, err := c.PollPowerState(startedCtx, "On", 5*time.Second); err != nil {
		return fmt.Errorf("waiting for host to power on: %w", err)
	}
	fmt.Printf("✓ %s: PowerState=On — installer is running\n", entry.Host)

	// Phase 7: rest of the budget for the install itself.
	doneCtx, cancel7 := context.WithDeadline(context.Background(), totalDeadline)
	defer cancel7()
	fmt.Printf("…  waiting up to %s for PowerState=Off (install completion)\n",
		time.Until(totalDeadline).Round(time.Second))
	if _, err := c.PollPowerState(doneCtx, "Off", 10*time.Second); err != nil {
		return fmt.Errorf("waiting for install to complete: %w", err)
	}
	fmt.Printf("✓ %s: PowerState=Off — install completed (install.sh ran systemctl poweroff)\n", entry.Host)
	fmt.Printf("→ next: bmcctl power %s on   (then: ssh %s@<host-ip>)\n",
		entry.Label, entry.Username)
	return nil
}
