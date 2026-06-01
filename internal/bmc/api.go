package bmc

import (
	"context"
	"fmt"
	"strings"
)

// ServiceRoot is the bare minimum we need from /redfish/v1/.
type ServiceRoot struct {
	RedfishVersion string `json:"RedfishVersion"`
	UUID           string `json:"UUID"`
	Product        string `json:"Product"`
}

// SystemInfo flattens the bits we care about from /Systems/Self.
type SystemInfo struct {
	Manufacturer string `json:"Manufacturer"`
	Model        string `json:"Model"`
	SKU          string `json:"SKU"`
	SerialNumber string `json:"SerialNumber"`
	PartNumber   string `json:"PartNumber"`
	HostName     string `json:"HostName"`
	BiosVersion  string `json:"BiosVersion"`
	PowerState   string `json:"PowerState"`
	UUID         string `json:"UUID"`
	Status       struct {
		Health string `json:"Health"`
		State  string `json:"State"`
	} `json:"Status"`
	ProcessorSummary struct {
		Count int    `json:"Count"`
		Model string `json:"Model"`
	} `json:"ProcessorSummary"`
	MemorySummary struct {
		TotalSystemMemoryGiB int `json:"TotalSystemMemoryGiB"`
		Status               struct {
			Health string `json:"Health"`
		} `json:"Status"`
	} `json:"MemorySummary"`
}

// ChassisInfo from /Chassis/Self — board manufacturer/model/serial.
type ChassisInfo struct {
	Manufacturer string `json:"Manufacturer"`
	Model        string `json:"Model"`
	SKU          string `json:"SKU"`
	SerialNumber string `json:"SerialNumber"`
	PartNumber   string `json:"PartNumber"`
	ChassisType  string `json:"ChassisType"`
	PowerState   string `json:"PowerState"`
}

// AccountServiceInfo flattens the bits of /redfish/v1/AccountService
// we use to size generated passwords. AMI MegaRAC on the W680D4U
// caps MaxPasswordLength at 20 chars; other firmwares vary.
type AccountServiceInfo struct {
	MinPasswordLength int `json:"MinPasswordLength"`
	MaxPasswordLength int `json:"MaxPasswordLength"`
}

// GetAccountService reads /redfish/v1/AccountService. We use it to
// discover the BMC's password-length constraints before generating
// a password — submitting one that's too long gets us a useless
// "PropertyValueFormatError" with the actual value redacted.
func (c *Client) GetAccountService(ctx context.Context) (*AccountServiceInfo, error) {
	var out AccountServiceInfo
	status, body, err := c.do(ctx, "GET", "/redfish/v1/AccountService", nil, &out)
	if err != nil {
		return nil, err
	}
	if status >= 300 {
		return nil, parseRedfishError(status, body)
	}
	return &out, nil
}

// ManagerInfo from /Managers/Self — info about the BMC itself.
type ManagerInfo struct {
	Manufacturer    string `json:"Manufacturer"`
	Model           string `json:"Model"`
	FirmwareVersion string `json:"FirmwareVersion"`
	DateTime        string `json:"DateTime"`
	UUID            string `json:"UUID"`
}

// GetServiceRoot reads /redfish/v1/. This is unauthenticated and is a
// cheap way to confirm the host speaks Redfish.
func (c *Client) GetServiceRoot(ctx context.Context) (*ServiceRoot, error) {
	var out ServiceRoot
	status, body, err := c.do(ctx, "GET", "/redfish/v1/", nil, &out)
	if err != nil {
		return nil, err
	}
	if status >= 300 {
		return nil, parseRedfishError(status, body)
	}
	return &out, nil
}

// GetSystem reads /redfish/v1/Systems/Self.
func (c *Client) GetSystem(ctx context.Context) (*SystemInfo, error) {
	var out SystemInfo
	status, body, err := c.do(ctx, "GET", "/redfish/v1/Systems/Self", nil, &out)
	if err != nil {
		return nil, err
	}
	if status >= 300 {
		return nil, parseRedfishError(status, body)
	}
	return &out, nil
}

// GetChassis reads /redfish/v1/Chassis/Self.
func (c *Client) GetChassis(ctx context.Context) (*ChassisInfo, error) {
	var out ChassisInfo
	status, body, err := c.do(ctx, "GET", "/redfish/v1/Chassis/Self", nil, &out)
	if err != nil {
		return nil, err
	}
	if status >= 300 {
		return nil, parseRedfishError(status, body)
	}
	return &out, nil
}

