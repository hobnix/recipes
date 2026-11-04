# Claude VM

Run a small Linux desktop in a virtual machine on the server, with Claude Desktop installed, your repos on a fast share, and RustDesk to get in from your PC or phone.

## Before you start
- A running server with the SSD pool ([Storage and disks](storage-and-disks.md)).
- The RustDesk app on the PC or phone you connect from (rustdesk.com).
- An Anthropic account for Claude Desktop.

## Set up the VM

```bash
sudo hs recipe claude-vm
```

The recipe creates the virtual machine `claude-vm` (Debian, XFCE desktop, 4096 MB RAM, 2 CPUs, 40 GB disk; it asks first). It installs Claude Desktop from Anthropic's apt repository after checking the signing key, and RustDesk. The user is `dev`; the password is random and kept in `/var/lib/hs/claude-vm-admin`. The VM logs `dev` in on its own, because RustDesk needs a running desktop.

Claude Desktop on Linux supports Debian and Ubuntu only. Code and Chat work; Cowork needs nested virtualization and is not set up.

## Keep the repos on a fast share
The recipe makes the fast share `repos` (`/fast/shares/repos` on the server) unless it exists, switches on nightly snapshots for it and passes it into the VM. In the VM it is `/srv/repos`, linked as `~/repos`. Your PC reaches the same folder as the share `repos`, so you can open the files from Windows. The files belong to the share owner (`adminuser:users`); the user `dev` has the same numbers inside the VM.

To use a share with another name, run the recipe with `--ask`:

```bash
sudo hs recipe claude-vm --ask
```

The share must be a fast one. A repo you clone into `~/repos` survives deleting the VM.

## Connect with RustDesk
1. Open RustDesk on your PC or phone and enter the ID the recipe printed.
2. Enter the password from `/var/lib/hs/claude-vm-admin` (also the sudo password of `dev`).
3. Start **Claude** from the application menu and sign in. It opens Firefox for the sign-in.

Forgot the ID? Read it from the VM:

```bash
sudo incus exec claude-vm -- rustdesk --get-id
```

RustDesk uses RustDesk's public relay servers unless you run your own. The VM has no public route; reach it at home or through Tailscale.

## Update
Claude Desktop does not update itself on Linux. Update the VM from time to time:

```bash
sudo incus exec claude-vm -- apt-get update
```

```bash
sudo incus exec claude-vm -- apt-get -y full-upgrade
```

Take a snapshot first with `sudo hs ct claude-vm snapshot`.

## Check that it worked
- `sudo incus exec claude-vm -- mountpoint /srv/repos` says it is a mountpoint.
- RustDesk shows the desktop of `dev`, and **Claude** starts.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| The recipe warns that the share is not mounted | The server cannot hand the folder to the VM | `sudo incus config device show claude-vm` shows the device `repos`; restart the VM with `sudo incus restart claude-vm` |
| RustDesk shows a black screen or cannot connect | The desktop is not logged in yet | Wait a minute after the start; restart the VM |
| Claude asks for the sign-in every time | The VM has no unlocked keyring | `sudo incus exec claude-vm -- apt-get install gnome-keyring`, then log in again |
| The recipe stops at the RustDesk version | GitHub did not answer | Name it: `sudo RECIPE_VERSION=1.4.0 hs recipe claude-vm` |

Not tested on hardware yet.

## Next
- [Containers and apps](containers-and-apps.md)
- [Users and shares](users-and-shares.md)
