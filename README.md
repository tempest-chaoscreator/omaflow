# Omaflow

Omaflow Plugin is the Omarchy bar chip. Omaflow is the cooling window. Both are clients of [CoolerControl](https://gitlab.com/coolercontrol/coolercontrol)'s `coolercontrold` daemon. Fan writes and sensor polls stay on that daemon's own `poll_rate` (default 1 second). Omaflow does not read sysfs and does not run `liquidctl`.

![Omaflow settings](screenshots/settings.jpg)

![Omaflow telemetry](screenshots/telemetry.jpg)

## Compatible version

**Omarchy 4** (Quattro shell). Tested on Omarchy `4.0.4`.

## Dependencies

| Package | Role |
| --- | --- |
| `coolercontrold` | The only control daemon. Do not install the `coolercontrol` desktop package. |
| [liquidctl](https://github.com/liquidctl/liquidctl) | Library the daemon uses for USB coolers. Omaflow never runs it. |
| Python 3 | Already on Omarchy. The plugin's client speaks HTTP to `127.0.0.1` only. |

`coolercontrold` is not in the Omarchy package repositories. Install that package yourself. The plugin does not run a package manager, does not install a root helper, and does not keep your CoolerControl password. Pairing asks for the password once, stores a revocable token at `~/.config/omaflow/coolercontrol.token` with mode `0600`, and drops the password. Revoke the token from CoolerControl's Access Protection page.

## Hardware

### Tested on

This machine:

| Role | Brand | Model |
| --- | --- | --- |
| CPU | AMD | Ryzen 9 5950X |
| GPU | NVIDIA | GeForce RTX 3090 Founders Edition |
| Motherboard | ASUS | ROG Crosshair VIII Dark Hero |
| AIO | NZXT | Kraken Z53 (LCD pump) |
| Fan hub | NZXT | Smart Device V2 |

AIO radiator fans on this build sit on an NZXT PWM hub into a motherboard header, not the Kraken fan header — so AIO fan control stays off unless you enable it.

### Supported (by backend)

<details>
<summary>NVIDIA</summary>

GPU fan control through `nvidia-settings` after you enable **GPU** on Settings. Zero-RPM idle (RTX 30-series Founders, and similar) is handed back to NVIDIA auto when the curve is 0%. Telemetry uses `nvidia-smi`.

- GeForce RTX 20 / 30 / 40 series
- GeForce GTX 16 series and newer with working `nvidia-settings` fan control
</details>

<details>
<summary>AMD</summary>

CPU package / CCD temps through `k10temp` (Ryzen). Chassis fans through any hwmon PWM channel CoolerControl exposes. No AMD GPU fan control in this release (telemetry only if the driver exports hwmon).

- Ryzen 3000 / 5000 / 7000 desktop (k10temp Tctl / Tccd)
- Board fan headers on ASUS, MSI, Gigabyte, ASRock when they appear as hwmon PWM
</details>

<details>
<summary>Intel</summary>

CPU temps through `coretemp` when present. Chassis fans through CoolerControl hwmon, same as AMD boards.

- Core i5 / i7 / i9 desktop with `coretemp`
</details>

<details>
<summary>NZXT</summary>

- Kraken Z53 / Z63 / Z73 — pump curve, LCD (liquid / accent / off), optional radiator fans
- Kraken X42 / X52 / X62 / X72 and X53 / X63 / X73 — pump (and fan where the device has one)
- Kraken 2023 / 2024 Standard and Elite — liquidctl LCD + pump
- Smart Device V1 / V2 — chassis fans via the kernel hwmon driver (`nzxtsmart2`)
</details>

<details>
<summary>Corsair</summary>

AIO pump / fan profiles through liquidctl when the device is listed by `liquidctl status`.

- Hydro H100i / H115i / H150i Pro / Elite / XT / Platinum class coolers
- Commander Pro / Core fan hubs if liquidctl exposes them
</details>

<details>
<summary>Other AIOs and hubs</summary>

Anything CoolerControl lists from liquidctl or hwmon. Pump duty is clamped to a 50% floor in every mode.

- MSI MEG / MPG CoreLiquid
- EVGA / NZXT Asetek 690LC units
- Aquacomputer D5 Next and similar liquidctl devices
- Generic motherboard PWM fans (Nuvoton NCT, ITE IT87, ASUS EC, …)
</details>

## Install

```bash
omarchy plugin add https://github.com/tempest-chaoscreator/omaflow-plugin.git --enable
```

This private repository holds both installs. Omaflow Plugin is the repository root. Omaflow, the cooling window, is `app/`.

Start the daemon for this session if it is not already running. Leave it disabled at boot. Omaflow always uses `127.0.0.1:11987`. There is no address or port to type.

```bash
sudo systemctl start coolercontrold
```

A saved token connects with no prompt. If the CoolerControl password was changed, the chip asks for it once, stores a revocable token, and drops the password. When the daemon has no modes yet, Omaflow creates Silent, Performance, Fixed, and Hell from the current channel snapshot. It does not replace modes that already exist, and it does not apply an empty mode.

The widget lands on the right of the bar. Move it with:

```bash
omarchy bar move tempest-chaoscreator.omaflow --section right
```

### Remove

```bash
omarchy plugin remove tempest-chaoscreator.omaflow
```

That deletes the plugin folder and its bar entry. `coolercontrold` and `liquidctl` stay installed. The token file stays at `~/.config/omaflow/coolercontrol.token` until you delete it. Revoke the Omaflow token in CoolerControl if you remove the plugin.

## Using it

| Action | Effect |
| --- | --- |
| Left click the chip | Open / close Omaflow Plugin |
| Right click | Toggle Silent and Performance, when those modes exist |
| `1`–`9` | Activate the mode in that position |
| `o` | Open Omaflow |
| Escape | Close the popover |

**Telemetry** — CPU (Tctl + CCDs), GPU (temp, load, power, fan), coolant, pump, chassis RPM, one-minute sparkline. The mode buttons on this page are the ones that change the live curve.

**Settings** — five modes and an NZXT CAM-style graph. CPU-temperature graphs run 28–98 °C. Liquid-temperature graphs (Pump, AIO, and CPU) run 28–60 °C, which is as hot as coolant should get. GPU stays on 20–90 °C. Drag a handle up and the points to its right come with it. Silent / Static / Performance / Hell share one padlock. Custom is always unlocked. Reset restores only the selected channel. Edits on this tab do not change the live mode; pick that on Telemetry.

Pump, AIO, and CPU each have a curve input: CPU temp or liquid temp. GPU and AIO (and CPU, when a CPU fan header is detected) hide their on/off switch until you select that card. The card grows to show a horizontal switch. CPU stays grey when CoolerControl sees no CPU fan. The info mark next to Reset explains one-cable AIOs: leave the CPU switch off and let the BIOS run `CPU_FAN`, or split the cable so the pump is on `AIO_PUMP` and the radiator fans are on `CPU_FAN`.

The bottom of Settings exports and imports a JSON file of the stored curves and settings.

Every channel card has a switch. Off does not stop the fan. A motherboard header (chassis, `CPU_FAN`, `AIO_PUMP`) is handed back to the BIOS curve. NVIDIA fans go back to the driver's own curve. A USB cooler has no BIOS curve, so Omaflow simply stops sending new speeds and the device keeps the last duty — never 0%. Silent's AIO curve sits 10–15 points above the chassis curve. The AIO card opens on CPU temperature. If CoolerControl sees an `AIO_PUMP` header and there is no USB cooler, that header follows the Pump curve. A USB pump and that header are never driven together.

GPU and AIO stay off until you enable them. Chassis and Pump start on. The CPU switch is shown on its card and stays locked off when no `CPU_FAN` header is detected.

| Mode | Fans | Pump |
| --- | --- | --- |
| **Silent** | Low floor, slow ramp | 50% floor, then up with CPU temp |
| **Static** | Flat 50% | Flat 60% |
| **Performance** | Steep ramp | 75% floor, then up |
| **Hell** | High floor, stays aggressive | 75% until warm, then 100% |
| **Custom** | Yours | Yours (still 50% minimum) |

Pump duty never goes below 50% in any mode, including Custom — dragging a pump handle below that floor snaps it back.

AIO LCD:

- **Liquid temp** — coolant readout. With **Sync with theme accent** on, Omaflow redraws it in the theme color (stock firmware liquid is white).
- **Theme accent** — solid fill of the Omarchy accent.
- **Off** — black screen, brightness 0.

## How it applies

- `coolercontrold` owns the fans, the pump, and the pump LCD. Omaflow sends channel settings and curves to `127.0.0.1:11987`. It does not write PWM, sysfs, or USB itself.
- Sensor polls and duty writes stay on the daemon's `poll_rate` (default 1 second). Omaflow does not change that rate on its own.
- Pump curves stay at or above 50%.
- Applying a mode puts the saved pump image back with the daemon orientation at 0, so the orientation stored on the mode does not turn the glass.

## Privileged paths

Omaflow does not install a root helper and does not run as root. The only secret it stores is the CoolerControl token at `~/.config/omaflow/coolercontrol.token`, mode `0600`. Curve groups, link flags, hidden devices, and the LCD view are local files in that directory, also mode `0600`.

## License

MIT. See [LICENSE](LICENSE).
