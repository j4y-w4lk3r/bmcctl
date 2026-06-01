package secrets

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
)

// OnePassword is the production Backend. It shells out to the `op`
// CLI binary; there is no native API used. Requirements:
//
//   - `op` binary on PATH (Homebrew: `brew install --cask 1password-cli`)
//   - A signed-in session (`op signin` or biometric unlock).
//
// All methods are blocking. If `op` exits non-zero we surface its
// stderr verbatim — its error messages are usually self-explanatory.
type OnePassword struct{}

// compile-time check that OnePassword satisfies Backend.
var _ Backend = OnePassword{}

func (OnePassword) Available() error {
	if _, err := exec.LookPath("op"); err != nil {
		return fmt.Errorf("1Password CLI (op) not found on PATH: %w", err)
	}
	return nil
}

func (OnePassword) CheckSignedIn() error {
	if _, err := runOp("whoami"); err != nil {
		return fmt.Errorf("1Password not signed in (run `op signin` or enable Touch ID): %w", err)
	}
	return nil
}

func (op OnePassword) ListVaults() ([]Vault, error) {
	out, err := runOp("vault", "list", "--format", "json")
	if err != nil {
		return nil, fmt.Errorf("op vault list failed: %w", err)
	}
	var raw []struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
	if err := json.Unmarshal([]byte(out), &raw); err != nil {
		return nil, fmt.Errorf("op vault list: parse JSON: %w", err)
	}
	vaults := make([]Vault, 0, len(raw))
	for _, v := range raw {
		vaults = append(vaults, Vault{ID: v.ID, Name: v.Name})
	}
	return vaults, nil
}

func (op OnePassword) ResolveVault(nameOrID string) (Vault, error) {
	if nameOrID == "" {
		return Vault{}, errors.New("--vault is required")
	}
	vaults, err := op.ListVaults()
	if err != nil {
		return Vault{}, err
	}
	for _, v := range vaults {
		if v.ID == nameOrID || strings.EqualFold(v.Name, nameOrID) {
			return v, nil
		}
	}
	return Vault{}, vaultNotFoundError(nameOrID, vaults)
}

// vaultNotFoundError builds the "didn't find %q; available: ..." error
// that we want users to actually see when they typo their vault name.
func vaultNotFoundError(asked string, available []Vault) error {
	if len(available) == 0 {
		return fmt.Errorf("vault %q not found and `op vault list` returned no vaults — is the session signed in?", asked)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "vault %q not found in this 1Password account.\nAvailable vaults:\n", asked)
	for _, v := range available {
		fmt.Fprintf(&b, "  - %-30s %s\n", v.Name, v.ID)
	}
	fmt.Fprintf(&b, "Re-run with `--vault <name-or-id>` using one of the above.")
	return errors.New(b.String())
}

func (OnePassword) CreateBMCItem(vault, title, host, username, password string, tags []string) (string, error) {
	if vault == "" {
		vault = "Private"
	}
	args := []string{
		"item", "create",
		"--category", "login",
		"--vault", vault,
		"--title", title,
		"--url", fmt.Sprintf("https://%s/", host),
		"username=" + username,
		"password=" + password,
		"--format", "json",
	}
	if len(tags) > 0 {
		args = append(args, "--tags", strings.Join(tags, ","))
	}
	out, err := runOp(args...)
	if err != nil {
		return "", fmt.Errorf("op item create failed: %w", err)
	}
	return parseOpItemID(out)
}

// parseOpItemID pulls the top-level "id" out of `op item create
// --format json`'s output. We use encoding/json rather than string
// scanning so pretty-printed output, the nested vault.id, and any
// other key reordering can't confuse us.
//
// Exposed as a package-private helper so it can be unit-tested
// without shelling out to `op`.
func parseOpItemID(out string) (string, error) {
	var item struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(out), &item); err != nil {
		return "", fmt.Errorf("op item create succeeded but response was not JSON: %w\n--- raw output ---\n%s", err, out)
	}
	if item.ID == "" {
		return "", fmt.Errorf("op item create succeeded but no \"id\" field in response:\n--- raw output ---\n%s", out)
	}
	return item.ID, nil
}

func (OnePassword) UpdateBMCPassword(ref, password string) error {
	if ref == "" {
		return errors.New("UpdateBMCPassword: empty item reference")
	}
	_, err := runOp("item", "edit", ref, "password="+password)
	if err != nil {
		return fmt.Errorf("op item edit failed: %w", err)
	}
	return nil
}

func (OnePassword) GetBMCPassword(ref string) (string, error) {
	if ref == "" {
		return "", errors.New("GetBMCPassword: empty item reference")
	}
	out, err := runOp("item", "get", ref, "--fields", "label=password", "--reveal")
	if err != nil {
		return "", fmt.Errorf("op item get failed: %w", err)
	}
	return strings.TrimSpace(out), nil
}

func (OnePassword) FindBMCItem(vault, title string) (string, error) {
	args := []string{"item", "list", "--categories", "Login", "--format", "json"}
	if vault != "" {
		args = append(args, "--vault", vault)
	}
	out, err := runOp(args...)
	if err != nil {
		return "", err
	}
	return findOpItemByTitle(out, title)
}

// findOpItemByTitle searches `op item list --format json` output for
// an item whose title matches. Exact case-insensitive match wins; if
// nothing exact matches, the first substring match is returned.
//
// Exposed as a package-private helper for tests.
func findOpItemByTitle(out, title string) (string, error) {
	var items []struct {
		ID    string `json:"id"`
		Title string `json:"title"`
	}
	if err := json.Unmarshal([]byte(out), &items); err != nil {
		return "", fmt.Errorf("op item list: parse JSON: %w", err)
	}
	lower := strings.ToLower(title)
	for _, it := range items {
		if strings.EqualFold(it.Title, title) {
			return it.ID, nil
		}
	}
	for _, it := range items {
		if strings.Contains(strings.ToLower(it.Title), lower) {
			return it.ID, nil
		}
	}
	return "", nil
}

// runOp runs the `op` binary, returning stdout. The CLI prints user-
// facing errors on stderr; we attach those to the returned error.
func runOp(args ...string) (string, error) {
	cmd := exec.Command("op", args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return "", fmt.Errorf("%s", msg)
	}
	return stdout.String(), nil
}
