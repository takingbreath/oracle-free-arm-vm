# Instructions for Claude: get Naveen a free Oracle Cloud Arm server

Your job: get Naveen a free Oracle Cloud Arm VM (Ampere A1, Ubuntu), in **Mumbai** if possible.
Do the work yourself. Naveen does only what needs him: sign-in, sign-up details, passwords,
verification codes, card details, the final "Upgrade" click, and the phone app.
Do not give him a list of steps to do. Tell him in one or two short sentences what you do next, then do it.

Read `README.md` for the Oracle rules and for what the scripts do.

## Facts (checked 13 Nov 2026)

- Free A1 size: **2 OCPUs + 12 GB RAM** in total per account (since 15 June 2026; before: 4 + 24).
- A free VM can exist only in the account's **home region**. The home region is chosen at sign-up and cannot change.
  Mumbai = region `ap-mumbai-1` = "India West (Mumbai)" in the sign-up form.
- A free-only account often gets "Out of host capacity" for days or weeks.
  Many users report that the VM comes fast after an upgrade to **Pay As You Go** (PAYG).
  The free amounts stay free on PAYG. Only use above them costs money.
- The repo owner's PAYG account (Mumbai) got its VM on the first try on 13 Nov 2026.

## Rules for you

1. Never type Naveen's password, verification codes, or card numbers. He types them in the browser.
2. Naveen clicks the final **Upgrade** / accept-terms button himself.
3. Do not download files in the browser. The CLI makes all keys on this computer.
4. Ask for the go-ahead once, with the start message below. After his yes, do every listed action without asking again.
5. Ask again only for: money above the free amounts (for example 4 OCPU / 24 GB), and deleting anything.
6. Never commit `config.env`, `grab-a1.log`, `grab-a1.pid`, the QR image or keys. `.gitignore` covers them. The ntfy topic is a secret.
7. Use the OCI profile `ORACLE_A1`. Never write to the `DEFAULT` profile: `oci setup bootstrap` silently replaces a profile with the same name.
8. Commands that can take long (`brew install`, the Oracle CLI installer, `oci setup bootstrap`): run them in the background or with a long time limit.
9. Report each finished step to Naveen in one line.

## Step 0: find out what is done already (every new session)

A free-only account can need days, so a later session may continue this work. Before the start message, check:
```bash
ls config.env grab-a1.pid grab-a1.log 2>/dev/null
grep -A6 '^\[ORACLE_A1\]' ~/.oci/config 2>/dev/null | grep -E '^(tenancy|region)='
ls ~/.ssh/oracle_a1 2>/dev/null
[ -f grab-a1.pid ] && ps -p "$(cat grab-a1.pid)" -o pid=,command=
tail -5 grab-a1.log 2>/dev/null
```
- `grab-a1.log` shows `SUCCESS`: go to step 9.
- The search runs (the `ps` line shows `grab-a1`): tell Naveen the last log line and go to "Watch the search" in step 8.
- Some files exist: skip the steps that are done. Send only the start-message parts that are still open.
- Nothing exists: send the start message.

## Start message (send this first; start step 1 while he answers)

> I will get you a free Oracle Cloud Arm server (2 cores, 12 GB RAM, Ubuntu) in Mumbai. The plan:
> 1. Phone alerts: you install the free **ntfy** app and subscribe with one QR code (Android) or one name (iPhone).
> 2. Oracle: I open Oracle in the browser. You sign in (or sign up), then you add a card and click Upgrade to make
>    the account **Pay As You Go**. Oracle then gives the server much faster. The free part stays free.
>    I add a budget alert of about ₹200 per month to your Oracle email.
> 3. On this Mac I make an SSH key and an Oracle CLI key. The CLI key is added to your Oracle user. It gives this Mac
>    full control of your Oracle account and stays on this Mac. In your account I make a free network.
> 4. I start a script that asks Oracle again and again until the server exists. Your phone gets a message when it is ready.
>
> Do you already have an Oracle Cloud account? And OK to go?

## Step 1: tools (no input from Naveen needed)

