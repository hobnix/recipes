# Claude VM

Run a Linux virtual machine on the server for Claude Code: SSH and developer tools first, a desktop you reach with Remote Desktop, your repos on a fast share.

## Before you start
- A running server with the SSD pool ([Storage and disks](storage-and-disks.md)).
- A claude.ai subscription (Pro, Max, Team or Enterprise) for Claude Code and Remote Control. Remote Control does not use an API key.
- On Windows, the Remote Desktop Connection (`mstsc`) that comes with the system. Optional: your public SSH key (one line, for example from `~/.ssh/id_ed25519.pub`).

## Set up the VM

```bash
sudo hs recipe claude-vm
```

The recipe creates the virtual machine `claude-vm` (Debian, XFCE desktop, no GPU). It asks first for the memory (default 8192 MB), the CPUs (default 4), the disk (default 40 GB) and your public SSH key (`-` for none). On an existing VM the key is asked only with `sudo hs recipe claude-vm --ask`. It installs the Claude Code command from Anthropic's apt repository and Claude Desktop, both after checking the signing key, plus SSH, xrdp, developer tools (git, gh, ripgrep, Node.js, Python, shellcheck, tmux and more) and Docker.

The user is `dev`. The password is random and kept in `/var/lib/hs/claude-vm-admin`. It is also the sudo password, the Remote Desktop password and the SSH password.

The VM has no public route. Remote Desktop (port 3389) and SSH are admin doors: reach them at home or through Tailscale, and never add a Zoraxy rule for them.

Claude Desktop on Linux supports Debian and Ubuntu only. Cowork needs nested virtualization, which is not verified here; do not count on it.

## Keep the repos on a fast share
The recipe makes the fast share `repos` (`/fast/shares/repos` on the server) unless it exists, switches on nightly snapshots for it and passes it into the VM. In the VM it is `/srv/repos`, linked as `~/repos`. Your PC reaches the same folder as the share `repos`, so you can open the files from Windows. The files belong to the share owner (`adminuser:users`); the user `dev` has the same numbers inside the VM.

To use a share with another name, run the recipe with `--ask`:

```bash
sudo hs recipe claude-vm --ask
```

The share must be a fast one. A repo you clone into `~/repos` survives deleting the VM.

## Connect with Remote Desktop
1. Open `mstsc` on your PC and enter the address of the VM (the recipe printed it).
2. Sign in as `dev` with the password from `/var/lib/hs/claude-vm-admin`.
3. The XFCE desktop opens. Start **Claude** from the application menu and sign in; it opens Firefox for the sign-in.

Each Remote Desktop login starts its own desktop session. Log out when you are done, or the next login may show a black screen.

## Work over SSH
Connect from a terminal on your PC:

```bash
ssh dev@<address>
```

If you gave a public key, no password is needed. The Claude desktop app on your PC can use the same address as an SSH environment: add a new environment, choose SSH, and enter `dev@<address>`.

Set your name for git once:

```bash
git config --global user.name "Your Name"
```

```bash
git config --global user.email "you@example.com"
```

Sign in to GitHub with `gh auth login`.

## Run sessions that keep going
A Claude Code session can keep running in the VM after you close the window, and you steer it from claude.ai/code or the phone app (Remote Control). It needs a claude.ai subscription, not an API key. A session waits at every permission prompt until you answer it.

1. In the VM, start `claude` and run `/login`.
2. Clone a repo into `~/repos`, for example `git clone <url> ~/repos/myrepo`.
3. Run `cd /srv/repos/myrepo`, then `claude` once, and accept the trust question. Use this path, not `~/repos`, because the service starts in `/srv/repos/<repo>` and trust is kept per path.
4. Enable the service for that repo:

```bash
sudo systemctl enable --now claude-remote@myrepo
```

5. Open claude.ai/code or the Claude phone app. The session of the repo is in the list.

The recipe installs the template unit `claude-remote@.service` but enables no instance, because it needs your sign-in and a cloned repo first. The name after the `@` is the folder in `/srv/repos`. To stop one: `sudo systemctl disable --now claude-remote@myrepo`.

Whether the service runs without a terminal is not verified. If it stops with an error about the terminal, run it in tmux instead:

```bash
tmux new -s claude
```

Then start `claude remote-control` in the repo inside tmux and detach with Ctrl-b d.

## Update
Claude Code and Claude Desktop are apt packages and do not update themselves. Take a snapshot first with `sudo hs ct claude-vm snapshot`, then update the VM from time to time:

```bash
sudo incus exec claude-vm -- apt-get update
```

```bash
sudo incus exec claude-vm -- apt-get -y full-upgrade
```

## Check that it worked
- `sudo incus exec claude-vm -- mountpoint /srv/repos` says it is a mountpoint.
- `mstsc` shows the desktop of `dev`, and **Claude** starts.
- `ssh dev@<address>` works, and `claude --version` prints a version.
- `docker run --rm hello-world` runs in the VM (log in again after the first setup so the group applies).

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| The recipe warns that the share is not mounted | The server cannot hand the folder to the VM | `sudo incus config device show claude-vm` shows the device `repos`; restart the VM with `sudo incus restart claude-vm` |
| Remote Desktop shows a black screen | Another session of `dev` is still open (for example on the VM console) | Log out the other sessions of `dev`, or restart xrdp: `sudo incus exec claude-vm -- systemctl restart xrdp` |
| Remote Desktop cannot connect | xrdp is not running or the VM has no address | `sudo incus exec claude-vm -- systemctl status xrdp`; check the address with `sudo hs ct list` |
| Claude asks for the sign-in every time | The VM has no unlocked keyring | `sudo incus exec claude-vm -- apt-get install --reinstall libpam-gnome-keyring`, then log out of the Remote Desktop session and in again |
| `claude-remote@<repo>` keeps restarting | No sign-in yet, the repo is not trusted, or the folder does not exist | `sudo incus exec claude-vm -- journalctl -u claude-remote@<repo> -n 40`; do steps 1 to 3 of the section above, or use the tmux fallback |
| SSH asks for a password although you gave a key | The key was not valid or not copied | Add it to `/home/dev/.ssh/authorized_keys` in the VM, or run `sudo hs recipe claude-vm --ask` |

Not tested on hardware yet.

## Next
- [Containers and apps](containers-and-apps.md)
- [Users and shares](users-and-shares.md)
