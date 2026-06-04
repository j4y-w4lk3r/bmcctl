import {
  Stack, Row, Grid, Card, CardHeader, CardBody,
  H1, H2, H3, Text, Code, Link, Pill, Stat, Table, Callout, Divider,
  useHostTheme,
} from "cursor/canvas";

const STATUS = {
  done: { label: "shipped", tone: "added" as const },
  planned: { label: "planned", tone: "info" as const },
  later: { label: "later", tone: "neutral" as const },
};

type FeatureRow = {
  feature: string;
  what: string;
  redfish: string;
  cmd: string;
  status: keyof typeof STATUS;
};

function FeatureTable({ rows }: { rows: FeatureRow[] }) {
  return (
    <Table
      headers={["Dashboard tile", "What it does", "Redfish endpoint", "bmcctl command", "Status"]}
      columnAlign={["left", "left", "left", "left", "left"]}
      rows={rows.map((r) => [
        <Text key="f" weight="semibold">{r.feature}</Text>,
        <Text key="w" tone="secondary" size="small">{r.what}</Text>,
        <Code key="e">{r.redfish}</Code>,
        <Code key="c">{r.cmd}</Code>,
        <Pill key="s" tone={STATUS[r.status].tone} active>{STATUS[r.status].label}</Pill>,
      ])}
    />
  );
}