```bash
command -v brew && brew install oci-cli qrencode
```
- No Homebrew: install the Oracle CLI without it (no sudo):
  ```bash
  bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)" -- --accept-all-defaults
  export PATH="$HOME/bin:$PATH"
  ```
  Without Homebrew there is no QR code. Naveen then types the topic name in the app. That is fine.
- Check: `oci --version`.

## Step 2: phone alerts (ntfy)

```bash
./ntfy-setup.sh
```
It makes a random secret topic, saves it in `config.env` (made from `config.env.example`), makes an Android QR code
`ntfy-qr-android.png`, and sends a test message.
- Run `open ntfy-qr-android.png` (it opens on the Mac screen). If you have a browser tool, you can also show it there.
- Send Naveen in one message: the two app links, the topic name, and:
  - Android: install ntfy, scan the QR code on the screen with the camera, open the link in ntfy.
  - iPhone: install ntfy, tap "+", type the topic name, keep the default server, tap Subscribe.
  - Allow notifications.
- Do not wait for him. Go on with step 3.
- When he says it is done, run `./ntfy-setup.sh --test` and ask if the phone showed "ntfy works".
  If not: check the notification permission and the topic spelling.

## Step 3: Oracle account and sign-in

Use your browser tool (Claude in Chrome or the built-in browser). Use the same browser tool for step 4 and step 5,
so that Naveen signs in only once. If you have no browser tool, use `open <url>` (his default browser) for all three steps.

- **No account:** open https://signup.cloud.oracle.com/ . Naveen fills the form himself.
  Tell him: **Home Region = India West (Mumbai)**. It cannot change later. Oracle asks for a card to verify him.
  Account set-up can take some minutes. Wait until the console opens or he says "done".
- **Has an account:** open https://cloud.oracle.com/ and let him sign in.
  Find the home region: the region menu (top right) marks it as the home region.
  If it is not Mumbai, tell him: "Your server can only be in <region>. Oracle does not allow a change." Go on with that region.

## Step 4: upgrade to Pay As You Go, and the budget alert

- In the signed-in console: menu > **Billing & Cost Management** > **Upgrade and Manage Payment**. Choose **Pay As You Go**.
- Naveen adds the card and clicks Upgrade himself. Oracle takes only credit cards or debit cards that work like credit cards.
  Oracle can put a temporary authorization hold on the card.
- If he says no to the upgrade: go on with the free account. Tell him it can take days.
- The upgrade can take minutes to hours. Do not wait for it.
- Budget alert, right after the upgrade request: find his email on the profile page (profile icon > **My profile**).
  Then menu > **Billing & Cost Management** > **Budgets** > **Create Budget**: monthly, amount about ₹200 in the
  currency that the form shows (about 3 if it shows USD), alert rule at 100 % of actual spend, to his email.
  Tell him in one line: "Budget alert: <amount> per month to <email>." If the form refuses before the upgrade is
  active, do it again in step 9.

## Step 5: Make the CLI key (made on this computer, no download)

Run it in the background. It waits for the sign-in. Use the home region if it is not Mumbai.
With a browser tool, keep `BROWSER=true` so that no second window opens. Without one, leave `BROWSER=true` out.
```bash
printf 'N/A\nN/A\n' | BROWSER=true oci --region ap-mumbai-1 setup bootstrap --profile-name ORACLE_A1 --config-location ~/.oci/config
```
- It prints a sign-in URL (`https://login.<region>.oraclecloud.com/...`). Open that URL in your browser tool.
  Naveen is already signed in there, so Oracle often goes on at once. If Oracle asks, he signs in again.
  The page then goes to `http://localhost:8181`, and the command continues.
- When the command ends, it prints `Config written to`. The key is in `~/.oci/sessions/ORACLE_A1/`.
- Test: `oci iam region-subscription list --profile ORACLE_A1`. It must list the home region.
- Nothing after 5 minutes: check for `[ORACLE_A1]` in `~/.oci/config`. If it is missing, stop the command and use the fallback.
- `port 8181 is already in use`: stop the program on port 8181 (`lsof -nP -iTCP:8181`), then run again.
- `ApiKey limit has been reached`: a user can have 3 API keys. Let Naveen delete an old key in the console
  (profile icon > **My profile** > **API keys**), then run again.
