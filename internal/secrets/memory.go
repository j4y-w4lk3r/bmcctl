package secrets

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
)

// Memory is an in-memory Backend used by tests. It never touches the
// 1Password CLI and is safe to use without network access. It is also
// the only Backend that lets tests *inspect* what was stored — see
// PasswordOf and Snapshot.
type Memory struct {
	mu     sync.Mutex
	items  map[string]*memItem
	vaults []Vault
}

type memItem struct {
	UUID     string
	Vault    string
	Title    string
	Host     string
	Username string
	Password string
	Tags     []string
}

// NewMemory returns a freshly constructed in-memory backend with a
// single default vault named "Private". Tests that need a different
// set should call SetVaults.
func NewMemory() *Memory {
	return &Memory{
		items: map[string]*memItem{},
		vaults: []Vault{
			{ID: "mem-vault-private", Name: "Private"},
		},
	}
}

var _ Backend = (*Memory)(nil)

func (m *Memory) Available() error     { return nil }
func (m *Memory) CheckSignedIn() error { return nil }

// SetVaults replaces the in-memory vault list. Test-only helper.
func (m *Memory) SetVaults(vaults []Vault) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.vaults = append([]Vault(nil), vaults...)
}

func (m *Memory) ListVaults() ([]Vault, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]Vault(nil), m.vaults...), nil
}

func (m *Memory) ResolveVault(nameOrID string) (Vault, error) {
	if nameOrID == "" {
		return Vault{}, errors.New("--vault is required")
	}
	m.mu.Lock()
	vaults := append([]Vault(nil), m.vaults...)
	m.mu.Unlock()
	for _, v := range vaults {
		if v.ID == nameOrID || strings.EqualFold(v.Name, nameOrID) {
			return v, nil
		}
	}
	return Vault{}, fmt.Errorf("memory: vault %q not found (have %v)", nameOrID, vaults)
}

func (m *Memory) CreateBMCItem(vault, title, host, username, password string, tags []string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if vault == "" {
		vault = "Private"
	}
	uuid := randUUID()
	m.items[uuid] = &memItem{
		UUID: uuid, Vault: vault, Title: title, Host: host,
		Username: username, Password: password, Tags: append([]string(nil), tags...),
	}
	return uuid, nil
}

func (m *Memory) UpdateBMCPassword(ref, password string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	item := m.lookupLocked(ref)
	if item == nil {
		return fmt.Errorf("memory: item %q not found", ref)
	}
	item.Password = password
	return nil
}

func (m *Memory) GetBMCPassword(_ /*vault*/, ref string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	item := m.lookupLocked(ref)
	if item == nil {
		return "", fmt.Errorf("memory: item %q not found", ref)
	}
	return item.Password, nil
}

func (m *Memory) FindBMCItem(vault, title string) (string, error) {
	if title == "" {
		return "", errors.New("memory: empty title")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, it := range m.items {
		if vault != "" && it.Vault != vault {
			continue
		}
		if strings.EqualFold(it.Title, title) {
			return it.UUID, nil
		}
	}
	return "", nil
}

// lookupLocked resolves either a UUID or a title (case-insensitive).
func (m *Memory) lookupLocked(ref string) *memItem {
	if it, ok := m.items[ref]; ok {
		return it
	}
	for _, it := range m.items {
		if strings.EqualFold(it.Title, ref) {
			return it
		}
	}
	return nil
}

// PasswordOf returns the password stored under the given UUID or title.
// Returns "" when not found. Test-only helper; not part of Backend.
func (m *Memory) PasswordOf(ref string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	if it := m.lookupLocked(ref); it != nil {
		return it.Password
	}
	return ""
}

// Snapshot returns a copy of every item currently in the backend, in no
// particular order. Useful for table-driven assertions in tests.
func (m *Memory) Snapshot() []memItem {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]memItem, 0, len(m.items))
	for _, it := range m.items {
		out = append(out, *it)
	}
	return out
}

// Len returns the number of items stored.
func (m *Memory) Len() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.items)
}

func randUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("memory: crypto/rand: " + err.Error())
	}
	return hex.EncodeToString(b[:])
}
