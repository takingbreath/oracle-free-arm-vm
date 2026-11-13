# Free Oracle Arm VM (Ampere A1) grabber

Oracle Cloud gives every account a free Arm VM (shape `VM.Standard.A1.Flex`).
When you ask for it, Oracle often answers **"Out of host capacity"**.
`grab-a1.sh` asks again and again until Oracle has space, then sends a message to your phone.

## With Claude (easiest)

Clone this repo, open the folder in Claude Code, and say:

> Get me the free Oracle server.

Claude follows [CLAUDE.md](CLAUDE.md). It opens Oracle in a browser, makes all keys, sets up the phone
alerts and runs the search. You only sign in, add a card, and install the ntfy app on your phone.

## The rules now (checked 13 Nov 2026)

| Rule | Value |
|---|---|
| Free A1 size, Always Free account | **2 OCPUs + 12 GB RAM in total** (1,500 OCPU-hours + 9,000 GB-hours per month). Was 4 OCPUs + 24 GB until **15 June 2026**. |
| Above the free size, Always Free account | Oracle refuses it (`LimitExceeded`). VMs above 2/12 were shut down after the change. |
| Where | Only in your **home region**. You choose it at sign-up. You cannot change it later. Mumbai = `ap-mumbai-1` ("India West (Mumbai)"). |
| Disk | 200 GB in total for all boot and block volumes. Each boot volume is at least 50 GB. |
| Idle VMs | Oracle can take back a free VM that is idle for 7 days: CPU (95th percentile) below 20 %, network below 20 % and memory below 20 %. |
| Pay As You Go (PAYG) account | Oracle's page says all accounts get the same free hours. Oracle support told users that the cut is for free-tier accounts only. On our PAYG account, the October 2026 bill shows a 4 OCPU / 24 GB A1 VM at cost 0. This is not an Oracle promise. It can change. |

