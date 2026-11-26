# The Mac node's keyboard session: one runbook

The measurements only the user can make (the [measurement record](v2-mac-measurements.md)'s "What stands between this
Mac and `vibeswitcher start`", rows 1 and 2: LA-1 to LA-7, ESC-1 to ESC-3, ANC-1, ANC-2, AG-1), then the `sudo` trial
of the anchor's record ([the tasks](v2-mac-tasks.md), item 10). About **25 minutes** in all; LA-4 needs an external
display, LA-5 and ANC-2 need Remote Login on for a few minutes.

**Where.** A **Terminal.app** window on this Mac (not a shell card: ANC-1 refuses one, and ESC-1/2 compare with
Terminal.app). Every command runs from this checkout, branch `v2-mac-runbook`, which stays in place until the session
is done. Start with:

```
cd /Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/v2-on-the-mac-8/.vibeswitcher/v2-runbook
```

**How each step goes.** It builds its probes (a few seconds), says what will appear, and waits: press **Return** to go
on (anything else stops it, nothing done). A step that shows something asks at the end for **one line of what you
saw**: type it and Return (never a password there; anything typed into Terminal before that question is thrown away). Its record is printed and saved in `.build/mac-measure-records/<script>.txt` of this
checkout (a run again replaces it; a run that stopped saves `<script>.stopped.txt`).

**While a dialog is up, answer the dialog, not Terminal.** Don't press Ctrl-C then: the script waits for the dialog to
end before it removes its job (it never kills a process inside an authentication), and every approval dialog ends by
itself within 60 s (LA-7's and ESC-2's consent questions wait for your answer). A job left behind is named with its `launchctl bootout` line; the undo list below catches it too.

## A. Needs nothing (about 12 minutes)

**1. ESC-3: how a job a session loads itself into launchd looks** (nothing on screen, under 30 s).

```
bash scripts/mac-measure/escape-launchctl.sh
```

Record `escape-launchctl.txt`; look for the job block's `ppid=1` and its `coalition` against yours.

**2. AG-1: what `launchctl bootout` ends** (nothing on screen, about 30 s).

```
bash scripts/mac-measure/agent-bootout.sh
```

Record `agent-bootout.txt`; look for the `== after bootout` lines: `main`, `group`, `setsid`, each `ended` or `still
running` (the script ends a survivor itself).

**3. ANC-1: this Terminal's chain of processes, read whole** (nothing on screen, under 30 s).

```
bash scripts/mac-measure/ancestry-terminal.sh
```

Record `ancestry-terminal.txt`; look for `login` with `bsdinfo=refused` and every `-- ancestor` line read.

**4. LA-1: the approval dialog asked by a LaunchAgent** (about 1 minute).

```
bash scripts/mac-measure/la-agent.sh
```

A system dialog: "la is trying to MEASURE-1 approve setting x to y", Touch ID or password. Read its words (a
screenshot helps), then **touch Touch ID**. Record `la-agent.txt`; look for `outcome=approved`.

**5. LA-2: Cancel, then the dialog's own 60 s limit** (about 2 minutes).

```
bash scripts/mac-measure/la-cancel.sh
```

First dialog ("MEASURE-2 …"): **click Cancel**. Second, the same: **touch nothing**; it goes away by itself after 60 s.
Record `la-cancel.txt`; look for `outcome=declined("cancelled at the Mac")`, then `outcome=declined("not answered
within 60 s")`.

**6. LA-3: the password route** (about 1 minute).

```
bash scripts/mac-measure/la-password.sh
```

In the dialog ("MEASURE-3 …") choose **Use Password…** and type your login password **into the dialog only**. Record
`la-password.txt`; look for `outcome=approved`.

**7. LA-6: a second dialog while one is open** (about 1 minute).

```
bash scripts/mac-measure/la-second.sh
```

"MEASURE-6 FIRST", then 3 s later "MEASURE-6 SECOND". Watch what the second does (waits, replaces, appears beside), then
**Cancel each**. Record `la-second.txt`; look for two `outcome=` lines.

**8. LA-7: whether a key from Terminal can answer the dialog** (about 1 minute).

```
bash scripts/mac-measure/la-keys.sh
```

A dialog ("MEASURE-7 …"); 3 s later a helper posts **one Escape**, only while the dialog is in front. **Touch nothing
for 10 s**, then Cancel it if it is still there. If macOS asks whether Terminal may control this computer
(Accessibility): **Don't Allow**. Record `la-keys.txt`; look for `keys: posted Escape at=…` followed by `outcome=` within
a second or two, or `keys: posted nothing: the frontmost app … isn't one of …` (a result too: hand it back as it is).

**9. ESC-1: `open -a Terminal` from a detached process** (about 1 minute).

```
bash scripts/mac-measure/escape-open-terminal.sh
```

A new Terminal window opens, runs for a moment and says the process completed: **close that window** (⌘W). Record
`escape-open-terminal.txt`; look for `== its chain` and the escaped shell's `coalition`/`responsible` against yours.

**10. ESC-2: `osascript … do script` from a detached process** (1 to 2 minutes).

```
bash scripts/mac-measure/escape-osascript.sh
```

macOS may ask whether to let something control Terminal (Automation): answer as you would an unknown request
(**Don't Allow** is fine: that is a result) **within 90 s**, and note its words. A new Terminal window may open and run:
**close it**. Record `escape-osascript.txt`; look for `== its chain`, or `== nothing ran within 90 s`.

## B. Needs Remote Login (about 6 minutes)

**11. Turn Remote Login on**: System Settings › General › Sharing › **Remote Login** on (it may ask for Touch ID or
your password: System Settings' own). Check it:

```
/usr/bin/nc -z -G 2 localhost 22 && echo "Remote Login: on" || echo "Remote Login: off"
```

**12. Log in over ssh** to this Mac. The first time it asks `Are you sure you want to continue connecting`: type `yes`.
Then your login password at ssh's `Password:` prompt (in this Terminal: that is ssh's own prompt).

```
ssh localhost
```

Then, in that ssh login:

```
cd /Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/v2-on-the-mac-8/.vibeswitcher/v2-runbook
```

**13. LA-5: the dialog asked from an ssh login** (under 1 minute; expected: nothing on screen).

```
bash scripts/mac-measure/la-ssh.sh
```

If a dialog appears on the Mac's screen, Cancel it and say so in the last line. Record `la-ssh.txt`; look for
`outcome=unavailable("no session to show the dialog in …")` and `managername`.

**14. ANC-2: the ssh login's chain of processes** (nothing on screen, under 30 s).

```
bash scripts/mac-measure/ancestry-ssh.sh
```

Record `ancestry-ssh.txt`; look for `managername=` and `sshd-session` with `bsdinfo=refused`.

**15. Leave the ssh login, then turn Remote Login off** (System Settings › General › Sharing › Remote Login off) and
check it says `off` with step 11's line.

```
exit
```

## C. Needs an external display (about 3 minutes; skip it without one: a closed lid sleeps the Mac)

**16. LA-4: the dialog with the lid closed.** Run it in a Terminal window on the external display, with an external
keyboard (a new window starts in your home folder: run the `cd` line at the top in it first); it asks you to close the
lid first.

```
bash scripts/mac-measure/la-lid-closed.sh
```

Close the lid, Return; then approve the dialog ("MEASURE-4 …") with whatever it offers (a password into the dialog
only). Record `la-lid-closed.txt`; look for `biometryType=` and `deviceOwnerAuthenticationWithBiometrics=` with the lid
closed, then `outcome=`.

## Hand the records back

One file with every record, for the lead to read:

```
( cd .build/mac-measure-records && for f in *.txt; do printf '\n######## %s\n' "$f"; cat "$f"; done ) > .build/mac-measure-records.txt
```

It is `/Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/v2-on-the-mac-8/.vibeswitcher/v2-runbook/.build/mac-measure-records.txt`.

## The undo list

- **Remote Login off** (step 15): System Settings › General › Sharing › Remote Login. `systemsetup -setremotelogin`
  needs Full Disk Access for Terminal, so the switch is the way. Check with step 11's line: `Remote Login: off`.
- **No measurement job left loaded.** This prints nothing when none is:

  ```
  launchctl list | grep dev.vibeswitcher.measure
  ```

  If it printed any, boot them out (only `dev.vibeswitcher.measure.*`, never the node's; once no dialog is on screen):

  ```
  launchctl list | awk '$3 ~ /^dev\.vibeswitcher\.measure\./ { print $3 }' | while read -r label; do launchctl bootout "gui/501/$label"; done
  ```

- **The Terminal windows** ESC-1 and ESC-2 opened: closed (⌘W).
- **Privacy entries**, only if LA-7 or ESC-2 asked: System Settings › Privacy & Security › Accessibility (Terminal, if
  it appeared and wasn't there before) and › Automation (Terminal › Terminal). Not `tccutil reset`: it wipes other grants.
- **ssh's `known_hosts` line**, only if step 12 asked `Are you sure you want to continue connecting`:

  ```
  ssh-keygen -R localhost
  ```

## The `sudo` trial of the anchor's record (about 3 minutes)

The node's administrator step (`scripts/node-pins-mac.sh`, run by the install with one `sudo`) written for real, on
the **trial path** it allows besides the node's own, with made-up cdhashes (a trial's, never a build's):
`/Library/Application Support/VibeSwitcher-trial/node-501.pins`. Nothing of the node reads this path.

**T1. Write the trial record.** It prints exactly what it will write and where, then `sudo` asks your password in this
Terminal (`Password:`, or Touch ID if sudo uses it here). It makes the folder (root:wheel 0755), writes the record
(root:wheel 0644) and lists both.

```
/usr/bin/env -i /bin/bash -p /Users/albert/dev/vibeswitcher/.vibeswitcher/worktrees/v2-on-the-mac-8/.vibeswitcher/v2-runbook/scripts/node-pins-mac.sh --record "/Library/Application Support/VibeSwitcher-trial/node-501.pins" --build 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 3333333333333333333333333333333333333333 4444444444444444444444444444444444444444
```

Look for `node-pins-mac: written /Library/Application Support/VibeSwitcher-trial/node-501.pins`, then two `ls` lines
owned `root wheel`, `drwxr-xr-x` and `-rw-r--r--`.

**T2. The record: its owners and modes from `/` down, its text, and a write and a create as you, both refused**
(saved as `sudo-trial.txt` with the others; run it before "Hand the records back", or that step again after):

```
/bin/mkdir -p .build/mac-measure-records; { /bin/ls -lde / /Library "/Library/Application Support" "/Library/Application Support/VibeSwitcher-trial" "/Library/Application Support/VibeSwitcher-trial/node-501.pins"; /bin/cat "/Library/Application Support/VibeSwitcher-trial/node-501.pins"; echo x >> "/Library/Application Support/VibeSwitcher-trial/node-501.pins" && echo "WRITE ALLOWED"; /usr/bin/touch "/Library/Application Support/VibeSwitcher-trial/x" && echo "CREATE ALLOWED"; } > .build/mac-measure-records/sudo-trial.txt 2>&1; cat .build/mac-measure-records/sudo-trial.txt
```

Look for two lines saying `permission denied` (zsh's `zsh: permission denied: …` for the write, `touch: …: Permission
denied` for the create) and no `ALLOWED`.

**T3. Undo the trial** (one `sudo` password again), file first, then its folder:

```
sudo /bin/rm "/Library/Application Support/VibeSwitcher-trial/node-501.pins"
```

```
sudo /bin/rmdir "/Library/Application Support/VibeSwitcher-trial"
```

(If T2 said `CREATE ALLOWED`, remove `/Library/Application Support/VibeSwitcher-trial/x` the same way first.)

## Checked before it was handed over (2026-11-26, by an agent, nothing shown)

Every script `bash -n` clean and `--dry-run` to its end (probes built, property list linted, stopped before anything
was loaded or shown); a real run refused from an agent's process; the record, the stopped record and the wait for an
open ask driven with stubs; T1's line with `--dry-run` (it printed the record above and asked nothing); the folders
above the trial path root's, not writable by group or others, no ACL; Remote Login off (step 11's line said so).
