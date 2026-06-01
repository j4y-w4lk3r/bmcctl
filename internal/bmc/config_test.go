package bmc

import (
	"path/filepath"
	"testing"
	"time"
)

// withTempConfig redirects the bmcctl config file into t.TempDir() for
// the duration of the test by setting BMCCTL_CONFIG. Saves us from
// stomping on the user's real ~/.config/bmcctl/hosts.json.
func withTempConfig(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "hosts.json")
	t.Setenv("BMCCTL_CONFIG", path)
	return path
}

// TestConfig_RoundTrip verifies that what we save loads back identical,
// and that a missing file returns an empty Config without error.
func TestConfig_RoundTrip(t *testing.T) {
	path := withTempConfig(t)

	loaded, gotPath, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig on missing file: %v", err)
	}
	if gotPath != path {
		t.Errorf("path = %q, want %q", gotPath, path)
	}
	if len(loaded.Hosts) != 0 {
		t.Errorf("expected empty Hosts, got %d", len(loaded.Hosts))
	}

	cfg := &Config{}
	entry := HostEntry{
		Label:      "router",
		Host:       "192.168.1.54",
		MAC:        "9C:6B:00:CF:4B:BD",
		BoardModel: "ASRockRack W680D4U-2L2T/G5",
		HostModel:  "i5-13500",
		OpItemUUID: "abc123",
		OpVault:    "Private",
		Username:   "admin",
		AccountID:  "4",
	}
	cfg.Upsert(entry)
	if _, err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	reloaded, _, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig after save: %v", err)
	}
	if len(reloaded.Hosts) != 1 {
		t.Fatalf("expected 1 host, got %d", len(reloaded.Hosts))
	}
	got := reloaded.Hosts[0]
	if got.Label != "router" || got.Host != "192.168.1.54" || got.OpItemUUID != "abc123" {
		t.Errorf("round-trip mismatch: %+v", got)
	}
	if got.InitializedAt.IsZero() || got.UpdatedAt.IsZero() {
		t.Errorf("timestamps should be set: %+v", got)
	}
}

// TestConfig_Find checks both label-based (case-insensitive) and
// host-based lookup.
func TestConfig_Find(t *testing.T) {
	cfg := &Config{Hosts: []HostEntry{
		{Label: "router", Host: "192.168.1.54", OpItemUUID: "a"},
		{Label: "nas", Host: "192.168.1.55", OpItemUUID: "b"},
	}}

	cases := []struct {
		key      string
		wantUUID string
	}{
		{"router", "a"},
		{"ROUTER", "a"}, // case-insensitive label
		{"Router", "a"},
		{"192.168.1.54", "a"},
		{"nas", "b"},
		{"192.168.1.55", "b"},
		{"missing", ""},
	}
	for _, c := range cases {
		got := cfg.Find(c.key)
		if c.wantUUID == "" {
			if got != nil {
				t.Errorf("Find(%q) = %+v, want nil", c.key, got)
			}
			continue
		}
		if got == nil {
			t.Errorf("Find(%q) = nil, want UUID %q", c.key, c.wantUUID)
			continue
		}
		if got.OpItemUUID != c.wantUUID {
			t.Errorf("Find(%q).UUID = %q, want %q", c.key, got.OpItemUUID, c.wantUUID)
		}
	}
}

// TestConfig_Upsert checks that updating an existing host preserves
// InitializedAt while bumping UpdatedAt, and that appending a new host
// stamps both.
func TestConfig_Upsert(t *testing.T) {
	cfg := &Config{}
	first := cfg.Upsert(HostEntry{Label: "router", Host: "192.168.1.54", OpItemUUID: "v1"})
	initAt := first.InitializedAt
	if initAt.IsZero() {
		t.Fatalf("InitializedAt should be set on first upsert")
	}

	// Make sure the second upsert has a *later* UpdatedAt timestamp.
	time.Sleep(2 * time.Millisecond)

	second := cfg.Upsert(HostEntry{Label: "router", Host: "192.168.1.54", OpItemUUID: "v2"})
	if second.InitializedAt != initAt {
		t.Errorf("InitializedAt should be preserved on update: was %v, now %v", initAt, second.InitializedAt)
	}
	if !second.UpdatedAt.After(initAt) {
		t.Errorf("UpdatedAt should be later than InitializedAt: %v vs %v", second.UpdatedAt, initAt)
	}
	if second.OpItemUUID != "v2" {
		t.Errorf("Upsert should overwrite mutable fields: got %q", second.OpItemUUID)
	}
	if len(cfg.Hosts) != 1 {
		t.Errorf("expected 1 host, got %d", len(cfg.Hosts))
	}

	// Adding a different host appends instead of replacing.
	cfg.Upsert(HostEntry{Label: "nas", Host: "192.168.1.55"})
	if len(cfg.Hosts) != 2 {
		t.Errorf("expected 2 hosts after second upsert, got %d", len(cfg.Hosts))
	}
}

// TestConfig_Remove deletes by label or host and reports success/fail.
func TestConfig_Remove(t *testing.T) {
	cfg := &Config{Hosts: []HostEntry{
		{Label: "router", Host: "192.168.1.54"},
		{Label: "nas", Host: "192.168.1.55"},
	}}
	if !cfg.Remove("ROUTER") {
		t.Error("Remove(\"ROUTER\") returned false")
	}
	if len(cfg.Hosts) != 1 || cfg.Hosts[0].Label != "nas" {
		t.Errorf("unexpected hosts after remove: %+v", cfg.Hosts)
	}
	if cfg.Remove("missing") {
		t.Error("Remove(\"missing\") returned true")
	}
	if !cfg.Remove("192.168.1.55") {
		t.Error("Remove by host returned false")
	}
	if len(cfg.Hosts) != 0 {
		t.Errorf("expected empty hosts, got %+v", cfg.Hosts)
	}
}