- **Fallback** (if bootstrap fails):
  ```bash
  mkdir -p ~/.oci && chmod 700 ~/.oci
  openssl genrsa -out ~/.oci/oracle_a1_api.pem 2048 && chmod 600 ~/.oci/oracle_a1_api.pem
  openssl rsa -pubout -in ~/.oci/oracle_a1_api.pem
  ```
  In the console: profile icon > **My profile** > **API keys** (or **Tokens and keys**) > **Add API key** >
  **Paste a public key**. Paste the PUBLIC key (it is not a secret). Oracle shows a "Configuration file preview".
  Copy it into `~/.oci/config` as section `[ORACLE_A1]`, with `key_file=~/.oci/oracle_a1_api.pem`.
  Then run `chmod 600 ~/.oci/config` (the CLI warns about open permissions).

## Step 6: SSH key

```bash
[ -f ~/.ssh/oracle_a1 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/oracle_a1 -C oracle-a1
```

## Step 7: settings and check

`config.env` exists after step 2. It has `OCI_PROFILE=ORACLE_A1` from the example. Keep `OCPUS=2` and `MEMORY_GB=12`.
```bash
./grab-a1.sh --check
```
It must end with `Check passed`. Fix any `STOP:` line, then run it again.
- `home region is ...`: set `region=` of `[ORACLE_A1]` in `~/.oci/config` to the home region.
- `cannot sign in`: do step 5 again.

## Step 8: start the search

```bash
nohup caffeinate -is ./grab-a1.sh >/dev/null 2>&1 &
```
- Check after 10 seconds: `ps -p "$(cat grab-a1.pid)"` and `tail -5 grab-a1.log`. The phone gets "Oracle VM search started".
- Tell Naveen: "The search runs. Keep the Mac plugged in and the lid open. Your phone gets a message
  when the server is ready, if the search stops, and every 6 hours while it tries."
- The script stops by itself on success and on errors that need a person. It never makes two VMs. Only one copy can run.
- Stop by hand: `kill $(cat grab-a1.pid)`. Start again: the same `nohup` command.

**Watch the search.** While this session stays open, watch `grab-a1.log` in the background
(for example a Monitor or a loop that waits for `SUCCESS` or `STOP:`). On `SUCCESS`, do step 9.
On `STOP:`, read the reason, fix it, start again. If the session closes, ntfy still tells Naveen, and a new session starts at step 0.

## Step 9: when the VM is ready

- `grab-a1.log` and the phone message show the IP. The SSH server needs about a minute after the VM starts. Test:
  ```bash
  for i in $(seq 12); do ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
    -i ~/.ssh/oracle_a1 ubuntu@<ip> 'uname -m; nproc; free -g' && break; sleep 10; done
  ```
- Add an SSH alias so he can type `ssh oracle-a1` (append to `~/.ssh/config`):
  ```
  Host oracle-a1
      HostName <ip>
      User ubuntu
      IdentityFile ~/.ssh/oracle_a1
  ```
- If the budget alert failed in step 4, make it now.
- Tell Naveen: the IP, `ssh oracle-a1`, and one rule: on a free-only account, Oracle can take back a VM that is
  idle for 7 days (CPU, network and memory all below 20 %).
- If he wants 4 OCPU / 24 GB on PAYG: tell him Oracle's page counts only 2 / 12 as free, and that the repo owner's
  PAYG account paid 0 for 4 / 24 in October 2026 without a promise. Change the size only after his yes:
  console > Compute > Instances > the VM > **Edit** > shape > 4 OCPU / 24 GB (it restarts the VM; the change can also
  get "Out of host capacity").

## Problems

| Message | What to do |
|---|---|
| `account limit is too low` | Free account: keep 2 / 12, and check for other A1 VMs in the console. Or finish the PAYG upgrade. |
| `Another copy is already running` | One search runs already. Use it, or stop it first. |
| `Unexpected answer from Oracle` | Read Oracle's message in the log. Fix it, start again. |
| `The OCI CLI is not installed` | Step 1. Without Homebrew, add `~/bin` to `PATH`. |
| No phone message | `./ntfy-setup.sh --test`. Check the app subscription and notification permission. |
| The Mac slept or restarted | Start step 8 again. Nothing is lost. |
