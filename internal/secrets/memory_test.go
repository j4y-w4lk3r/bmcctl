package secrets

import (
	"strings"
	"testing"
)

// TestMemory_Lifecycle covers the basic Backend contract: create →
// read → update → read. The Memory backend should be a faithful drop-
// in for OnePassword from the test's point of view.
func TestMemory_Lifecycle(t *testing.T) {
	m := NewMemory()
	if err := m.Available(); err != nil {
		t.Errorf("Available should always be nil: %v", err)
	}
	if err := m.CheckSignedIn(); err != nil {
		t.Errorf("CheckSignedIn should always be nil: %v", err)
	}

	ref, err := m.CreateBMCItem("Private", "BMC – router", "10.0.0.1", "admin", "p@ss", []string{"bmc"})
	if err != nil {
		t.Fatal(err)
	}
	if ref == "" {
		t.Fatal("empty ref from CreateBMCItem")
	}
	if got, _ := m.GetBMCPassword(ref); got != "p@ss" {
		t.Errorf("initial password = %q, want p@ss", got)
	}

	if err := m.UpdateBMCPassword(ref, "newer-pw"); err != nil {
		t.Fatal(err)
	}
	if got, _ := m.GetBMCPassword(ref); got != "newer-pw" {
		t.Errorf("after update = %q, want newer-pw", got)
	}

	// Lookup by title (case-insensitive).
	got, err := m.FindBMCItem("Private", "bmc – router")
	if err != nil || got != ref {
		t.Errorf("FindBMCItem returned (%q, %v), want (%q, nil)", got, err, ref)
	}

	// Wrong vault → not found.
	got, _ = m.FindBMCItem("OtherVault", "BMC – router")
	if got != "" {
		t.Errorf("FindBMCItem with wrong vault returned %q, want empty", got)
	}
}

// TestMemory_NotFound checks the error paths.
func TestMemory_NotFound(t *testing.T) {
	m := NewMemory()
	if _, err := m.GetBMCPassword("bogus"); err == nil {
		t.Error("GetBMCPassword(bogus) should error")
	}
	if err := m.UpdateBMCPassword("bogus", "x"); err == nil {
		t.Error("UpdateBMCPassword(bogus) should error")
	}
}

// TestMemory_Vaults covers the vault discovery surface that lets
// cmdInit validate --vault before touching the BMC.
func TestMemory_Vaults(t *testing.T) {
	m := NewMemory()

	// Default vault is "Private" — same as OnePassword's default.
	v, err := m.ListVaults()
	if err != nil {
		t.Fatal(err)
	}
	if len(v) != 1 || v[0].Name != "Private" {
		t.Errorf("default ListVaults = %+v, want [{Private, ...}]", v)
	}

	// Resolve by exact name, case-insensitive name, and ID.
	got, err := m.ResolveVault("Private")
	if err != nil || got.Name != "Private" {
		t.Errorf("by name: (%+v, %v)", got, err)
	}
	got, err = m.ResolveVault("private")
	if err != nil || got.Name != "Private" {
		t.Errorf("by lowercase name: (%+v, %v)", got, err)
	}
	got, err = m.ResolveVault("mem-vault-private")
	if err != nil || got.ID != "mem-vault-private" {
		t.Errorf("by ID: (%+v, %v)", got, err)
	}

	// Missing vault should surface the available list in the error.
	m.SetVaults([]Vault{
		{ID: "id-personal", Name: "Personal"},
		{ID: "id-servers", Name: "Servers"},
	})
	_, err = m.ResolveVault("Private")
	if err == nil {
		t.Fatal("ResolveVault should fail when vault missing")
	}
	if !strings.Contains(err.Error(), "Personal") || !strings.Contains(err.Error(), "Servers") {
		t.Errorf("error should list available vaults, got %v", err)
	}

	// CreateBMCItem still works using the vault's ID.
	if _, err := m.CreateBMCItem("id-personal", "BMC – x", "10.0.0.1", "admin", "p", nil); err != nil {
		t.Errorf("CreateBMCItem by ID: %v", err)
	}
}

// TestMemory_Snapshot exposes the testing-only helpers.
func TestMemory_Snapshot(t *testing.T) {
	m := NewMemory()
	_, _ = m.CreateBMCItem("V1", "a", "h1", "admin", "p1", nil)
	_, _ = m.CreateBMCItem("V2", "b", "h2", "admin", "p2", nil)
	if m.Len() != 2 {
		t.Errorf("Len = %d, want 2", m.Len())
	}
	snap := m.Snapshot()
	if len(snap) != 2 {
		t.Errorf("Snapshot length = %d, want 2", len(snap))
	}
}
