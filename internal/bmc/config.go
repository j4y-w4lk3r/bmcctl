package bmc

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// HostEntry is one BMC known to the user's local config. None of these
// fields are secret — the password lives in 1Password and is looked up
// via OpItemUUID.
type HostEntry struct {
	Label         string    `json:"label"` // human-friendly name, e.g. "router" or "nas"
	Host          string    `json:"host"`  // IP or DNS
	MAC           string    `json:"mac,omitempty"`
	BoardModel    string    `json:"board_model,omitempty"`
	HostModel     string    `json:"host_model,omitempty"`
	OpItemUUID    string    `json:"op_item_uuid"` // 1Password item UUID
	OpVault       string    `json:"op_vault,omitempty"`
	Username      string    `json:"username"`             // BMC username, usually "admin"
	AccountID     string    `json:"account_id,omitempty"` // Redfish account ID (default "4")
	InitializedAt time.Time `json:"initialized_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// Config is the on-disk registry of BMCs the user has set up. We never
// write a password into it. Stored at ~/.config/bmcctl/hosts.json.
type Config struct {
	Hosts []HostEntry `json:"hosts"`
}

func defaultConfigPath() (string, error) {
	if env := os.Getenv("BMCCTL_CONFIG"); env != "" {
		return env, nil
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "bmcctl", "hosts.json"), nil
}

// LoadConfig reads ~/.config/bmcctl/hosts.json (or $BMCCTL_CONFIG).
// Missing file returns an empty config, not an error.
func LoadConfig() (*Config, string, error) {
	path, err := defaultConfigPath()
	if err != nil {
		return nil, "", err
	}
	buf, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return &Config{}, path, nil
	}
	if err != nil {
		return nil, path, err
	}
	var c Config
	if err := json.Unmarshal(buf, &c); err != nil {
		return nil, path, fmt.Errorf("parse %s: %w", path, err)
	}
	return &c, path, nil
}

// SaveConfig writes the config atomically (write+rename). The parent
// directory is created with 0o700.
func SaveConfig(c *Config) (string, error) {
	path, err := defaultConfigPath()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}
	buf, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return "", err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, buf, 0o600); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, path); err != nil {
		return "", err
	}
	return path, nil
}

// Find returns the entry matching `nameOrHost` by label or IP. Case-
// insensitive on label.
func (c *Config) Find(nameOrHost string) *HostEntry {
	for i := range c.Hosts {
		if strings.EqualFold(c.Hosts[i].Label, nameOrHost) || c.Hosts[i].Host == nameOrHost {
			return &c.Hosts[i]
		}
	}
	return nil
}

// Upsert replaces an existing entry (matched by host) or appends a new
// one. Returns the stored entry for chaining.
func (c *Config) Upsert(e HostEntry) *HostEntry {
	now := time.Now().UTC()
	e.UpdatedAt = now
	for i := range c.Hosts {
		if c.Hosts[i].Host == e.Host {
			if e.InitializedAt.IsZero() {
				e.InitializedAt = c.Hosts[i].InitializedAt
			}
			c.Hosts[i] = e
			return &c.Hosts[i]
		}
	}
	if e.InitializedAt.IsZero() {
		e.InitializedAt = now
	}
	c.Hosts = append(c.Hosts, e)
	return &c.Hosts[len(c.Hosts)-1]
}

// Remove deletes the entry for nameOrHost. Returns true if removed.
func (c *Config) Remove(nameOrHost string) bool {
	for i := range c.Hosts {
		if strings.EqualFold(c.Hosts[i].Label, nameOrHost) || c.Hosts[i].Host == nameOrHost {
			c.Hosts = append(c.Hosts[:i], c.Hosts[i+1:]...)
			return true
		}
	}
	return false
}
