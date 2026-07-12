# RFFE4095 - 24 GHz Phased Array Radar RX/TX RFFE

IHP__RFFE4095: 24 GHz Phased Array Radar RF Front End module submission for IHP SG13G2 130 nm BiCMOS, July 2026.

Fully-integrated 22 - 26 GHz FMCW phased-array RX/TX radar front end module on with integrated LNA, PA, phase shifter, up/down conversion mixer, PLL, and VCO.

![alt text](doc/EDSArchRev1.png)

### Authors
Max Vallone, Ryan Wans, Grant Congdon, Alek Taranov, Arthur Prudius, Andrew Fewell.

### Contact
Max Vallone: mvallone@purdue.edu
Alek Taranov: ataranov@purdue.edu

---

## Features

- **LNA**: LNA gain 22 dB, NF 3.5 dB @ 24 GHz. 
- **PA**: PA gain 25 dB, Pout +5 dBm over 22-26 GHz RF bandwidth.
- **Upconversion mixer**: Single sideband differential mixer with 3 dB conversion gain. 2 GHz IF bandwidth, 22-26 GHz RF bandwidth. 14 mA @ 1.8 V.
- **Downconversion mixer**: Single-ended mixer with 3 dB conversion gain, 2 GHz IF bandwidth, 22-26 GHz RF bandwidth. 3 mA @ 1.2 V.
- **Phase shifter**: 360° Gilbert cell topology phase shifter with polyphase input, single ended output, 40mA consumption at 1.2V.
- **PLL**: 26mA, 5.5-6.5G Quadrature Int-n PLL, 80MHz frequency steps, Off chip loop filter, 20MHz reference.
- **Multiplier**: x4 frequency multiplier with quadrature in, single ended out, 12mA.
- **VCO**: 6 GHz VCO with 5.276 GHz - 6.693 GHz (1.417 GHz tuning range), 0.65 Vpp swing, 89.66° I/Q at 1.65 V supply. 23.3 mA @ 1.65 V.
- **SPI**: SPI slave interface (CPOL=0, CPHA=0) for configurable frequency and operating point.

---

# Repository

### Structure

```
- doc/     : user documentation
- dependencies/ : sub-cells and blocks
- release/v.1.0.0 : immutable versioned deliveries
```

### Setup
```
git clone https://github.com/Purdue-IEEE-EDS/IHP__RFFE4095.git ~/IHP__RFFE4095
cd ~/IHP__RFFE4095
```

---

## Building Release

To build a new release, run `./release.sh` with the path to new new GDS:
```
cd ~/IHP__RFFE4095
CONTAINER=3caa74e4d32c ./release.sh /path/to/new.gds
```

Where `CONTAINER=<container_id_or_name>` is the docker `iic-osic container`:
```
$ docker ps
CONTAINER ID   IMAGE                   COMMAND                  CREATED       STATUS       PORTS                        NAMES
3caa74e4d32c   hpretl/iic-osic-tools   "/dockerstartup/scri…"   2 weeks ago   Up 2 weeks   80/tcp, 5901/tcp, 8888/tcp   objective_sutherland
```

This script:
- Flattens/normalizes the passed GDS
- Compares a stable geometry fingerprint against current release/gds/RFFE4095.gds
- If different, creates the next patch release, e.g. release/v.1.0.1/, with:gds/RFFE4095.gds
- Updates release/gds/RFFE4095.gds
- If identical, it does not create a new version
