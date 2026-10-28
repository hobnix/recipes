# One login for your services

Put Authentik in front of the services that people reach from outside: you sign in with your directory account (Active Directory, when the server has one), friends with a local account that exists only in Authentik.

Admin pages (Incus, the reverse proxy, the container manager, the dashboard, the docs page) get no public route and no Authentik: they are reachable only from the home network or over Tailscale.

Tested on a real server: login, TOTP, the LDAP source, the reverse-proxy forward auth (with a test page) and the Pelican login (Authentik 2026.8). Menu names can differ in other versions.

## Before you start
- A server with the `ad` capability if you want directory accounts ([Users and shares](users-and-shares.md)); without it, use local Authentik users only and skip the LDAP step.
- A public name for the login page (here `auth.example.com`) and a reverse proxy such as Zoraxy.

## Set it up

```bash
sudo hs recipe authentik
```

The recipe creates the container `authentik` with Docker inside (a fixed address when your router connection is set up) and starts Authentik from its official `docker-compose.yml` (server, worker, database). It makes the database password, the secret key and the first admin password once and keeps them in `/opt/authentik/.env` inside the container. It prints the login `akadmin` with that password once, and the values for the LDAP source.

Put the container in the backup (the recipe already does, with a database dump) and check it:

```bash
sudo hs backup ct authentik on
```

## Add your directory accounts (LDAP source)
1. Create a read-only account without groups and a group for everyone who may sign in.

```bash
sudo hs user add authentik-bind
```

```bash
sudo hs group add panel-users
```

```bash
sudo hs user <name> join panel-users
```

2. In Authentik: **Directory > Federation and Social login > Create > LDAP Source**. The recipe printed the values. Mind these:
   - Server URI `ldaps://<domain controller>`, not `ldap://`: Samba refuses a sign-in without encryption ("Transport encryption required").
   - Samba's certificate is self-signed: leave "TLS Verification Certificate" empty and StartTLS off.
   - Bind CN in UPN form, `authentik-bind@<your realm>`; a bare name is rejected (`invalidCredentials`).
   - Choose the Active Directory mappings for users and groups, then **Sync** and check **Directory > Users**.
3. Create the group `panel-users` in Authentik (**Directory > Groups**), add the directory users, and bind it to each application: **Applications > <app> > Policy / Group / User Bindings > Bind existing policy > Group**. **Without a binding every Authentik user may enter.**
4. Switch on TOTP for your account (**Settings > MFA devices**). Do not put your directory password on a page everyone on the internet can try without protection.

## Add friends
**Directory > Users > Create**, set a password, put them in a group of their own (for example `pelican-friends`). They need no directory account and see nothing of your network.

## Put a service behind the login (forward auth)
Two ways; you can mix them.

| | Domain level (one application for all) | Single application (one per service) |
| --- | --- | --- |
| Authentik | One proxy provider, mode forward auth (domain level): authentication URL `https://auth.example.com`, cookie domain `example.com` | One provider per service, mode forward auth (single application), external host `https://<service>.example.com` |
| Reverse proxy per service | The forward-auth address and the headers | In addition the ignored path, the callback directory and "Add to Forward Auth hosts" |
| Access rule | One group binding for all services | One group per service possible |
| Limit | One cookie domain only | More manual work per service |

Use domain level for services the same people may see; single application for a service with its own group. Always select the application under **Outposts > authentik Embedded Outpost > Selected Applications** (otherwise the outpost answers 404) and set a group binding.

In the reverse proxy, on the service's rule:
- Forward-auth address `http://<authentik>/outpost.goauthentik.io/auth/traefik` (not `/auth/nginx`, which needs a header Zoraxy does not send).
- Response headers `X-authentik-*` and response client headers `Set-Cookie`.
- Single application only: ignored path `/outpost.goauthentik.io`, a callback virtual directory to `<authentik>:80/outpost.goauthentik.io`, then click **Add to Forward Auth hosts** (filling the form alone creates nothing; repeat after each new service).

Do not protect apps that have their own mobile apps (Jellyfin, Immich) with forward auth: the apps cannot sign in through a browser page.

## The login page itself
In the reverse proxy rule for `auth.example.com`:
- Target `<authentik address>:<port>` (the recipe prints it).
- A custom header `X-Forwarded-Proto: https` (replace, do not append). TLS ends at the tunnel; without the header Authentik builds `http://` API addresses and the browser blocks them as mixed content.
- A virtual directory `/if/admin/` to `127.0.0.1:1` (a dead end): the admin page is then reachable only from the home network at `http://<address>/if/admin/`.
- In Authentik edit the embedded outpost and set `authentik_host: https://auth.example.com`, otherwise it sends browsers to the internal address.

## Pelican signs in through Authentik
Put it in front of the Panel by OIDC, not as a forward-auth page: Wings calls the Panel's API (`/api/remote/...`) without a browser and would be locked out.
1. In Authentik create the group `pelican-friends`, then **Applications > Create with Provider**: name and slug `pelican`, provider OAuth2/OpenID, the implicit-consent authorization flow, client type Confidential, redirect URI (strict) `https://<panel address>/auth/oauth/callback/authentik`. Note client ID and secret. Bind the groups `panel-users` and `pelican-friends`.
2. In Pelican: **Admin > Settings > OAuth > Authentik**: base URL `https://auth.example.com`, client ID, secret. Set **Create missing users** on and **Link missing users** off: otherwise Pelican links by e-mail address, and since users can change their e-mail in Authentik a friend could take over the admin account.
3. Link your own admin account by hand (profile > OAuth > link Authentik), then test with the Authentik button. Keep the password as a reserve.
4. Test: a friend signs in (new account, no admin); a user in neither group is refused.

The Panel fetches the login from its container through `https://auth.example.com`, so that address must be reachable from there.

## Look of the login page
`brand/` in the package folder (`packages/authentik/brand/`) holds ready files (`logo.svg`, favicons, light and dark halftone backgrounds). Upload them under **Customization > Files**, then under **Customization > Brands** edit the brand for your address: title, logo, favicon and the default flow background (`background-%(theme)s.png` for light and dark). Reload with Ctrl+F5: browsers keep favicons stubbornly.

## Check that it worked
- A private browser window: forwarded to the login, then the service. A user outside the group is refused. `curl -i` without a login never shows the service.
- `curl -i https://<service>.example.com/outpost.goauthentik.io/ping` is answered by Authentik (204), not by the app (single application only).

## Update and remove
- Update: `sudo hs recipe authentik` keeps the secrets and fetches newer images.
- Remove: `sudo hs ct authentik remove` asks you to type the name and deletes the container with its users, groups and secrets. Restore it from the backup if you need it again.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| "The request failed and the interceptors did not return an alternative response" | The proxy sends `http` to Authentik | Add `X-Forwarded-Proto: https` |
| Redirect loop or 404 on `/outpost.goauthentik.io/callback` | Single application without the callback directory | Add it and click **Add to Forward Auth hosts** |
| "failed to detect a forward URL from nginx" | Wrong forward-auth address | Use `/auth/traefik` |
| `invalidCredentials` in the LDAP source | Bind name not in UPN form | `authentik-bind@<realm>`; reset the password with `samba-tool user setpassword` |

## Next
- [Game servers with Pelican](pelican.md)
