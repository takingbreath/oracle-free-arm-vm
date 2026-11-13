# Free Oracle Arm VM (Ampere A1) grabber

Oracle Cloud gives every account a free Arm VM (shape `VM.Standard.A1.Flex`).
When you ask for it, Oracle often answers **"Out of host capacity"**.
`grab-a1.sh` asks again and again until Oracle has space, then prints the IP.

## The rules now (checked 13 Nov 2026)

| Rule | Value |
|---|---|
| Free A1 size, Always Free account | **2 OCPUs + 12 GB RAM in total** (1,500 OCPU-hours + 9,000 GB-hours per month). Was 4 OCPUs + 24 GB until **15 June 2026**. |
| Above the free size, Always Free account | Oracle refuses it (`LimitExceeded`). VMs above 2/12 were shut down after the change. |
| Where | Only in your **home region**. You choose it at sign-up. You cannot change it later. |
| Disk | 200 GB in total for all boot and block volumes. Each boot volume is at least 50 GB. |
| Idle VMs | Oracle can take back a free VM that is idle for 7 days: CPU (95th percentile) below 20 %, network below 20 % and memory below 20 %. |
| Pay As You Go (PAYG) account | Oracle's page says all accounts get the same free hours. Oracle support told users that the cut is for free-tier accounts only. On our PAYG account, the October 2026 bill shows a 4 OCPU / 24 GB A1 VM at cost 0. This is not an Oracle promise. It can change. |

Sources: [Oracle: Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm),
[InfoQ, July 2026](https://www.infoq.com/news/2026/07/oracle-cloud-free-tier-limits/).

**Fastest way to get the VM: upgrade the account to Pay As You Go (step 2).**

## Steps

1. **Make an Oracle Cloud account** at <https://www.oracle.com/cloud/free/>.
   Choose the home region with care. Free VMs exist only there.

2. **Upgrade the account to Pay As You Go (do this, it is the main trick).**
   - Why: on a free-only account, "Out of host capacity" can go on for days or weeks.
     Many users report that the A1 VM comes at once after the upgrade.
     On our PAYG account (Mumbai, 13 Nov 2026) the launch worked on the first try.
   - How: Oracle console > menu > **Billing & Cost Management** > **Upgrade and Manage Payment** > **Pay As You Go**.
     Add a credit card (or a debit card that works like a credit card; prepaid and virtual cards are refused).
   - Oracle can put a temporary authorization hold on the card. The upgrade can take some time.
     Wait until the console shows the account as Pay As You Go, then go on.
   - Cost: the Always Free amounts stay free. Only use above them costs money.
     In October 2026 our PAYG account paid 0 for a 4 OCPU / 24 GB A1 VM, but Oracle does not promise this.
   - Safety: make a budget alert with a small limit and your email
     (**Billing & Cost Management** > **Budgets** > **Create Budget**).
   - On PAYG you can ask for the old size: set `OCPUS=4` and `MEMORY_GB=24` in `config.env`.
     Keep 2 / 12 if you want to be sure it stays free.

3. **Install the OCI CLI.**
   - Mac: `brew install oci-cli`
   - Linux: `bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"`

4. **Make an API key** (the CLI signs in with it).
   - Oracle console > profile icon (top right) > **My profile** > **API keys** (some consoles: **Tokens and keys**) > **Add API key**.
   - Choose **Generate API key pair**, click **Download private key**, then **Add**.
   - Oracle shows a "Configuration file preview". Copy it into `~/.oci/config`.
   - Put the full path of the downloaded `.pem` file in the `key_file=` line.
   - Run `chmod 600 ~/.oci/config ~/.oci/*.pem`.
   - Test: `oci iam availability-domain list` must print your availability domains.

5. **Make an SSH key** for the VM:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/oracle_a1
   ```

6. **Get this repo and set it up:**
   ```bash
   git clone https://github.com/takingbreath/oracle-free-arm-vm.git
   cd oracle-free-arm-vm
   cp config.env.example config.env     # change values only if you need to
   ```

7. **Check everything, without a launch:**
   ```bash
   ./grab-a1.sh --check
   ```

8. **Start it and leave it running.** It can take minutes or days.
   - Mac (keeps the Mac awake): `caffeinate -i ./grab-a1.sh`
   - Linux server: run it inside `tmux` or `screen`.
   - It writes every attempt to `grab-a1.log`.

9. When it prints `SUCCESS`, log in:
   ```bash
   ssh -i ~/.ssh/oracle_a1 ubuntu@<public-ip>
   ```

## What the script does

- Reads the tenancy and region from `~/.oci/config`. It stops if the region is not your home region.
- Finds every availability domain in the region and tries them in turn.
- Finds the newest Canonical Ubuntu 24.04 Arm image.
- Finds a public subnet. If there is none, it makes a free VCN, an internet gateway and a public subnet. The new VCN lets SSH (port 22) in.
- Sends **one** launch request per attempt (`--no-retry`). The CLI otherwise repeats a failed launch up to 8 times by itself.
- On "Out of host capacity": waits `RETRY_SECONDS` (default 60), then tries again.
- On "TooManyRequests": doubles the wait, up to 10 minutes.
- On a lost answer (timeout or 5xx error): checks whether the VM exists before it tries again. So it never makes two VMs.
- Stops at once on `LimitExceeded`, a bad API key, or any other unknown error, and shows Oracle's message.
- Stops if a VM with the same name already exists.

## Settings

All settings are in `config.env.example`, with notes. The most used:

| Setting | Default | Meaning |
|---|---|---|
| `OCPUS` / `MEMORY_GB` | `2` / `12` | VM size. Free account: 2/12 at most. |
| `BOOT_VOLUME_GB` | `50` | Disk size. Free: 200 GB in total. |
| `DISPLAY_NAME` | `free-a1` | VM name in the console. |
| `SSH_PUBLIC_KEY_FILE` | `~/.ssh/oracle_a1.pub` | Public key for user `ubuntu`. |
| `RETRY_SECONDS` | `60` | Wait between attempts. |
| `OCI_PROFILE` | `DEFAULT` | Profile in `~/.oci/config`. |

## Problems

| Message | Fix |
|---|---|
| `account limit is too low` | Free account: lower `OCPUS`/`MEMORY_GB` to 2/12 or less, minus other A1 VMs. Or upgrade to Pay As You Go (step 2). |
| `cannot sign in` / `refused the API key` | Check `~/.oci/config` (user, fingerprint, key_file, tenancy). |
| `your home region is ...` | Set `region=` in `~/.oci/config` to the home region. |
| `Unexpected answer from Oracle` | Read Oracle's message above it. Fix it, then run again. |

## Tests

```bash
bash tests/fake-oci-test.sh     # 12 checks with a fake 'oci'; no Oracle account needed
```

Tested on 13 Nov 2026 with OCI CLI 3.75.0 and macOS bash 3.2:
the fake tests pass, and a real run in `ap-mumbai-1` made the network, launched a 1 OCPU / 6 GB test VM,
printed its IP, and the SSH login worked. The test VM and network were deleted after the test.