// GetManager reads /redfish/v1/Managers/Self.
func (c *Client) GetManager(ctx context.Context) (*ManagerInfo, error) {
	var out ManagerInfo
	status, body, err := c.do(ctx, "GET", "/redfish/v1/Managers/Self", nil, &out)
	if err != nil {
		return nil, err
	}
	if status >= 300 {
		return nil, parseRedfishError(status, body)
	}
	return &out, nil
}

// SetPassword changes the password for the BMC account at
// /redfish/v1/AccountService/Accounts/<id>. On AMI MegaRAC the default
// admin user is usually account ID "4" but we accept any.
//
// AMI MegaRAC enforces Redfish's "lost update" protection: a PATCH
// must carry an If-Match header containing the resource's current
// ETag. Without it the server returns HTTP 428 PreconditionRequired
// (Ami.1.0.PreconditionHeaderMissing). So we do a two-step dance:
//
//  1. GET  /AccountService/Accounts/<id>   — capture the ETag
//  2. PATCH /AccountService/Accounts/<id>  — send it back in If-Match
//
// If the GET doesn't return an ETag (older firmware, broken impl) we
// fall back to "*" which means "match any version" — accepted by every
// MegaRAC build I've seen, and equivalent to the original ETag-less
// PATCH attempt for those that don't enforce the precondition.
func (c *Client) SetPassword(ctx context.Context, accountID, newPassword string) error {
	if accountID == "" {
		accountID = "4"
	}
	path := "/redfish/v1/AccountService/Accounts/" + accountID

	// 1. GET to obtain the ETag. Some MegaRAC builds also embed the
	//    same value as `@odata.etag` in the JSON body, so we look in
	//    both places.
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

	// 2. PATCH carrying the ETag in If-Match.
	body := map[string]string{"Password": newPassword}
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

// Power performs a power action on the host. Valid actions match the
// Redfish ResetType enum: On, ForceOff, GracefulShutdown, ForceRestart,
// PowerCycle, Nmi, GracefulRestart.
func (c *Client) Power(ctx context.Context, action string) error {
	body := map[string]string{"ResetType": action}
	status, errBody, err := c.do(ctx, "POST",
		"/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset", body, nil)
	if err != nil {
		return err
	}
	if status >= 300 {
		return parseRedfishError(status, errBody)
	}
	return nil
}

// Sensors is the flattened thermal+power telemetry for the dashboard.
type Sensors struct {
	Temperatures []TemperatureReading
	Fans         []FanReading
}

type TemperatureReading struct {
	Name           string  `json:"Name"`
	ReadingCelsius float64 `json:"ReadingCelsius"`
	UpperCritical  float64 `json:"UpperThresholdCritical"`
}

type FanReading struct {
	Name    string  `json:"Name"`
	Reading float64 `json:"Reading"`
	Units   string  `json:"ReadingUnits"`
}

// GetSensors reads /Chassis/Self/Thermal.
func (c *Client) GetSensors(ctx context.Context) (*Sensors, error) {
	var out struct {
		Temperatures []TemperatureReading `json:"Temperatures"`
		Fans         []FanReading         `json:"Fans"`
	}
	status, body, err := c.do(ctx, "GET", "/redfish/v1/Chassis/Self/Thermal", nil, &out)
	if err != nil {
		return nil, err
	}
	if status >= 300 {
		return nil, parseRedfishError(status, body)
	}
	return &Sensors{Temperatures: out.Temperatures, Fans: out.Fans}, nil
}

// FormatPower normalizes the friendly action names a user types on the
// CLI into the canonical Redfish ResetType values.
func FormatPower(action string) (string, error) {
	switch strings.ToLower(action) {
	case "on":
		return "On", nil
	case "off", "force-off", "forceoff":
		return "ForceOff", nil
	case "graceful", "shutdown", "graceful-shutdown":
		return "GracefulShutdown", nil
	case "cycle", "power-cycle":
		return "PowerCycle", nil
	case "reset", "restart", "force-restart":
		return "ForceRestart", nil
	case "graceful-restart":
		return "GracefulRestart", nil
	case "nmi":
		return "Nmi", nil
	}
	return "", fmt.Errorf("unknown power action %q (valid: on|off|graceful|cycle|reset|graceful-restart|nmi)", action)
}