export default function BmcctlPhase8() {
  const t = useHostTheme();
  return (
    <Stack gap={20} style={{ padding: 24, maxWidth: 1180 }}>
      <Stack gap={6}>
        <H1>bmcctl Phase 8</H1>
        <Text tone="secondary">
          BMC dashboard inventory, glossary, and a phased plan to expose every
          tile through <Code>bmcctl</Code> via the Redfish API.
        </Text>
      </Stack>

      <Grid columns={4} gap={12}>
        <Stat value="13" label="bmcctl commands shipped" tone="success" />
        <Stat value="48" label="dashboard tiles total" />
        <Stat value="2" label="planned next (v0.3)" tone="info" />
        <Stat value="33" label="lower-priority extras" tone="warning" />
      </Grid>

      <Callout tone="info" title="Redfish, not redis">
        ASRock Rack BMCs run AMI MegaRAC firmware, which exposes almost every
        dashboard tile as a Redfish JSON endpoint. <Code>bmcctl</Code> already
        speaks Redfish (see <Code>internal/bmc/api.go</Code>) for power, sensors,
        FRU, info, and password management. Adding new features is mostly
        wiring more endpoints to new subcommands, not new infrastructure.
      </Callout>

      <H2>Vocabulary</H2>
      <Grid columns={2} gap={12}>
        <Card>
          <CardHeader>BMC stack</CardHeader>
          <CardBody>
            <Stack gap={10}>
              <Text><Text weight="semibold">BMC</Text> - Baseboard Management Controller. A small ARM SoC on your motherboard that runs even when the host CPU is off. Lets you power-cycle, monitor sensors, and open a remote console without physical access.</Text>
              <Text><Text weight="semibold">IPMI</Text> - older binary protocol for BMCs. <Code>ipmitool</Code> uses it. <Code>bmcctl mc</Code> and <Code>bmcctl fru</Code> shell out to <Code>ipmitool</Code>.</Text>
              <Text><Text weight="semibold">Redfish</Text> - modern HTTPS+JSON replacement for IPMI. DMTF standard. What <Code>bmcctl</Code> uses for everything else.</Text>
              <Text><Text weight="semibold">AMI MegaRAC</Text> - the BMC firmware that ships on ASRock Rack, Supermicro, Tyan, etc. The web UI you screenshotted is its dashboard.</Text>
            </Stack>
          </CardBody>
        </Card>

        <Card>
          <CardHeader>System info</CardHeader>
          <CardBody>
            <Stack gap={10}>
              <Text><Text weight="semibold">FRU</Text> - Field Replaceable Unit. Manufacturer-burned metadata on each replaceable component (board, chassis, PSU): serial numbers, part numbers, manufacture date. Used for inventory.</Text>
              <Text><Text weight="semibold">SMBIOS</Text> - System Management BIOS. Standard for what the host BIOS exposes about hardware (CPU model, RAM slots, DIMM SKUs). <Code>dmidecode</Code> on Linux reads this.</Text>
              <Text><Text weight="semibold">BSOD</Text> - Blue Screen of Death. Windows crash screen. <Text weight="semibold">Capture BSOD</Text> = the BMC video-captures the screen at the moment of crash so you can see it remotely after the fact.</Text>
              <Text><Text weight="semibold">Watchdog</Text> - timer the BMC arms; if the OS does not pet it within N seconds, the BMC assumes the OS is hung and hard-resets the host.</Text>
            </Stack>
          </CardBody>
        </Card>

        <Card>
          <CardHeader>Remote control</CardHeader>
          <CardBody>
            <Stack gap={10}>
              <Text><Text weight="semibold">KVM-over-IP</Text> - Keyboard / Video / Mouse over IP. Full graphical remote console as if you were sitting at the server.</Text>
              <Text><Text weight="semibold">H5Viewer</Text> - HTML5 KVM client. Runs in any modern browser. No plugins. Use this.</Text>
              <Text><Text weight="semibold">JViewer</Text> - Java applet KVM client (older). Needs a JRE locally. Avoid unless H5Viewer breaks.</Text>
              <Text><Text weight="semibold">Serial Over LAN (SOL)</Text> - redirects the host serial port over the network. Text-only, but invaluable for GRUB, kernel panics, and Linux serial consoles. <Code>ipmitool sol activate</Code>.</Text>
            </Stack>
          </CardBody>
        </Card>

        <Card>
          <CardHeader>Storage and config</CardHeader>
          <CardBody>
            <Stack gap={10}>
              <Text><Text weight="semibold">Media Redirection / Image Redirection</Text> - mount an ISO or USB image to the host as a virtual optical drive. The host BIOS sees a CD-ROM and can boot from it. This is how you remotely install an OS. We will use this for <Code>bmcctl install-arch</Code>.</Text>
              <Text><Text weight="semibold">Remote Images</Text> - the same, but the BMC pulls the image from a network share (NFS / SMB / HTTPS) instead of streaming from your laptop.</Text>
              <Text><Text weight="semibold">PAM Order</Text> - Pluggable Authentication Modules order. Which auth backend the BMC tries first: local accounts, LDAP, RADIUS, AD. Most homelabs leave it on local.</Text>
              <Text><Text weight="semibold">SSL Settings</Text> - the HTTPS cert the BMC web UI presents. Self-signed by default; you can upload a real cert (and a Let's Encrypt one if your BMC is publicly reachable - though you should NOT expose a BMC to the internet).</Text>
            </Stack>
          </CardBody>
        </Card>
      </Grid>

      <H2>How Redfish works</H2>

      <Text tone="secondary">
        DMTF standard for managing servers over HTTPS+JSON. Replaces the old
        binary IPMI protocol. Every BMC vendor that matters (AMI, Supermicro,
        HPE iLO, Dell iDRAC, Lenovo XCC) speaks it. Hosted by the BMC itself
        on its admin IP, port 443.
      </Text>

      <Grid columns={2} gap={16}>
        <Card>
          <CardHeader>1. Service Root</CardHeader>
          <CardBody>
            <Stack gap={8}>
              <Text>Single well-known entry point: <Code>GET /redfish/v1/</Code> (no auth, returns the catalog of top-level collections).</Text>
              <Text size="small" tone="secondary">Response (trimmed):</Text>
              <Code style={{ display: "block", whiteSpace: "pre", padding: 12 }}>{`{
  "Systems":        { "@odata.id": "/redfish/v1/Systems" },
  "Chassis":        { "@odata.id": "/redfish/v1/Chassis" },
  "Managers":       { "@odata.id": "/redfish/v1/Managers" },
  "AccountService": { "@odata.id": "/redfish/v1/AccountService" },
  "UpdateService":  { "@odata.id": "/redfish/v1/UpdateService" },
  "SessionService": { "@odata.id": "/redfish/v1/SessionService" }
}`}</Code>
              <Text size="small" tone="tertiary">Every resource has an <Code>@odata.id</Code> link. The whole tree is HATEOAS — you discover by following links, never by hard-coding paths.</Text>
            </Stack>
          </CardBody>
        </Card>

        <Card>
          <CardHeader>2. Hierarchy you actually care about</CardHeader>
          <CardBody>
            <Stack gap={8}>
              <Text><Code>/Systems/Self</Code> — the host. Power state, boot order, BIOS attributes.</Text>
              <Text><Code>/Chassis/Self</Code> — the box. Sensors (Thermal, Power), LEDs, FRU.</Text>
              <Text><Code>/Managers/Self</Code> — the BMC itself. Firmware version, network, virtual media, time, logs.</Text>
              <Text><Code>/AccountService</Code> — users / passwords. <Code>bmcctl init</Code> writes here.</Text>
              <Text><Code>/UpdateService</Code> — firmware updates (BMC + BIOS).</Text>
              <Text size="small" tone="tertiary"><Code>Self</Code> is convention for "the only one of these". Standalone servers always use it.</Text>
            </Stack>
          </CardBody>
        </Card>

        <Card>
          <CardHeader>3. Verbs</CardHeader>
          <CardBody>
            <Stack gap={6}>
              <Text><Text weight="semibold">GET</Text> read a resource. Free.</Text>
              <Text><Text weight="semibold">PATCH</Text> partially modify. e.g. set boot order, change network config.</Text>
              <Text><Text weight="semibold">POST</Text> create or trigger an action. URL ends in <Code>Actions/&lt;Type&gt;.&lt;Name&gt;</Code>. e.g. power on the host:</Text>
              <Code style={{ display: "block", padding: 8 }}>POST /redfish/v1/Systems/Self/Actions/ComputerSystem.Reset
{"{"} "ResetType": "On" {"}"}</Code>
              <Text><Text weight="semibold">DELETE</Text> remove (sessions, accounts).</Text>
            </Stack>
          </CardBody>
        </Card>

        <Card>
          <CardHeader>4. Auth</CardHeader>
          <CardBody>
            <Stack gap={6}>
              <Text><Text weight="semibold">HTTP Basic</Text> on every call. What <Code>bmcctl</Code> does — fetch the password from 1Password, send <Code>Authorization: Basic &lt;base64&gt;</Code>.</Text>
              <Text><Text weight="semibold">Sessions</Text> POST to <Code>/SessionService/Sessions</Code>, get a token in <Code>X-Auth-Token</Code>, reuse for subsequent calls. Faster for batch operations; <Code>bmcctl</Code> does not bother because each command is one or two calls.</Text>
              <Text size="small" tone="tertiary">Certs are self-signed. <Code>bmcctl</Code> skips TLS verification but only after confirming the cert subject contains <Code>MEGARAC</Code> — so it cannot be tricked into PATCHing a random HTTPS service that happens to bind the same IP.</Text>
            </Stack>
          </CardBody>
        </Card>
      </Grid>

      <H3>End-to-end example: power on with curl</H3>
      <Code style={{ display: "block", padding: 12, whiteSpace: "pre" }}>{`# 1. Read the catalog (no auth needed)
curl -k https://192.168.1.54/redfish/v1/

# 2. Read the host's current power state
curl -k -u admin:PASSWORD https://192.168.1.54/redfish/v1/Systems/Self \\
  | jq .PowerState
# "Off"

# 3. Power it on
curl -k -u admin:PASSWORD -X POST \\
  -H 'Content-Type: application/json' \\
  -d '{"ResetType":"On"}' \\
  https://192.168.1.54/redfish/v1/Systems/Self/Actions/ComputerSystem.Reset

# 4. Verify
curl -k -u admin:PASSWORD https://192.168.1.54/redfish/v1/Systems/Self \\
  | jq .PowerState
# "On"`}</Code>
      <Text size="small" tone="tertiary">
        Everything <Code>bmcctl</Code> does is just a tidier version of the
        above, with credentials pulled from 1Password and the response parsed
        into pretty tables. <Code>internal/bmc/api.go</Code> shows the pattern
        — copying it for new endpoints (mount-iso, boot override, firmware
        info) is mostly mechanical.
      </Text>

      <H3>Why this is the &quot;super-fast path&quot;</H3>
      <Stack gap={6}>
        <Text>Compared to scraping the AMI web UI (HTML forms, CSRF tokens, session cookies, JS-rendered pages), Redfish gives you:</Text>
        <Text>- One auth model that works for every endpoint.</Text>
        <Text>- Stable URLs that do not change between firmware updates (the schema is versioned).</Text>
        <Text>- Vendor-independence: the same <Code>POST .../ComputerSystem.Reset</Code> works on Supermicro, HPE, Dell. You can grow <Code>bmcctl</Code> beyond ASRock Rack by mostly just adjusting the cert-subject safety check.</Text>
        <Text>- Discoverability: every resource lists its links and supported actions, so you can write the next subcommand by following <Code>@odata.id</Code> chains in <Code>curl</Code>, not by reading PDFs.</Text>
      </Stack>

      <Divider />

      <H2>Dashboard tile -&gt; Redfish -&gt; bmcctl: feature map</H2>

      <H3>Power and chassis (where bmcctl shines)</H3>
      <FeatureTable rows={[
        { feature: "Power Control - Power On",        what: "Cold-start the host",                   redfish: "POST /Systems/Self/Actions/ComputerSystem.Reset {On}",            cmd: "bmcctl power LABEL on",       status: "done" },
        { feature: "Power Control - Power Off",       what: "Force-off (yank-the-cord)",             redfish: "POST .../Reset {ForceOff}",                                       cmd: "bmcctl power LABEL off",      status: "done" },
        { feature: "Power Control - ACPI Shutdown",   what: "Polite OS-level shutdown",              redfish: "POST .../Reset {GracefulShutdown}",                               cmd: "bmcctl power LABEL graceful", status: "done" },
        { feature: "Power Control - Power Cycle",     what: "Off then on",                           redfish: "POST .../Reset {PowerCycle}",                                     cmd: "bmcctl power LABEL cycle",    status: "done" },
        { feature: "Power Control - Hard Reset",      what: "Force-restart, no OS notice",           redfish: "POST .../Reset {ForceRestart}",                                   cmd: "bmcctl power LABEL reset",    status: "done" },
        { feature: "Power Control - Boot to BIOS",    what: "Next boot stops in BIOS setup",         redfish: "PATCH /Systems/Self {Boot.Override=BiosSetup}",                    cmd: "bmcctl boot LABEL bios",      status: "done" },
        { feature: "Dashboard - PowerState",          what: "On / Off indicator",                    redfish: "GET /Systems/Self {PowerState}",                                  cmd: "bmcctl power LABEL status",   status: "done" },
      ]}/>

      <H3>Information and inventory</H3>
      <FeatureTable rows={[
        { feature: "Dashboard - Product Info",        what: "Board model, system product",           redfish: "GET /Systems/Self, /Chassis/Self",                                cmd: "bmcctl info LABEL",           status: "done" },
        { feature: "Dashboard - Firmware Info",       what: "BMC, BIOS, ME, microcode versions",     redfish: "GET /Managers/Self, /UpdateService/FirmwareInventory",            cmd: "bmcctl firmware LABEL",       status: "planned" },
        { feature: "Dashboard - Network Info",        what: "MAC, IPv4/IPv6 mode and address",       redfish: "GET /Managers/Self/EthernetInterfaces",                           cmd: "bmcctl net LABEL",            status: "planned" },
        { feature: "Sensor reading",                  what: "All temps, fans, voltages",             redfish: "GET /Chassis/Self/Thermal, /Power",                               cmd: "bmcctl sensors LABEL",        status: "done" },
        { feature: "System Information - FRU",        what: "Board / chassis / PSU serial numbers",  redfish: "ipmitool fru print 0 (no Redfish equivalent)",                    cmd: "bmcctl fru LABEL",            status: "done" },
        { feature: "System Information - SMBIOS",     what: "Host BIOS hardware self-description",   redfish: "Vendor-specific OEM endpoint, varies",                            cmd: "(use dmidecode on host)",     status: "later" },
        { feature: "System Information - Inventory",  what: "CPU, memory, storage breakdown",        redfish: "GET /Systems/Self/Processors, /Memory, /Storage",                 cmd: "bmcctl inventory LABEL",      status: "later" },
        { feature: "Logs - IPMI Event Log (SEL)",     what: "Hardware events, last N entries",       redfish: "GET /Systems/Self/LogServices/SEL/Entries",                       cmd: "bmcctl events LABEL",         status: "planned" },
      ]}/>

      <H3>OS install path (the install-arch story)</H3>
      <FeatureTable rows={[
        { feature: "Image Redirection - Remote Images", what: "Mount an ISO via NFS/SMB/HTTPS",      redfish: "POST /Managers/Self/VirtualMedia/CD1/Actions/InsertMedia",        cmd: "bmcctl mount-iso LABEL --url URL", status: "done" },
        { feature: "Media Redirection - eject",        what: "Unmount the virtual CD",                redfish: "POST /Managers/Self/VirtualMedia/CD1/Actions/EjectMedia",         cmd: "bmcctl eject-iso LABEL",      status: "done" },
        { feature: "Power Control - one-shot CD boot", what: "Next boot from virtual CD only",       redfish: "PATCH /Systems/Self {Boot.Override=Once,Target=Cd}",              cmd: "bmcctl boot LABEL cd",        status: "done" },
        { feature: "Cold-start to running OS",         what: "Mount + boot-override + power on",     redfish: "(orchestrates the three above)",                                  cmd: "bmcctl install-arch LABEL --iso URL", status: "done" },
      ]}/>

      <H3>Maintenance (lower priority, but cheap to add)</H3>
      <FeatureTable rows={[
        { feature: "Maintenance - Backup Configuration", what: "Export BMC config as a file",       redfish: "POST /Managers/Self/Actions/Oem.AmiBmc.Backup",                   cmd: "bmcctl backup LABEL > FILE",  status: "later" },
        { feature: "Maintenance - Restore Configuration", what: "Import a backup",                  redfish: "POST /Managers/Self/Actions/Oem.AmiBmc.Restore",                  cmd: "bmcctl restore LABEL FILE",   status: "later" },
        { feature: "Maintenance - Restore Factory",    what: "Wipe BMC config to defaults",          redfish: "POST /Managers/Self/Actions/Manager.ResetToDefaults",             cmd: "bmcctl factory-reset LABEL",  status: "later" },
        { feature: "Maintenance - Reset (BMC reboot)", what: "Reboot the BMC itself, host untouched",redfish: "POST /Managers/Self/Actions/Manager.Reset {GracefulRestart}",     cmd: "bmcctl bmc-reboot LABEL",     status: "later" },
        { feature: "Maintenance - Firmware Update",    what: "Flash a new BMC firmware image",       redfish: "POST /UpdateService/Actions/SimpleUpdate (multipart)",            cmd: "bmcctl flash LABEL IMAGE",    status: "later" },
        { feature: "Maintenance - BIOS Update",        what: "Flash host BIOS via the BMC",          redfish: "POST /UpdateService/Actions/SimpleUpdate (multipart, BIOS slot)", cmd: "bmcctl bios-flash LABEL IMG", status: "later" },
        { feature: "Settings - User Management",       what: "Create / delete BMC users",            redfish: "GET POST DELETE /AccountService/Accounts",                        cmd: "bmcctl users LABEL ...",      status: "later" },
        { feature: "Settings - Network Settings",      what: "DHCP/static, VLAN, hostname",          redfish: "PATCH /Managers/Self/EthernetInterfaces/eth0",                    cmd: "bmcctl net set LABEL ...",    status: "later" },
        { feature: "Settings - SSL Settings",          what: "Replace BMC HTTPS cert",               redfish: "POST /Managers/Self/NetworkProtocol/HTTPS/Certificates",          cmd: "bmcctl ssl push LABEL CERT",  status: "later" },
        { feature: "Settings - Date and Time",         what: "NTP servers, timezone",                redfish: "PATCH /Managers/Self/NetworkProtocol/NTP",                        cmd: "bmcctl ntp set LABEL ...",    status: "later" },
        { feature: "Remote Control - SOL",             what: "Serial-over-LAN console",              redfish: "(IPMI, not Redfish: ipmitool sol activate)",                       cmd: "bmcctl sol LABEL",            status: "later" },
        { feature: "Remote Control - KVM",             what: "Open H5Viewer in browser",             redfish: "(BMC web UI URL)",                                                cmd: "bmcctl kvm LABEL",            status: "done" },
        { feature: "Settings - Captured BSOD",         what: "Pull last BSOD screenshot",            redfish: "GET /Managers/Self/Oem.AmiBmc/CapturedBSOD",                       cmd: "bmcctl bsod LABEL > FILE",    status: "later" },
        { feature: "Miscellaneous - UID Control",      what: "Toggle the chassis ID LED",            redfish: "PATCH /Chassis/Self {IndicatorLED}",                              cmd: "bmcctl uid LABEL on/off",     status: "later" },
      ]}/>

      <Callout tone="neutral">
        Tiles I am marking <Pill tone="neutral" size="sm" active>later</Pill> are not less useful;
        they are just less central to the homelab cold-boot loop. Once
        <Code> install-arch </Code> works end-to-end, adding any one of them is
        a single afternoon: discover the Redfish path with <Code>curl</Code>,
        copy the existing <Code>internal/bmc/api.go</Code> pattern, add a
        subcommand in <Code>cmd/bmcctl/main.go</Code>, write tests against the
        in-process MegaRAC mock.
      </Callout>

      <H2>Phase 8 plan - two parallel streams</H2>

      <Grid columns={2} gap={16}>
        <Card>
          <CardHeader trailing={<Pill tone="info" size="sm" active>~2 hours</Pill>}>
            Stream A - Distribution (mechanical)
          </CardHeader>
          <CardBody>
            <Stack gap={8}>
              <Text tone="secondary">Same five-step pattern we just used for fsvc Phase 7e. Mostly templating.</Text>
              <Stack gap={6}>
                <Text><Text weight="semibold">A1.</Text> .goreleaser.yaml (cross-compile darwin/linux for amd64/arm64, plus linux armv7).</Text>
                <Text><Text weight="semibold">A2.</Text> .github/workflows/ci.yml + release.yml.</Text>
                <Text><Text weight="semibold">A3.</Text> arch/PKGBUILD + aur-bump.sh + aur-bootstrap.sh.</Text>
                <Text><Text weight="semibold">A4.</Text> Create j4y-w4lk3r/homebrew-bmcctl tap (public, MIT, Casks/.gitkeep).</Text>
                <Text><Text weight="semibold">A5.</Text> Wire HOMEBREW_TAP_GITHUB_TOKEN + AUR_SSH_PRIVATE_KEY secrets, tag v0.1.0, watch CI.</Text>
                <Text><Text weight="semibold">A6.</Text> Bump j4y-suite meta-cask to v0.2.0 with depends_on cask: j4y-w4lk3r/bmcctl/bmcctl.</Text>
              </Stack>
            </Stack>
          </CardBody>
        </Card>

        <Card>
          <CardHeader trailing={<Pill tone="added" size="sm" active>shipped v0.2.0</Pill>}>
            Stream B - Redfish features (value-add)
          </CardHeader>
          <CardBody>
            <Stack gap={8}>
              <Text tone="secondary">Each step is a self-contained subcommand. They build toward the cold-start install-arch story.</Text>
              <Stack gap={6}>
                <Text><Text weight="semibold">B1.</Text> bmcctl mount-iso / eject-iso (Redfish VirtualMedia.InsertMedia / EjectMedia). <Pill tone="added" size="sm">done</Pill></Text>
                <Text><Text weight="semibold">B2.</Text> bmcctl boot LABEL [pxe|cd|disk|bios|usb|diags] [--continuous] (PATCH /Systems/Self with If-Match ETag). <Pill tone="added" size="sm">done</Pill></Text>
                <Text><Text weight="semibold">B3.</Text> bmcctl install-arch LABEL --iso URL (orchestrates B1 + B2 + power-cycle, polls PowerState until On). <Pill tone="added" size="sm">done</Pill></Text>
                <Text><Text weight="semibold">B4.</Text> bmcctl firmware (read), bmcctl events (SEL log read), bmcctl net (interface read). <Pill tone="info" size="sm">v0.3.x</Pill></Text>
                <Text><Text weight="semibold">B5.</Text> All maintenance tiles — backup/restore, BMC reboot, factory-reset. <Pill tone="neutral" size="sm">on demand</Pill></Text>
              </Stack>
            </Stack>
          </CardBody>
        </Card>
      </Grid>

      <H2>Recommended order</H2>
      <Stack gap={8}>
        <Text>
          <Text weight="semibold">1. Stream A first (the boring part).</Text>{" "}
          Get bmcctl onto Homebrew + AUR exactly like fsvc. This is mechanical,
          well-trodden territory — no new design decisions. Once shipped, every
          subsequent feature ships in minutes via <Code>git tag v0.1.x</Code>.
        </Text>
        <Text>
          <Text weight="semibold">2. Then B1 + B2 + B3 in one cluster.</Text>{" "}
          Virtual media, boot override, and install-arch are interlocked
          (install-arch is just orchestration of the other two). Doing them
          together means one design pass, one round of tests against
          <Code> testmegarac</Code>, one release.
        </Text>
        <Text>
          <Text weight="semibold">3. Maintenance tiles on demand.</Text>{" "}
          Skip B4/B5 until you actually want one. The dashboard tiles map
          1-to-1 to <Code>bmcctl</Code> subcommands, so we can add any of them
          in an afternoon when a real need shows up (e.g. <Code>bmcctl events</Code>
          {" "}the next time a host crashes overnight).
        </Text>
      </Stack>

      <Divider />

      <Stack gap={6}>
        <H3>Status — 2026-06-04</H3>
        <Row gap={8} wrap>
          <Pill tone="added" active>Stream A: brew + AUR + meta-cask shipped v0.1.0</Pill>
          <Pill tone="added" active>Stream B: virtual media + boot + install-arch shipped v0.2.0</Pill>
          <Pill tone="info" active>Next: archiso build for unattended install (paired with bmcctl install-arch)</Pill>
        </Row>
        <Text size="small" tone="tertiary" style={{ marginTop: 6, color: t.text.tertiary }}>
          v0.2.0 commit <Code>bc44865</Code> ships 4 new commands, ~700 LOC,
          11 new tests against an extended <Code>testmegarac</Code> mock that
          enforces the same If-Match ETag dance the real AMI MegaRAC firmware
          does. <Code>bmcctl install-arch</Code> is the orchestrator — eject
          stale media, mount the ISO, set Boot=Cd/Once, PowerCycle, poll until
          PowerState=On. With <Code>--no-wait</Code> it fires-and-forgets,
          which is what you want once the ISO is fully unattended via airootfs
          /root/install.sh (Arch's equivalent of kickstart/preseed/cloud-init).
        </Text>
      </Stack>
    </Stack>
  );
}
