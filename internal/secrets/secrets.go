// Package secrets stores and retrieves BMC credentials. The production
// backend shells out to the 1Password CLI (`op`); the in-memory backend
// is used by tests so the suite never touches the user's real vault.
//
// All backends speak the same Backend interface — the bmc package and
// the bmcctl CLI take a Backend, never a concrete type, so swapping in
// a fake during tests is a one-line change.
package secrets

// Vault is the minimum we need from a 1Password vault listing: its
// UUID and human name. Either string can be used to refer to the
// vault when calling other Backend methods.
type Vault struct {
	ID   string
	Name string
}

// Backend is the contract for any credentials store. Implementations
// must be safe to call from a single goroutine; the package does not
// guarantee concurrency.
type Backend interface {
	// Available returns nil if the backend can be reached (e.g. the
	// `op` binary is on PATH, or — for Memory — always nil).
	Available() error

	// CheckSignedIn confirms the backend is in a usable state, e.g.
	// the 1Password session is unlocked. Memory always returns nil.
	CheckSignedIn() error

	// ListVaults returns every vault the signed-in account can see.
	// Used to validate --vault arguments before we do anything
	// destructive, and to give the user a helpful "did you mean ...?"
	// listing on mismatch.
	ListVaults() ([]Vault, error)

	// ResolveVault looks up a vault by ID or name (case-insensitive)
	// and returns its full record. Returns an error whose message
	// lists available vaults if the lookup fails, so the caller can
	// surface it directly to the user.
	ResolveVault(nameOrID string) (Vault, error)

	// CreateBMCItem stores a new BMC credential. The returned string
	// is an opaque reference — for 1Password it's the item UUID; for
	// Memory it's a synthesised slug. Callers should persist this
	// reference so subsequent operations can find the item.
	CreateBMCItem(vault, title, host, username, password string, tags []string) (ref string, err error)

	// UpdateBMCPassword replaces the password on an existing item
	// identified by ref. URL/title/tags are not touched.
	UpdateBMCPassword(ref, password string) error

	// GetBMCPassword returns the password stored against ref. vault is
	// the item's 1Password vault (ID or name); it may be empty for
	// interactive sessions but is REQUIRED when `op` runs as a service
	// account, which refuses `op item get <uuid>` without a vault.
	GetBMCPassword(vault, ref string) (string, error)

	// FindBMCItem locates an item by title (case-insensitive) within
	// the given vault. Empty string is returned (no error) when not
	// found. Used by `bmcctl rotate` when the local config has lost
	// the UUID but the user still has the item in 1Password.
	FindBMCItem(vault, title string) (string, error)
}

// Default returns the backend used by the bmcctl CLI in production: a
// fresh OnePassword instance. Tests should construct their own Memory
// backend explicitly.
func Default() Backend { return OnePassword{} }