Sources: [Oracle: Always Free resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm),
[InfoQ, July 2026](https://www.infoq.com/news/2026/07/oracle-cloud-free-tier-limits/),
[Oracle Free Tier FAQ](https://www.oracle.com/se/cloud/free/faq/).

**Fastest way to get the VM: upgrade the account to Pay As You Go (step 2).**

## Steps by hand

1. **Make an Oracle Cloud account** at <https://signup.cloud.oracle.com/>.
   Home region: **India West (Mumbai)**, or the region you want. Free VMs exist only there.

2. **Upgrade the account to Pay As You Go (do this, it is the main trick).**
   - Why: on a free-only account, "Out of host capacity" can go on for days or weeks.
     Many users report that the A1 VM comes at once after the upgrade.
     On our PAYG account (Mumbai, 13 Nov 2026) the launch worked on the first try.
   - How: Oracle console > menu > **Billing & Cost Management** > **Upgrade and Manage Payment** > **Pay As You Go**.
     Add a credit card (or a debit card that works like a credit card; prepaid and virtual cards are refused).
   - Oracle can put a temporary authorization hold on the card. The upgrade can take some time.
     You do not have to wait for it: start the search, it keeps trying.
   - Cost: the Always Free amounts stay free. Only use above them costs money.
     In October 2026 our PAYG account paid 0 for a 4 OCPU / 24 GB A1 VM, but Oracle does not promise this.
   - Safety: make a budget alert with a small limit and your email
     (**Billing & Cost Management** > **Budgets** > **Create Budget**).

3. **Install the tools.**
   - Mac: `brew install oci-cli qrencode`
   - Mac without Homebrew, or Linux (no sudo needed):
     `bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults`
     (the `oci` command is then in `~/bin`).

4. **Make the CLI key** (no download; the CLI makes the key and uploads it after you sign in):
   ```bash
   printf 'N/A\nN/A\n' | oci --region ap-mumbai-1 setup bootstrap --profile-name ORACLE_A1 --config-location ~/.oci/config
   ```
   A browser window opens. Sign in to Oracle. The command ends with `Config written to`.
   Use your own home region in `--region` if it is not Mumbai.

5. **Make an SSH key** for the VM:
   ```bash
   ssh-keygen -t ed25519 -N "" -f ~/.ssh/oracle_a1
   ```

6. **Phone alerts** (from the repo folder):
   ```bash
   ./ntfy-setup.sh
   ```
   Install the **ntfy** app ([Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy),
   [iPhone](https://apps.apple.com/us/app/ntfy/id1625396347)).
   Android: scan `ntfy-qr-android.png` with the camera and open the link in ntfy.
   iPhone: in the app tap "+" and type the topic name that the script printed.
   The script sends a test message. The topic name is secret: anyone who knows it can read the messages.

7. **Check everything, without a launch:**
   ```bash
   ./grab-a1.sh --check
   ```

8. **Start it and leave it running.** It can take minutes or days.
   - Mac (keeps the Mac awake, keeps running after the terminal closes):
     `nohup caffeinate -is ./grab-a1.sh >/dev/null 2>&1 &`
   - Linux server: run it inside `tmux` or `screen`.
   - It writes every attempt to `grab-a1.log`. Stop it with `kill $(cat grab-a1.pid)`.

9. When your phone says the VM is ready, log in:
   ```bash
   ssh -o StrictHostKeyChecking=accept-new -i ~/.ssh/oracle_a1 ubuntu@<public-ip>
   ```

## Phone messages

With `NTFY_TOPIC` set (step 6), the script sends:

| When | Message |
|---|---|
| The search starts | "Oracle VM search started" |
| Every `HEARTBEAT_HOURS` (default 6) | "Still trying for the Oracle VM", with the number of attempts (quiet) |
| The VM is ready | "Oracle VM is ready", with the IP and the SSH command (loud) |
| The script stops on an error | "Oracle VM script stopped", with the reason |
| Someone or the computer stops it | "Oracle VM script stopped", with the number of attempts |

No message for a long time means the computer is off or asleep. Start the search again.

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
- Stops if a VM with the same name already exists. Refuses to start a second copy of itself.

## Settings

All settings are in `config.env.example`, with notes. The most used:

| Setting | Default | Meaning |
|---|---|---|
| `OCPUS` / `MEMORY_GB` | `2` / `12` | VM size. Free account: 2/12 at most. |
| `BOOT_VOLUME_GB` | `50` | Disk size. Free: 200 GB in total. |
| `DISPLAY_NAME` | `free-a1` | VM name in the console. |
| `SSH_PUBLIC_KEY_FILE` | `~/.ssh/oracle_a1.pub` | Public key for user `ubuntu`. |
| `RETRY_SECONDS` | `60` | Wait between attempts. |
| `OCI_PROFILE` | `ORACLE_A1` | Profile in `~/.oci/config`. |
| `NTFY_TOPIC` | empty | ntfy topic for phone messages. `./ntfy-setup.sh` fills it in. |
| `HEARTBEAT_HOURS` | `6` | "Still trying" message interval. 0 = none. |

## Problems

| Message | Fix |
|---|---|
| `account limit is too low` | Free account: lower `OCPUS`/`MEMORY_GB` to 2/12 or less, minus other A1 VMs. Or upgrade to Pay As You Go (step 2). |
| `cannot sign in` / `refused the API key` | Do step 4 again. |
| `your home region is ...` | Set `region=` of `[ORACLE_A1]` in `~/.oci/config` to the home region. |
| `Another copy is already running` | A search runs already. Stop it first with `kill $(cat grab-a1.pid)`. |
| `Unexpected answer from Oracle` | Read Oracle's message above it. Fix it, then run again. |

## Tests

```bash
bash tests/fake-oci-test.sh     # 21 checks with a fake 'oci' and 'curl'; no account, no network
```

Tested on 13 Nov 2026 with OCI CLI 3.75.0 and macOS bash 3.2:
- the fake tests pass;
- a real run in `ap-mumbai-1` made the network, launched a 1 OCPU / 6 GB test VM, printed its IP,
  and the SSH login worked (the test VM and network were deleted after the test);
- real ntfy messages (test, start, ready, stop) arrived on ntfy.sh;
- the background start kept running after the terminal command ended, and `kill` sent the stop message;
- `oci setup bootstrap` printed the sign-in link and waited on port 8181 (the sign-in itself was not tested).
